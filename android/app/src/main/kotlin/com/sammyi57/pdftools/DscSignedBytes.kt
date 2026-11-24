package com.sammyi57.pdftools

import java.security.MessageDigest

/**
 * Android adaptation of PdfCraft's byte-range checks (MIT, see
 * third_party/PDFCRAFT_DSC_NOTICE.md). Never verify reconstructed PDF bytes.
 * A later revision needs a separate structural/DocMDP assessment.
 */
internal object DscSignedBytes {
  data class Parts(val signed: ByteArray, val cms: ByteArray, val whole: Boolean)
  fun sha256(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

  fun read(bytes: ByteArray, range: IntArray): Parts {
    require(range.size == 4 && range[0] == 0 && range.all { it >= 0 }) { "Invalid ByteRange" }
    val a = range[1]
    val b = range[2]
    val end = b.toLong() + range[3]
    require(a > 0 && b.toLong() - a >= 2 && end <= bytes.size && range[3] > 0) {
      "ByteRange exceeds file or overlaps"
    }
    require(bytes[a] == '<'.code.toByte() && bytes[b - 1] == '>'.code.toByte()) {
      "ByteRange does not exclude exactly the signature contents"
    }
    require(b - a <= 4 * 1024 * 1024) { "Signature exceeds safety limit" }
    val cms = java.io.ByteArrayOutputStream()
    var hi = -1
    for (i in a + 1 until b - 1) {
      val ch = bytes[i].toInt() and 255
      if (ch in listOf(0, 9, 10, 12, 13, 32)) continue
      val digit = Character.digit(ch.toChar(), 16)
      require(digit >= 0) { "Signature contents are not hexadecimal" }
      if (hi < 0) hi = digit else { cms.write((hi shl 4) or digit); hi = -1 }
    }
    if (hi >= 0) cms.write(hi shl 4)
    require(cms.size() > 0) { "Empty signature" }
    val signed = ByteArray(a + range[3])
    bytes.copyInto(signed, 0, 0, a)
    bytes.copyInto(signed, a, b, end.toInt())
    return Parts(signed, cms.toByteArray(), end == bytes.size.toLong() ||
      (end.toInt() until bytes.size).all { (bytes[it].toInt() and 255) in listOf(0, 9, 10, 12, 13, 32) })
  }
}
