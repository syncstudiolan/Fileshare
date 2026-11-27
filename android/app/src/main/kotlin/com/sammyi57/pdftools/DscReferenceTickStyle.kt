package com.sammyi57.pdftools

import com.tom_roush.pdfbox.pdmodel.PDPageContentStream

/**
 * Pure appearance artwork. No signature verification, certificate logic,
 * trust decisions or original signed bytes are touched by this renderer.
 *
 * Reference: tapered, solid emerald check with a dark bevel/outline.
 * The middle joint is intentionally thinner than the rounded short-arm
 * entrance and the long-arm tip; a uniform-width stroked polyline is wrong.
 * Draw directly inside the existing status /AP XObject (not over the PDF).
 */
internal fun drawReferenceBeveledCheck(
  stream: PDPageContentStream, x: Float, y: Float,
  width: Float, height: Float,
) {
  require(width.isFinite() && height.isFinite() && width > 0f && height > 0f)

  fun contour(points: Array<FloatArray>) {
    stream.moveTo(x + width * points[0][0], y + height * points[0][1])
    for (point in points.drop(1))
      stream.lineTo(x + width * point[0], y + height * point[1])
    stream.closePath()
    stream.fill()
  }

  // Left arm is full at the entrance, neck tapers through the bend,
  // and the ascending arm broadens slightly towards its beveled cap.
  val silhouette = arrayOf(
    floatArrayOf(.055f,.505f), floatArrayOf(.169f,.637f),
    floatArrayOf(.378f,.395f), floatArrayOf(.806f,.930f),
    floatArrayOf(.953f,.822f), floatArrayOf(.451f,.144f),
    floatArrayOf(.346f,.117f), floatArrayOf(.158f,.359f),
  )
  stream.setNonStrokingColor(21,29,27)
  contour(silhouette)

  // Inset bright-green body follows the same taper, leaving an even
  // thin dark extrusion around the perimeter rather than a flat stroke.
  val body = arrayOf(
    floatArrayOf(.074f,.505f), floatArrayOf(.169f,.614f),
    floatArrayOf(.383f,.366f), floatArrayOf(.813f,.906f),
    floatArrayOf(.932f,.818f), floatArrayOf(.435f,.165f),
    floatArrayOf(.350f,.144f), floatArrayOf(.158f,.385f),
  )
  stream.setNonStrokingColor(21,165,65)
  contour(body)

  // Thin bevel facet on the outer rising edge supplies the 3D shape.
  // This stays *inside* the green body; it is not a second check mark.
  stream.setNonStrokingColor(11,118,48)
  contour(arrayOf(
    floatArrayOf(.435f,.165f), floatArrayOf(.932f,.818f),
    floatArrayOf(.813f,.906f), floatArrayOf(.397f,.376f),
    floatArrayOf(.418f,.304f),
  ))

  // Soft highlight towards the top arm adds depth, without covering text.
  stream.setNonStrokingColor(48,193,91)
  contour(arrayOf(
    floatArrayOf(.425f,.386f), floatArrayOf(.811f,.888f),
    floatArrayOf(.858f,.851f), floatArrayOf(.440f,.316f),
  ))
}
