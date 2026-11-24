package com.sammyi57.pdftools

import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.cert.X509CertificateHolder
import org.bouncycastle.cert.ocsp.*
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.operator.jcajce.JcaContentVerifierProviderBuilder
import org.bouncycastle.operator.jcajce.JcaDigestCalculatorProviderBuilder
import java.security.cert.X509Certificate
import java.util.Date

/** Verify signed OCSP evidence, never trust the HTTP response status by itself. */
internal object DscOcsp {
  enum class Verdict { GOOD, REVOKED, UNKNOWN }
  private val provider = DscCms.provider
  private val digests get() = JcaDigestCalculatorProviderBuilder().setProvider(provider).build()
  fun request(cert: X509Certificate, issuer: X509Certificate): ByteArray =
    OCSPReqBuilder().addRequest(CertificateID(digests.get(CertificateID.HASH_SHA1),
      X509CertificateHolder(issuer.encoded), cert.serialNumber)).build().encoded

  fun check(bytes: ByteArray, cert: X509Certificate, issuer: X509Certificate,
      at: Date, now: Date = Date()): Verdict = runCatching {
    require(bytes.size in 1..(1024 * 1024))
    val response = OCSPResp(bytes)
    require(response.status == OCSPResp.SUCCESSFUL)
    val basic = response.responseObject as? BasicOCSPResp ?: error("Unsupported OCSP response")
    require(basic.criticalExtensionOIDs.isNullOrEmpty())
    require(basic.producedAt.time <= now.time + 300000L)
    val issuerHolder = X509CertificateHolder(issuer.encoded)
    val converter = JcaX509CertificateConverter().setProvider(provider)
    val candidates = (listOf(issuer) + basic.certs.map { converter.getCertificate(it) })
      .distinctBy { DscSignedBytes.sha256(it.encoded) }
    val signer = candidates.firstOrNull { candidate ->
      runCatching {
        candidate.checkValidity(basic.producedAt)
        val holder = X509CertificateHolder(candidate.encoded)
        val id = basic.responderId
        val matchesId = id == RespID(holder.subject) ||
          id == RespID(holder.subjectPublicKeyInfo, digests.get(RespID.HASH_SHA1))
        val authorized = candidate == issuer || (
          candidate.issuerX500Principal == issuer.subjectX500Principal &&
          candidate.extendedKeyUsage?.contains("1.3.6.1.5.5.7.3.9") == true &&
          candidate.getExtensionValue("1.3.6.1.5.5.7.48.1.5") != null &&
          !candidate.hasUnsupportedCriticalExtension() &&
          (candidate.keyUsage?.getOrElse(0){false} ?: true) &&
          run { candidate.verify(issuer.publicKey, provider); true }
        )
        matchesId && authorized && basic.isSignatureValid(
          JcaContentVerifierProviderBuilder().setProvider(provider).build(candidate.publicKey))
      }.getOrDefault(false)
    } ?: error("OCSP responder not authorized")
    require(signer.publicKey.algorithm.isNotBlank())
    val matches = basic.responses.filter {
      it.certID.serialNumber == cert.serialNumber && it.certID.matchesIssuer(issuerHolder, digests)
    }
    require(matches.size == 1)
    val single = matches.single()
    require(single.criticalExtensionOIDs.isNullOrEmpty())
    val next = single.nextUpdate ?: error("OCSP nextUpdate missing")
    require(single.thisUpdate <= at && next >= at &&
      single.thisUpdate <= basic.producedAt && basic.producedAt <= next)
    when (val status = single.certStatus) {
      null -> Verdict.GOOD
      is RevokedStatus -> if(status.revocationTime <= at) Verdict.REVOKED else Verdict.UNKNOWN
      else -> Verdict.UNKNOWN
    }
  }.getOrDefault(Verdict.UNKNOWN)
}
