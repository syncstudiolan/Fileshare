package com.sammyi57.pdftools

import android.util.Log
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.font.PDType1Font
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAppearanceDictionary
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAppearanceStream
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationWidget
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDSignatureField
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/** Full validation and integrity-only legacy verification remain distinct.
 * The qualified mark never claims a valid current-policy certificate or a
 * successful revocation check. The original PDF signature remains untouched.
 */
internal enum class DscAppearanceVerdict { VALID, VERIFIED_WITH_WARNINGS, INVALID, UNKNOWN }

internal fun dscAppearanceVerdict(sig: DscResult): DscAppearanceVerdict = when {
  sig.status == DscStatus.INVALID || sig.revocation == "Revoked" -> DscAppearanceVerdict.INVALID
  sig.status == DscStatus.VALID && sig.integrity && sig.trusted &&
    sig.revocation == "Good" -> DscAppearanceVerdict.VALID
  // A native-verified legacy signature proves signed-byte integrity and CA
  // chaining, NOT modern SHA-1 suitability or a good revocation response.
  // Show a clearly qualified verification mark rather than the stale PDF '?'.
  sig.status == DscStatus.LEGACY_NATIVE_VERIFIED && sig.integrity && sig.trusted &&
    sig.nativeVerdict?.equals("valid", ignoreCase = true) == true &&
    sig.revocation != "Revoked" -> DscAppearanceVerdict.VERIFIED_WITH_WARNINGS
  else -> DscAppearanceVerdict.UNKNOWN
}

/**
 * Render-only PDF copy. It rewrites the /AP N stream of VERIFIED/INVALID
 * signature widgets in a temporary, explicitly unsigned preview, so the PDF
 * engine itself draws the status together with the page at every zoom/scroll.
 *
 * Unlike an overlay composited above a second PDF viewport, the old question
 * mark and our new status can never appear at different scroll positions.
 * Widget backgrounds are transparent: the exact original PAGE artwork shows
 * through instead of a hard-coded white rectangle. The signer/date/reason
 * lines are taken from the original signed PDF and verified certificate,
 * never from invented test data.
 *
 * Do not share, sign, validate, or save this derivative as the real document:
 * the original PDF remains at 'path' and is used for all verification,
 * saving, sharing and tool actions. The preview rewrites PDF bytes, so its
 * embedded /ByteRange would intentionally no longer validate.
 */
internal suspend fun prepareDscViewerAppearance(
    path: String, password: String?, result: DscDocument): File? =
  withContext(Dispatchers.IO) {
    if (result.signatures.none { dscAppearanceVerdict(it) != DscAppearanceVerdict.UNKNOWN })
      return@withContext null
    val original = File(path)
    require(original.length() in 1L..(64L*1024*1024)) { "PDF too large for render-only preview" }
    val bytes = original.readBytes()
    require(DscSignedBytes.sha256(bytes) == result.hash) {
      "Source PDF changed; refresh original signature validation"
    }
    val folder = File(appContext.cacheDir, "pdf_signature_previews").apply { mkdirs() }
    val output = File.createTempFile("preview-only-", ".pdf", folder)
    try {
      var changed = 0
      PDDocument.load(bytes, password.orEmpty()).use { pdf ->
        changed = applyDscPreviewAppearances(pdf, result)
        if (changed > 0) {
          // Jetpack PDF does not consistently paint every widget /AP. Bake
          // the replacement into page content of this UNSIGNED preview only.
          // false = preserve the appearance we just authored, do not
          // regenerate the original '?' from the field value.
          val matched = signaturePreviewFields(pdf, result)
          check(matched.isNotEmpty()) {
            "No signature widget can be flattened into the preview"
          }
          pdf.documentCatalog.acroForm?.flatten(matched, false)
          pdf.documentInformation.setCustomMetadataValue(
            "FileSharePreviewOnly", "UNSIGNED_RENDER_COPY_NEVER_VERIFY")
          pdf.save(output)
        }
      }
      if (changed == 0) {
        output.delete()
        return@withContext null
      }
      require(output.length() in 1L..(64L*1024*1024)) { "Preview PDF too large" }
      output
    } catch (e: Exception) {
      output.delete()
      Log.w("FileShareDSC", "Unable to compose signature preview; show original PDF", e)
      null
    }
  }

