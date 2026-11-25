package com.sammyi57.pdftools

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.font.PDType1Font
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory
import com.tom_roush.pdfbox.rendering.PDFRenderer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

internal fun hasVerifiedAppearance(sig: DscResult): Boolean =
  sig.integrity && sig.trusted && sig.revocation != "Revoked" &&
    (sig.status == DscStatus.VALID || sig.status == DscStatus.LEGACY_NATIVE_VERIFIED || sig.status == DscStatus.NATIVE_VERIFIED)

/** One shared painter for viewport and the clearly identified unsigned visual copy.
 * Never edits the original PDF or claims that a flattened image is a DSC. */
internal fun paintDscAppearance(canvas: Canvas, rect: RectF, sig: DscResult, visualCopy: Boolean) {
  if (!hasVerifiedAppearance(sig) || !rect.width().isFinite() || !rect.height().isFinite() ||
      rect.width() <= 0f || rect.height() <= 0f) return
  val legacy = sig.status == DscStatus.LEGACY_NATIVE_VERIFIED
  val signer = sig.certificate?.let(DscCertificates::displayName) ?: sig.name
  val p = Paint(Paint.ANTI_ALIAS_FLAG)
  val save = canvas.save()
  try {
    canvas.clipRect(rect)
    p.color = Color.WHITE
    canvas.drawRect(rect, p)
    canvas.translate(rect.left, rect.top)
    canvas.scale(rect.width()/240f, rect.height()/200f)
    // Reference layout: left-aligned black heading and signer/date lines,
    // with a large, outlined diagonal green check across the text block.
    // Both the viewer and exported page use this exact same painter.
    val dark = 0xff171717.toInt()
    val warning = 0xff805400.toInt()
    fun line(value: String, y: Float, size: Float, color: Int = dark) {
      p.style = Paint.Style.FILL
      p.color = color
      p.typeface = Typeface.DEFAULT
      p.textAlign = Paint.Align.LEFT
      p.textSize = size
      val measured = p.measureText(value)
      if (measured > 224f) p.textSize = size * 224f / measured
      canvas.drawText(value, 8f, y, p)
    }
    val qualified = legacy || sig.revocation != "Good" || sig.status != DscStatus.VALID
    line(if (qualified) "Signature verified*" else "Signature valid", 34f, 26f)
    line("Digitally signed by", 60f, 18f)
    line(signer.take(160), 81f, 18f)
    val date = sig.claimedSigningDate
    line(if (date != null) "Date: " + date else "Date: Not available", 103f, 16f)
    // Filled angular tick with black outline and offset dark shadow,
    // matching the reference rather than using a corner badge or glyph.
    val tick = Path().apply {
      moveTo(88f, 78f)
      lineTo(109f, 99f)
      lineTo(151f, 38f)
      lineTo(166f, 49f)
      lineTo(112f, 127f)
      lineTo(74f, 94f)
      close()
    }
    p.style = Paint.Style.FILL
    p.color = 0xff111111.toInt()
    canvas.save()
    canvas.translate(3f, 4f)
    canvas.drawPath(tick,p)
    canvas.restore()
    p.color = 0xe600a33d.toInt()
    canvas.drawPath(tick,p)
    p.style = Paint.Style.STROKE
    p.strokeWidth = 2f
    p.strokeJoin = Paint.Join.MITER
    p.color = 0xff183b23.toInt()
    canvas.drawPath(tick,p)
    // Keep material qualifications readable below the reference-style
    // block. A static copy cannot represent a live digital signature.
    if (legacy) line("* Legacy SHA-1", 146f, 14f, warning)
    if (sig.revocation != "Good") line("* CA revocation status unavailable", 163f, 13f, warning)
    if (date != null) line("Date as recorded by signer", 179f, 11f, dark)
    line(if (visualCopy) "UNSIGNED VISUAL COPY" else "File Share verification", 195f, 13f, dark)
  } finally { canvas.restoreToCount(save) }
}

/** Render full pages at bounded high resolution, not a cropped phone screenshot.
 * Explicit opt-in only; every new page has a large unsigned-copy header outside
 * the original page area. No original AcroForm or signature dictionaries copied. */
