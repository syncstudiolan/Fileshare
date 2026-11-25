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
    val dark = 0xff20252a.toInt()
    val warning = 0xff805400.toInt()
    fun line(value: String, y: Float, size: Float, color: Int = dark, bold: Boolean = false) {
      p.style = Paint.Style.FILL
      p.color = color
      p.typeface = if (bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
      p.textAlign = Paint.Align.LEFT
      p.textSize = size
      val measured = p.measureText(value)
      if (measured > 224f) p.textSize = size * 224f / measured
      canvas.drawText(value, 8f, y, p)
    }
    line(if (visualCopy) "Original signature checked*" else if (legacy || sig.revocation != "Good") "Signature verified*" else "Signature valid", 26f, 23f)
    line("Digitally signed by", 46f, 15f)
    line(signer.take(100), 64f, 15f)
    sig.claimedSigningDate?.let { line("Claimed date: " + it, 81f, 13f) }
    val tick = Path().apply {
      moveTo(77f, 113f); lineTo(108f, 142f); lineTo(177f, 88f)
    }
    p.style = Paint.Style.STROKE
    p.strokeCap = Paint.Cap.SQUARE
    p.strokeJoin = Paint.Join.MITER
    p.strokeWidth = 22f; p.color = 0xff12321d.toInt()
    canvas.drawPath(tick, p)
    p.strokeWidth = 16f; p.color = 0xff159447.toInt()
    canvas.drawPath(tick, p)
    if (legacy) {
      line("* Legacy SHA-1", 163f, 13f, warning, true)
      line(if (sig.revocation == "Good") "Revocation checked" else "CA status not available", 178f, 13f, warning)
    } else if (sig.revocation != "Good") {
      line("* CA revocation status unavailable", 178f, 13f, warning)
    }
    line(if (visualCopy) "UNSIGNED VISUAL COPY" else "File Share verification", 194f, 13f, dark, visualCopy)
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
          for (index in 0 until input.numberOfPages) {
            val page = input.getPage(index)
            val box = page.cropBox
            val rotated = ((page.rotation % 360)+360)%360 in setOf(90,270)
            val w = if (rotated) box.height else box.width
            val h = if (rotated) box.width else box.height
            require(w.isFinite() && h.isFinite() && w > 0f && h > 0f) { "Invalid PDF page dimensions" }
            val scale = minOf(3f, 2400f/maxOf(w,h))
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
              val img = JPEGFactory.createFromImage(out, bitmap, 0.96f)
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
      require(target.isFile && target.length() > 0L) { "Visual copy was not created" }
      target
    } catch (e: Throwable) {
      output?.delete()
      throw e
    } finally { snapshot.delete() }
  }