/** Replace ONLY a signed widget's normal /AP in an unsigned, in-memory
 * rendering derivative. The original document is NEVER passed to this
 * function for persistence or signing. */
/** Fail-closed match for a signed PDF /V dictionary and its field value. */
internal fun dscSameSignedData(
  fieldRange: IntArray?, fieldContents: ByteArray?,
  signatureRange: IntArray?, signatureContents: ByteArray?,
): Boolean =
  fieldRange != null && signatureRange != null &&
    fieldContents != null && signatureContents != null &&
    fieldRange.contentEquals(signatureRange) &&
    fieldContents.contentEquals(signatureContents)

/**
 * COSDictionary object identity (===) is not stable across PDFBox wrappers.
 * Match actual signature contents + ByteRange instead, and reject ambiguous
 * fields. Never assign a green appearance to an unrelated PDF field.
 */
internal fun signaturePreviewFields(pdf: PDDocument, result: DscDocument): List<PDSignatureField> {
  val fields = pdf.documentCatalog.acroForm?.fieldTree
    ?.filterIsInstance<PDSignatureField>().orEmpty()
  val selected = mutableListOf<PDSignatureField>()
  pdf.signatureDictionaries.forEachIndexed { index, signed ->
    val sig = result.signatures.firstOrNull { it.id.substringBefore(":").toIntOrNull() == index }
      ?: return@forEachIndexed
    if (dscAppearanceVerdict(sig) == DscAppearanceVerdict.UNKNOWN) return@forEachIndexed
    val candidate = fields.filter { field ->
      val value = field.signature ?: return@filter false
      dscSameSignedData(value.byteRange, value.contents,
        signed.byteRange, signed.contents)
    }
    if (candidate.size != 1) {
      Log.w("FileShareDSC", "Signature ${index + 1}: expected exactly one matching signature widget field, found ${candidate.size}")
      return@forEachIndexed
    }
    val field = candidate.single()
    if (field.widgets.any { widget ->
        widget.rectangle?.let { it.width.isFinite() && it.height.isFinite() &&
          it.width > 0f && it.height > 0f } == true
      } && field !in selected) selected.add(field)
  }
  return selected
}

/** Replaces the annotation appearance only in a temporary unsigned document.
 * It is later flattened for reliable rendering by Android's Jetpack PDF.
 */
internal fun applyDscPreviewAppearances(pdf: PDDocument, result: DscDocument): Int {
  val selected = signaturePreviewFields(pdf, result)
  var changed = 0
  pdf.signatureDictionaries.forEachIndexed { index, signed ->
    val sig = result.signatures.firstOrNull { it.id.substringBefore(":").toIntOrNull() == index }
      ?: return@forEachIndexed
    val verdict = dscAppearanceVerdict(sig)
    if (verdict == DscAppearanceVerdict.UNKNOWN) return@forEachIndexed
    val field = selected.singleOrNull { candidate ->
      val value = candidate.signature ?: return@singleOrNull false
      dscSameSignedData(value.byteRange, value.contents,
        signed.byteRange, signed.contents)
    } ?: return@forEachIndexed
    for (widget in field.widgets) {
      val rect = widget.rectangle ?: continue
      if (rect.width <= 0f || rect.height <= 0f ||
          !rect.width.isFinite() || !rect.height.isFinite()) continue
      drawViewerSignature(pdf, widget, sig, verdict,
        signed.name.orEmpty(), signed.reason.orEmpty(), signed.location.orEmpty())
      changed++
    }
  }
  return changed
}

