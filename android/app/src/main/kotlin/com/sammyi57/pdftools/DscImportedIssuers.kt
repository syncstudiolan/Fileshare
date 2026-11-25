package com.sammyi57.pdftools

import java.io.File
import java.security.cert.X509Certificate

/** Downloaded intermediates are chain-building material, not trust anchors. */
internal object DscImportedIssuers {
  private fun directory() = File(appContext.filesDir,"dsc_imported_issuers").apply { mkdirs() }
  private fun target(cert: X509Certificate) = File(directory(),DscSignedBytes.sha256(cert.encoded)+".cer")
  fun load(): List<X509Certificate> = directory().listFiles().orEmpty()
    .filter { it.extension == "cer" && it.length() in 1L..131072L }.take(256)
    .mapNotNull { file -> runCatching {
      DscCertificates.decode(file.readBytes()).takeIf { it.basicConstraints >= 0 && target(it).name == file.name }
    }.getOrNull() }
  @Synchronized fun add(cert: X509Certificate) {
    require(cert.basicConstraints >= 0 && cert.encoded.size in 1..131072) { "Select an issuer CA certificate" }
    require(cert.subjectX500Principal != cert.issuerX500Principal) { "Root certificates require independent trust confirmation" }
    val dest = target(cert)
    require(dest.exists() || load().size < 256) { "Issuer store is full" }
    val tmp = File.createTempFile("issuer-",".tmp",directory())
    try {
      tmp.writeBytes(cert.encoded)
      check(tmp.renameTo(dest)) { "Unable to save issuer certificate" }
    } finally { tmp.delete() }
  }
  fun remove(cert: X509Certificate) { target(cert).delete() }
}
