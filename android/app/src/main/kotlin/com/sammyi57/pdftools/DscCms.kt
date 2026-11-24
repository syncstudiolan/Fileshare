package com.sammyi57.pdftools

import org.bouncycastle.asn1.ASN1InputStream
import org.bouncycastle.asn1.pkcs.PKCSObjectIdentifiers
import org.bouncycastle.asn1.ess.SigningCertificateV2
import org.bouncycastle.asn1.cms.CMSObjectIdentifiers
import org.bouncycastle.cert.X509CertificateHolder
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cms.CMSProcessableByteArray
import org.bouncycastle.cms.CMSSignedData
import org.bouncycastle.cms.CMSSignerDigestMismatchException
import org.bouncycastle.cms.jcajce.JcaSimpleSignerInfoVerifierBuilder
import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.security.MessageDigest
import java.security.cert.X509Certificate

/** The Android CMS primitive. No network, UI or PDF writer dependencies. */
internal object DscCms {
  val provider = BouncyCastleProvider()
  data class Checked(val cms: CMSSignedData, val cert: X509Certificate,
    val embedded: List<X509Certificate>, val intact: Boolean, val strong: Boolean)
  private val digests = mapOf("2.16.840.1.101.3.4.2.1" to "SHA-256",
    "2.16.840.1.101.3.4.2.2" to "SHA-384", "2.16.840.1.101.3.4.2.3" to "SHA-512")

  fun check(signed: ByteArray, padded: ByteArray, pades: Boolean): Checked {
    // Read one CMS object, permitting only zero placeholder padding after it.
    // Keep its original encoding: do not rewrite the signed attributes.
    val stream = padded.inputStream()
    ASN1InputStream(stream).use { require(it.readObject() != null) { "Empty CMS" } }
    val consumed = padded.size - stream.available()
    require(consumed > 0 && (consumed until padded.size).all { padded[it] == 0.toByte() }) {
      "Unexpected data after CMS"
    }
    val encoded = padded.copyOf(consumed)
    val raw = CMSSignedData(encoded)
    require(raw.isDetachedSignature && raw.signedContentTypeOID == CMSObjectIdentifiers.data.id) {
      "Not a detached document signature"
    }
    val cms = CMSSignedData(CMSProcessableByteArray(signed), encoded)
    val signer = cms.signerInfos.signers.singleOrNull() ?: error("Unsupported CMS signer count")
    val holders = cms.certificates.getMatches(null).filterIsInstance<X509CertificateHolder>()
    val holder = holders.singleOrNull { signer.sid.match(it) } ?: error("Missing or ambiguous signer certificate")
    val converter = JcaX509CertificateConverter().setProvider(provider)
    val cert = converter.getCertificate(holder)
    val embedded = holders.map { converter.getCertificate(it) }
    val intact = try {
      // Use the public key to check integrity separately from certificate dates.
      signer.verify(JcaSimpleSignerInfoVerifierBuilder().setProvider(provider).build(cert.publicKey))
    } catch (_: CMSSignerDigestMismatchException) { false }
    val attributes = signer.signedAttributes
    val ess = attributes?.getAll(PKCSObjectIdentifiers.id_aa_signingCertificateV2)
    val binding = if (ess != null && ess.size() == 1) {
      val attr = attributes.get(PKCSObjectIdentifiers.id_aa_signingCertificateV2)
      val first = if (attr.attrValues.size() == 1)
        SigningCertificateV2.getInstance(attr.attrValues.getObjectAt(0)).certs.firstOrNull() else null
      val algorithm = first?.let { digests[it.hashAlgorithm.algorithm.id] }
      first != null && algorithm != null &&
        MessageDigest.isEqual(first.certHash, MessageDigest.getInstance(algorithm).digest(cert.encoded))
    } else !pades && (ess == null || ess.size() == 0)
    val strong = signer.digestAlgOID in digests && binding &&
      ((cert.publicKey as? java.security.interfaces.RSAPublicKey)?.modulus?.bitLength() ?: 2048) >= 2048
    return Checked(cms, cert, embedded, intact, strong)
  }
}
