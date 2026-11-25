package com.sammyi57.pdftools

import com.tom_roush.pdfbox.cos.COSName
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
internal fun replaceDscNamedStatusLayers(
  pdf: PDDocument, widget: PDAnnotationWidget, verdict: DscAppearanceVerdict,
): Boolean {
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

  fun layer(key: String, draw: (PDPageContentStream) -> Unit): PDAppearanceStream {
    val prior = old.getValue(key)!!
    val appearance = PDAppearanceStream(pdf).apply {
      bBox = prior.bBox
      resources = PDResources()
    }
    PDPageContentStream(pdf, appearance).use(draw)
    return appearance
  }
  val checked = verdict in setOf(DscAppearanceVerdict.VALID,
    DscAppearanceVerdict.VERIFIED_WITH_WARNINGS)
  val ink = if (checked) intArrayOf(25, 140, 70) else intArrayOf(190, 43, 44)
  val iconLayer = if (checked) "n1" else "n3"
  val blankLayer = if (checked) "n3" else "n1"
  val icon = layer(iconLayer) { stream ->
    stream.setStrokingColor(ink[0], ink[1], ink[2])
    stream.setLineWidth(8f)
    if (checked) {
      stream.moveTo(16f, 51f)
      stream.lineTo(40f, 27f)
      stream.lineTo(85f, 78f)
    } else {
      stream.moveTo(22f, 22f)
      stream.lineTo(78f, 78f)
      stream.moveTo(22f, 78f)
      stream.lineTo(78f, 22f)
    }
    stream.stroke()
  }
  val blank = layer(blankLayer) { _ -> }
  val caption = layer("n4") { stream ->
    val label = when (verdict) {
      DscAppearanceVerdict.VALID -> "Signature Valid"
      DscAppearanceVerdict.VERIFIED_WITH_WARNINGS -> "Integrity Verified*"
      DscAppearanceVerdict.INVALID -> "Signature Invalid"
      DscAppearanceVerdict.UNKNOWN -> "Not Verified"
    }
    val box = old.getValue("n4")!!.bBox
    val width = (box.width - 2f).coerceAtLeast(1f)
    val measured = PDType1Font.HELVETICA_BOLD.getStringWidth(label)/1000f
    val size = minOf(4.7f, width/measured)
    stream.setNonStrokingColor(ink[0], ink[1], ink[2])
    stream.beginText()
    stream.setFont(PDType1Font.HELVETICA_BOLD, size)
    stream.newLineAtOffset(box.lowerLeftX+1f,box.lowerLeftY+2f)
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
