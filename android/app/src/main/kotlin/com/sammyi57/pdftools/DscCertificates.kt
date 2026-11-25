package com.sammyi57.pdftools

import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.cert.X509CRL
import org.bouncycastle.cert.X509CertificateHolder
import org.bouncycastle.cert.X509CRLHolder

/**
 * Decode public certificates with the platform X.509 factory first. The
 * app's private BC instance remains the cryptographic provider, not the
 * Android system's reduced "BC" provider. No provider is globally installed.
 */
internal object DscCertificates {
  private fun factory() = CertificateFactory.getInstance("X.509")

  /** Read the actual CN rather than printing a long encoded distinguished name. */
  fun displayName(cert: X509Certificate): String = runCatching {
    val name = org.bouncycastle.asn1.x500.X500Name.getInstance(cert.subjectX500Principal.encoded)
    name.getRDNs(org.bouncycastle.asn1.x500.style.BCStyle.CN).firstOrNull()?.first?.value?.let {
      org.bouncycastle.asn1.x500.style.IETFUtils.valueToString(it)
    }?.takeIf { it.isNotBlank() }?.take(200) ?: cert.subjectX500Principal.name
  }.getOrDefault(cert.subjectX500Principal.name)

  fun certificate(holder: X509CertificateHolder): X509Certificate =
    factory().generateCertificate(holder.encoded.inputStream()) as X509Certificate

  fun crl(holder: X509CRLHolder): X509CRL =
    factory().generateCRL(holder.encoded.inputStream()) as X509CRL

  fun decode(bytes: ByteArray): X509Certificate =
    factory().generateCertificate(bytes.inputStream()) as X509Certificate

  fun parse(bytes: ByteArray): List<X509Certificate> =
    factory().generateCertificates(bytes.inputStream()).filterIsInstance<X509Certificate>()
}
