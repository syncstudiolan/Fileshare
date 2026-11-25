package com.sammyi57.pdftools

/** Plain HTTP is for signed public PKI evidence only. Not general web access.
 * Keep in sync with file_share_doc_network_security.xml. */
internal object DscHttpPolicy {
  private val domains = setOf("cca.gov.in", "ocvs.gov.in", "ca.igcar.gov.in", "crl.care4sign.com", "www.e-mudhra.com", "e-mudhra.com", "ocsp.e-mudhra.com")
  fun allowed(host: String): Boolean {
    val normalized = host.lowercase(java.util.Locale.ROOT)
    return normalized in domains || normalized == "www.cca.gov.in"
  }
}