private fun drawViewerSignature(
  document: PDDocument, widget: PDAnnotationWidget, sig: DscResult,
  verdict: DscAppearanceVerdict, originalName: String,
  originalReason: String, originalLocation: String,
) {
  val box = widget.rectangle
  val width = box.width
  val height = box.height
  val appearance = PDAppearanceStream(document).apply {
    bBox = PDRectangle(width, height)
    resources = PDResources()
  }
  val dictionary = PDAppearanceDictionary().apply {
    setNormalAppearance(appearance)
  }
  // Important: NOT a page-wide opaque rectangle. The signed page's original
  // art and its original colored background remain as drawn in the PDF.
  PDPageContentStream(document, appearance).use { stream ->
    val green = verdict == DscAppearanceVerdict.VALID || verdict == DscAppearanceVerdict.VERIFIED_WITH_WARNINGS
    val accent = if (green) intArrayOf(0, 135, 74) else intArrayOf(191, 40, 40)
    val title = when(verdict) {
      DscAppearanceVerdict.VALID -> "Signature valid"
      DscAppearanceVerdict.VERIFIED_WITH_WARNINGS -> "Signature integrity verified*"
      else -> "Signature invalid"
    }
    // The mark sits BELOW the heading, not through it.
    val markW = width * .26f
    val markH = height * .28f
    val x = width * .55f
    val y = height * .14f
    stream.setStrokingColor(accent[0], accent[1], accent[2])
    stream.setLineWidth((minOf(width,height) * .035f).coerceIn(1.1f, 5f))
    if (green) {
      stream.moveTo(x, y + markH*.44f)
      stream.lineTo(x + markW*.36f, y)
      stream.lineTo(x + markW, y + markH)
    } else {
      stream.moveTo(x, y)
      stream.lineTo(x+markW, y+markH)
      stream.moveTo(x, y+markH)
      stream.lineTo(x+markW, y)
    }
    stream.stroke()

    // PDF appearance text is NOT substituted with a made-up signer or date.
    // Read actual signature properties, with certificate name as fallback.
    val signer = originalName.ifBlank {
      sig.certificate?.let(DscCertificates::displayName).orEmpty()
        .ifBlank { sig.name }
    }
    val facts = listOfNotNull(
      signer.trim().takeIf { it.isNotEmpty() }?.let { "Digitally signed by $it" },
      sig.claimedSigningDate?.trim()?.takeIf { it.isNotEmpty() }?.let { "Date: $it" },
      originalReason.trim().takeIf { it.isNotEmpty() }?.let { "Reason: $it" },
      originalLocation.trim().takeIf { it.isNotEmpty() }?.let { "Location: $it" },
    )
    fun line(text: String, baseline: Float, fontSize: Float, bold: Boolean = false) {
      // Built-in Helvetica has WinAnsi coverage only. Do not invent glyphs:
      // skip unsupported code points rather than crash the viewer.
      val cleaned = text.map { ch -> if(ch.code in 32..126) ch else ' ' }
        .joinToString("").replace(Regex("\\s+"), " ").trim()
      if(cleaned.isEmpty())return
      val font = if(bold) PDType1Font.HELVETICA_BOLD else PDType1Font.HELVETICA
      val safeWidth = (width-12f).coerceAtLeast(4f)
      val measured = font.getStringWidth(cleaned) / 1000f
      val size = minOf(fontSize, (safeWidth / measured).coerceAtLeast(1f))
      stream.setNonStrokingColor(26, 34, 32)
      stream.beginText()
      stream.setFont(font, size)
      stream.newLineAtOffset(5f, baseline)
      stream.showText(cleaned)
      stream.endText()
    }
    val titleSize = (height * .14f).coerceIn(7f, 19f)
    line(title, height*.84f, titleSize, true)
    val lineSize = (height*.095f).coerceIn(5f, 12f)
    val step = lineSize*1.25f
    val displayFacts = if(verdict == DscAppearanceVerdict.VERIFIED_WITH_WARNINGS)
      listOf("* Legacy SHA-1; revocation not established") + facts
      else facts
    displayFacts.take(4).forEachIndexed { index, fact ->
      line(fact, height*.67f-index*step, lineSize)
    }
    // The renderer itself—not a second Compose overlay—now owns the status.
  }
  widget.appearance = dictionary
}
