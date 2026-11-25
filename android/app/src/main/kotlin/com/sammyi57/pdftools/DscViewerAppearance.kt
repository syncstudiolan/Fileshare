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
  sig.status in setOf(DscStatus.LEGACY_NATIVE_VERIFIED, DscStatus.NATIVE_VERIFIED) &&
    sig.integrity && sig.trusted &&
    sig.nativeVerdict?.equals("valid", ignoreCase = true) == true &&
    sig.revocation != "Revoked" -> DscAppearanceVerdict.VERIFIED_WITH_WARNINGS
  else -> DscAppearanceVerdict.UNKNOWN
}

/** Signature text comes from the current PDF/signature, never from a
 * document template or a hard-coded identity. Qualified status is distinct
 * from a modern-policy valid signature on both viewer and export.
 */
internal fun dscAppearanceLabel(verdict: DscAppearanceVerdict): String = when(verdict) {
  DscAppearanceVerdict.VALID -> "Signature valid"
  DscAppearanceVerdict.VERIFIED_WITH_WARNINGS -> "Signature integrity verified*"
  DscAppearanceVerdict.INVALID -> "Signature invalid"
  DscAppearanceVerdict.UNKNOWN -> "Signature not established"
}

internal fun dscAppearanceFacts(sig: DscResult, signer: String,
    reason: String, location: String, verdict: DscAppearanceVerdict): List<String> {
  val result = mutableListOf<String>()
  signer.trim().takeIf { it.isNotEmpty() }?.let { result.add("Digitally signed by $it") }
  sig.claimedSigningDate?.trim()?.takeIf { it.isNotEmpty() }?.let { result.add("Date: $it") }
  reason.trim().takeIf { it.isNotEmpty() }?.let { result.add("Reason: $it") }
  location.trim().takeIf { it.isNotEmpty() }?.let { result.add("Location: $it") }
  if (verdict == DscAppearanceVerdict.VERIFIED_WITH_WARNINGS) {
    if (sig.status == DscStatus.LEGACY_NATIVE_VERIFIED)
      result.add("* Legacy SHA-1: modern validity not established")
  }
  if (verdict != DscAppearanceVerdict.UNKNOWN && sig.revocation != "Good") {
    result.add("* Revocation: ${sig.revocation}")
  }
  return result
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
        throw IllegalStateException(
          "No matching editable signature widget was found. " +
          "The original signed PDF and its cryptographic result are unchanged.")
      }
      require(output.length() in 1L..(64L*1024*1024)) { "Preview PDF too large" }
      output
    } catch (e: Exception) {
      output.delete()
      Log.w("FileShareDSC", "Unable to compose signature preview; show original PDF", e)
      throw e
    }
  }

/** Replace ONLY a signed widget's normal /AP in an unsigned, in-memory
 * rendering derivative. The original document is NEVER passed to this
 * function for persistence or signing. */
/** Fail-closed match for a signed PDF /V dictionary and its field value. */
/** PDF signature /Contents may be returned by PDFBox either with its
 * reserved trailing zero bytes or with the ASN.1 DER payload alone.
 * Compare the common bytes and allow ONLY zero-valued extra padding;
 * always require the exact same signed /ByteRange to avoid accidental
 * binding to another field. This never establishes cryptographic validity.
 */
internal fun dscSameSignatureContents(a: ByteArray, b: ByteArray): Boolean {
  if(a.contentEquals(b))return true
  val length=minOf(a.size,b.size)
  if(length==0)return false
  for(i in 0 until length)if(a[i]!=b[i])return false
  val longer=if(a.size>b.size)a else b
  for(i in length until longer.size)if(longer[i].toInt()!=0)return false
  return true
}

internal fun dscSameSignedData(
  fieldRange: IntArray?, fieldContents: ByteArray?,
  signatureRange: IntArray?, signatureContents: ByteArray?,
): Boolean =
  fieldRange != null && signatureRange != null &&
    fieldContents != null && signatureContents != null &&
    fieldRange.contentEquals(signatureRange) &&
    dscSameSignatureContents(fieldContents,signatureContents)

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
      Log.w("FileShareDSC",
        "Signature ${index + 1}: matched ${candidate.size} signed fields " +
        "(AcroForm fields=${fields.size}, PDF signatures=${pdf.signatureDictionaries.size}); " +
        "cannot replace appearance without an unambiguous signed widget")
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
      // Adobe/UIDAI-style signature widgets already contain a dedicated
      // FRM with n0..n4 layers. Preserve original n0/n2 instead of erasing
      // the whole signer box. For shared/multi-signature appearances use the
      // existing conservative isolated-widget fallback.
      val layered = pdf.signatureDictionaries.size == 1 &&
        field.widgets.size == 1 &&
        replaceDscNamedStatusLayers(pdf, widget, verdict)
      if(!layered) {
        drawViewerSignature(pdf, widget, sig, verdict,
          signed.name.orEmpty(), signed.reason.orEmpty(), signed.location.orEmpty())
      }
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
    val title = dscAppearanceLabel(verdict)
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
    val facts = dscAppearanceFacts(sig, signer, originalReason, originalLocation, verdict)
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
    // Content-aware layout rather than the PAN-card template dimensions.
    // Keep the full source-derived signature identity before optional details.
    val titleSize = (height * .14f).coerceIn(5f, 19f)
    line(title, height*.84f, titleSize, true)
    val availableHeight = (height*.56f).coerceAtLeast(0f)
    val targetLineSize = (height*.095f).coerceIn(4f, 12f)
    val perLine = targetLineSize*1.24f
    val lines = minOf(facts.size, (availableHeight / perLine).toInt().coerceAtLeast(0))
    facts.take(lines).forEachIndexed { index, fact ->
      line(fact, height*.66f-index*perLine, targetLineSize)
    }
    // The renderer itself—not a second Compose overlay—now owns the status.
  }
  widget.appearance = dictionary
}