internal suspend fun prepareDscVisualCopy(path: String, name: String, password: String?, expectedHash: String): File =
  withContext(Dispatchers.IO) {
    val source = File(path)
    require(source.length() in 1L..(64L*1024*1024)) { "PDF exceeds visual copy limit" }
    val bytes = source.readBytes()
    require(bytes.size <= 64*1024*1024 && DscSignedBytes.sha256(bytes) == expectedHash) { "PDF changed; reopen and verify again" }
    val dir = File(appContext.cacheDir, "pdf_send").apply { mkdirs() }
    val snapshot = File.createTempFile("dsc-original-", ".pdf", dir)
    var output: File? = null
    try {
      snapshot.writeBytes(bytes)
      val verified = DscVerifier.read(snapshot.path, password, online = false)
      require(verified.hash == expectedHash && verified.signatures.isNotEmpty() &&
        verified.signatures.all(::hasVerifiedAppearance) && verified.signatures.all { it.widgets.isNotEmpty() }) {
        "Visual copy requires verified visible signatures; share the original instead."
      }
      val basename = cleanName(name.substringBeforeLast('.', name)).ifBlank { "document" }
      val target = File(dir, "${basename}_UNSIGNED_VISUAL_COPY_${System.nanoTime()}.pdf")
      output = target
      PDDocument.load(bytes,password.orEmpty()).use { input ->
        require(input.currentAccessPermission.canPrint() && input.currentAccessPermission.canExtractContent()) {
          "The PDF permissions do not allow creating a visual copy."
        }
        require(input.numberOfPages in 1..50) { "Visual copy supports up to 50 pages" }
        require(verified.signatures.flatMap { it.widgets }.all { it.page in 0 until input.numberOfPages }) {
          "Signature widget page could not be mapped safely"
        }
        val renderer = PDFRenderer(input)
        PDDocument().use { out ->
          out.documentInformation.title = "Unsigned visual verification copy"
          out.documentInformation.setCustomMetadataValue("FileShareCopyType", "UNSIGNED_VISUAL_COPY_V1")
          for (index in 0 until input.numberOfPages) {
            val page = input.getPage(index)
            val box = page.cropBox
            val rotated = ((page.rotation % 360)+360)%360 in setOf(90,270)
            val w = if (rotated) box.height else box.width
            val h = if (rotated) box.width else box.height
            require(w.isFinite() && h.isFinite() && w > 0f && h > 0f) { "Invalid PDF page dimensions" }
            // 300 dpi target; cap the longest edge to keep per-page memory bounded.
            val scale = minOf(300f/72f, 3500f/maxOf(w,h))
            val bitmap = renderer.renderImage(index, scale)
            try {
              val canvas = Canvas(bitmap)
              val sx = bitmap.width/w; val sy = bitmap.height/h
              for (sig in verified.signatures) for (widget in sig.widgets.filter { it.page == index }) {
                require(listOf(widget.left,widget.top,widget.right,widget.bottom).all { it.isFinite() } &&
                  widget.right > widget.left && widget.bottom > widget.top &&
                  widget.left >= -0.5f && widget.top >= -0.5f && widget.right <= w+0.5f && widget.bottom <= h+0.5f) {
                  "Signature widget is outside the rendered page"
                }
                paintDscAppearance(canvas, RectF(widget.left*sx,widget.top*sy,widget.right*sx,widget.bottom*sy), sig, true)
              }
              val img = JPEGFactory.createFromImage(out, bitmap, 0.98f)
              val header = 46f
              val pw = maxOf(w, 360f)
              val newPage = PDPage(PDRectangle(pw,h+header))
              out.addPage(newPage)
              PDPageContentStream(out,newPage).use { stream ->
                stream.drawImage(img, (pw-w)/2f, 0f,w,h)
                stream.beginText()
                stream.setFont(PDType1Font.HELVETICA_BOLD, 13f)
                stream.newLineAtOffset(8f,h+28f)
                stream.showText("UNSIGNED VISUAL COPY - NOT A DIGITAL SIGNATURE")
                stream.endText()
                stream.beginText()
                stream.setFont(PDType1Font.HELVETICA, 9f)
                stream.newLineAtOffset(8f,h+12f)
                stream.showText("For independent verification, use the original signed PDF.")
                stream.endText()
              }
            } finally { bitmap.recycle() }
          }
          out.save(target)
        }
      }
      require(target.isFile && target.length() in 1L..(64L*1024*1024)) { "Visual copy exceeds the 64 MB size limit" }
      PDDocument.load(target).use { check ->
        require(!check.isEncrypted && check.signatureDictionaries.isEmpty() &&
          check.documentInformation.getCustomMetadataValue("FileShareCopyType") == "UNSIGNED_VISUAL_COPY_V1") {
          "Visual copy must be password-free and explicitly unsigned"
        }
        require(check.numberOfPages > 0)
      }
      target
    } catch (e: Throwable) {
      output?.delete()
      throw e
    } finally { snapshot.delete() }
  }
