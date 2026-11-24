package com.sammyi57.pdftools

import java.security.Signature
import java.security.cert.X509Certificate
import org.bouncycastle.asn1.ASN1InputStream
import org.bouncycastle.asn1.ASN1OctetString

/** Legacy Adobe X.509 RSA/SHA-1 cryptographic integrity only.
 * Weak legacy hashes must never be promoted to current-policy Valid. */
internal object DscLegacy {
  fun verify(signed: ByteArray, padded: ByteArray, cert: X509Certificate): Boolean {
    val input = padded.inputStream()
    val signature = ASN1InputStream(input).use {
      val value = it.readObject() ?: error("Empty legacy signature")
      require(value is ASN1OctetString) { "Legacy signature must be an ASN.1 octet string" }
      value.octets
    }
    val consumed = padded.size - input.available()
    require(consumed > 0 && (consumed until padded.size).all { padded[it] == 0.toByte() }) {
      "Unexpected data after legacy signature"
    }
    require(cert.publicKey.algorithm == "RSA")
    return Signature.getInstance("SHA1withRSA", DscCms.provider).run {
      initVerify(cert.publicKey)
      update(signed)
      verify(signature)
    }
  }
}
