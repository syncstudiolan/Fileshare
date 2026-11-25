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

  fun certificate(holder: X509CertificateHolder): X509Certificate =
    factory().generateCertificate(holder.encoded.inputStream()) as X509Certificate

  fun crl(holder: X509CRLHolder): X509CRL =
    factory().generateCRL(holder.encoded.inputStream()) as X509CRL

  fun decode(bytes: ByteArray): X509Certificate =
    factory().generateCertificate(bytes.inputStream()) as X509Certificate

  fun parse(bytes: ByteArray): List<X509Certificate> =
    factory().generateCertificates(bytes.inputStream()).filterIsInstance<X509Certificate>()
}
