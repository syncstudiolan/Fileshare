package com.sammyi57.pdftools

import java.security.cert.X509Certificate
import java.security.cert.CertificateFactory

/** Only independently pinned document-signing roots, never the PDF's claim of trust. */
internal object DscRoots {
  // CCA root list + independent Microsoft CCADB document-signing record.
  const val CURRENT = "9a3fd3176798e842ddcb12c262f11cfacca70a8b84c6ea6fda30842a95a94cd8"
  // Expired root: eligible only at a verified historical validation time.
  const val HISTORICAL = "60109bc6c38328598a112c7a25e38b0f23e5a7511cb815fb64e0c4ff05db7df7"
  fun isPinned(cert: X509Certificate): Boolean = runCatching {
    DscSignedBytes.sha256(cert.encoded) in setOf(CURRENT,HISTORICAL) &&
      cert.basicConstraints >= 0 && cert.subjectX500Principal == cert.issuerX500Principal &&
      !cert.hasUnsupportedCriticalExtension() &&
      (cert.keyUsage?.getOrElse(5){false} ?: true) &&
      run { cert.verify(cert.publicKey); true }
  }.getOrDefault(false)

  fun bundled(): List<X509Certificate> = runCatching {
    appContext.assets.open("dsc/CCAIndia2022.pem").use {
      val cert = CertificateFactory.getInstance("X.509").generateCertificate(it) as X509Certificate
      require(DscSignedBytes.sha256(cert.encoded) == CURRENT && isPinned(cert))
      listOf(cert)
    }
  }.getOrDefault(emptyList())
}
