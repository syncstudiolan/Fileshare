package com.sammyi57.pdftools

import java.io.File
import java.security.cert.X509Certificate

/** Personal signer trust is separate from CA trust, never a PKIX trust anchor. */
internal object DscSignerTrust {
  private fun directory() = File(appContext.filesDir, "dsc_signer_trust").apply { mkdirs() }
  private fun target(cert: X509Certificate) = File(directory(), DscSignedBytes.sha256(cert.encoded) + ".cer")
  fun contains(cert: X509Certificate): Boolean = runCatching {
    val file = target(cert)
    file.isFile && file.length() in 1L..131072L && file.readBytes().contentEquals(cert.encoded)
  }.getOrDefault(false)
  fun load(): List<X509Certificate> = directory().listFiles().orEmpty()
    .filter { it.extension == "cer" && it.length() in 1L..131072L }.take(256)
    .mapNotNull { file -> runCatching {
      DscCertificates.decode(file.readBytes()).takeIf { target(it).name == file.name }
    }.getOrNull() }
  @Synchronized fun add(cert: X509Certificate) {
    require(cert.encoded.size in 1..131072)
    require(contains(cert) || load().size < 256) { "Signer trust store is full" }
    val file = File.createTempFile("signer-", ".tmp", directory())
    try {
      file.writeBytes(cert.encoded)
      check(file.renameTo(target(cert))) { "Unable to save signer trust" }
    } finally { file.delete() }
  }
  fun remove(cert: X509Certificate) { target(cert).delete() }
}

/** Policy is testable without Android or a UI. A personal tick is not a
 * CA-backed/revocation-confirmed green tick, even when the user trusts a signer. */
internal object DscPersonalPolicy {
  fun accepted(explicitTrust: Boolean, integrity: Boolean, modernPolicy: Boolean,
      currentlyValid: Boolean, nativeValid: Boolean, revoked: Boolean): Boolean =
    explicitTrust && integrity && modernPolicy && currentlyValid && nativeValid && !revoked
}
