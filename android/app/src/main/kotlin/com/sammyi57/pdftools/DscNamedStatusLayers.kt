package com.sammyi57.pdftools

import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.font.PDType1Font
import com.tom_roush.pdfbox.pdmodel.graphics.form.PDFormXObject
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAppearanceStream
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationWidget

/**
 * PDF Craft-style n1/n3/n4 status layer rewrite in an UNSIGNED viewer preview.
 * Preserve /FRM transforms, original n0 background and actual n2 signer data.
 * Never modify the original signed PDF or promote a status from a visual mark.
 */
/** A named Adobe status appearance must never be flattened into an opaque
 * invented replacement on failure. A failed layer update is reported
 * instead so the original signer artwork is preserved exactly.
 */
internal fun dscHasNamedStatusLayers(widget: PDAnnotationWidget): Boolean = runCatching {
  val normal=widget.appearance?.normalAppearance
    ?.takeIf { it.isStream }?.appearanceStream ?: return@runCatching false
  val resources=normal.resources ?: return@runCatching false
  val frame=resources.getXObject(COSName.getPDFName("FRM"))
    as? PDFormXObject ?: return@runCatching false
  val layers=frame.resources ?: return@runCatching false
  layers.getXObject(COSName.getPDFName("n1")) is PDFormXObject &&
    layers.getXObject(COSName.getPDFName("n3")) is PDFormXObject
}.getOrDefault(false)

internal fun replaceDscNamedStatusLayers(
  pdf: PDDocument, widget: PDAnnotationWidget, verdict: DscAppearanceVerdict,
): Boolean {
  if (verdict == DscAppearanceVerdict.UNKNOWN) return false
  val stream = widget.appearance?.normalAppearance
    ?.takeIf { it.isStream }?.appearanceStream ?: return false
  val resources = stream.resources ?: return false
  val frame = resources.getXObject(COSName.getPDFName("FRM"))
    as? PDFormXObject ?: return false
  val layers = frame.resources ?: return false
  val required = listOf("n0", "n1", "n2", "n3", "n4")
  val old = required.associateWith { key ->
    layers.getXObject(COSName.getPDFName(key)) as? PDFormXObject
  }
  if (old.values.any { it == null }) return false
  // Original PDF Craft guards against opaque page-wide redrawing. Do not
  // attempt to replace an appearance which has no usable status form.
  // The visible signature's own signer block is always left as issued.
  for (key in listOf("n1", "n3", "n4")) {
    val box = old.getValue(key)!!.bBox
    if (!box.width.isFinite() || !box.height.isFinite() ||
        box.width <= 0f || box.height <= 0f ||
        box.width > 1000000f || box.height > 1000000f) return false
  }

  fun layer(key: String, draw: (PDPageContentStream, PDRectangle) -> Unit): PDAppearanceStream {
    val prior = old.getValue(key)!!
    val box = prior.bBox
    require(box.width > 0f && box.height > 0f &&
      box.width.isFinite() && box.height.isFinite()) {
      "Unusable original signature status layer rectangle"
    }
    val appearance = PDAppearanceStream(pdf).apply {
      bBox = box
      this.resources = PDResources()
    }
    // The original status layer may have a matrix and optional-content
    // visibility. Retain these from the REAL PDF (never invent coordinates).
    for (key in listOf(COSName.MATRIX, COSName.OC)) {
      prior.cosObject.getDictionaryObject(key)?.let {
        appearance.cosObject.setItem(key, it)
      }
    }
    PDPageContentStream(pdf, appearance).use { draw(it, box) }
    return appearance
  }
  val checked = verdict in setOf(DscAppearanceVerdict.VALID,
    DscAppearanceVerdict.VERIFIED_WITH_WARNINGS)
  val ink = if (checked) intArrayOf(25, 140, 70) else intArrayOf(190, 43, 44)
  val iconLayer = if (checked) "n1" else "n3"
  val blankLayer = if (checked) "n3" else "n1"
  val icon = layer(iconLayer) { stream, box ->
    // Lucide-style check/cross, centred *inside the original n1/n3 bbox*.
    // Fixed 100-unit drawing coordinates would overflow UIDAI signatures.
    val side = minOf(box.width, box.height)
    val x = box.lowerLeftX + (box.width-side)*.5f
    val y = box.lowerLeftY + (box.height-side)*.5f
    stream.setStrokingColor(ink[0], ink[1], ink[2])
    stream.setLineWidth((side*.085f).coerceAtLeast(.25f))
    if (checked) {
      stream.moveTo(x+side*.17f,y+side*.53f)
      stream.lineTo(x+side*.40f,y+side*.30f)
      stream.lineTo(x+side*.84f,y+side*.77f)
    } else {
      stream.moveTo(x+side*.20f,y+side*.20f)
      stream.lineTo(x+side*.80f,y+side*.80f)
      stream.moveTo(x+side*.20f,y+side*.80f)
      stream.lineTo(x+side*.80f,y+side*.20f)
    }
    stream.stroke()
  }
  val blank = layer(blankLayer) { _, _ -> }
  val caption = layer("n4") { stream, box ->
    val label = when (verdict) {
      DscAppearanceVerdict.VALID -> "Signature Valid"
      DscAppearanceVerdict.VERIFIED_WITH_WARNINGS -> "Integrity Verified*"
      DscAppearanceVerdict.INVALID -> "Signature Invalid"
      DscAppearanceVerdict.UNKNOWN -> "Not Verified"
    }
    val width = (box.width*.94f).coerceAtLeast(1f)
    val measured = PDType1Font.HELVETICA_BOLD.getStringWidth(label)/1000f
    val size = minOf(box.height*.62f, width/measured).coerceAtLeast(.25f)
    stream.setNonStrokingColor(ink[0], ink[1], ink[2])
    stream.beginText()
    stream.setFont(PDType1Font.HELVETICA_BOLD, size)
    stream.newLineAtOffset(box.lowerLeftX+box.width*.03f,
      box.lowerLeftY+(box.height-size*.72f)*.5f)
    stream.showText(label)
    stream.endText()
  }
  // Only rewrite an isolated, uniquely matched signature widget's resources.
  // Real verification is performed on unmodified bytes by DscVerifier.
  layers.put(COSName.getPDFName(iconLayer), icon)
  layers.put(COSName.getPDFName(blankLayer), blank)
  layers.put(COSName.getPDFName("n4"), caption)
  return true
}
