package com.sammyi57.pdftools

import org.bouncycastle.asn1.cms.ContentInfo
import org.bouncycastle.asn1.ASN1InputStream
import org.bouncycastle.asn1.pkcs.PKCSObjectIdentifiers
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cms.CMSSignedData
import org.bouncycastle.cms.jcajce.JcaSimpleSignerInfoVerifierBuilder
import org.bouncycastle.tsp.TimeStampToken
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.util.Date

/** RFC3161 timestamp must cover the exact signature value, not a claimed date. */
internal object DscTimestamp {
  data class Evidence(val time: Date, val signer: X509Certificate,
    val certificates: List<X509Certificate>, val cms: CMSSignedData)
  private val algorithms = mapOf("2.16.840.1.101.3.4.2.1" to "SHA-256",
    "2.16.840.1.101.3.4.2.2" to "SHA-384", "2.16.840.1.101.3.4.2.3" to "SHA-512")

  fun attached(cms: CMSSignedData): Evidence? = runCatching {
    val signer = cms.signerInfos.signers.single()
    val attributes = signer.unsignedAttributes ?: return null
    val all = attributes.getAll(PKCSObjectIdentifiers.id_aa_signatureTimeStampToken)
    require(all.size() == 1)
    val attribute = attributes.get(PKCSObjectIdentifiers.id_aa_signatureTimeStampToken)
    require(attribute.attrValues.size() == 1)
    val token = TimeStampToken(ContentInfo.getInstance(attribute.attrValues.getObjectAt(0)))
    check(token, signer.signature)
  }.getOrNull()

  fun document(padded: ByteArray, covered: ByteArray): Evidence {
    val input = padded.inputStream()
    val obj = ASN1InputStream(input).use { it.readObject() ?: error("Empty timestamp") }
    val consumed = padded.size - input.available()
    require(consumed > 0 && (consumed until padded.size).all { padded[it] == 0.toByte() }) {
      "Unexpected trailing timestamp bytes"
    }
    return check(TimeStampToken(ContentInfo.getInstance(obj)), covered)
  }

  fun check(token: TimeStampToken, covered: ByteArray): Evidence {
    val info = token.timeStampInfo
    val algorithm = algorithms[info.messageImprintAlgOID.id] ?: error("Unsupported timestamp digest")
    require(MessageDigest.isEqual(info.messageImprintDigest,
      MessageDigest.getInstance(algorithm).digest(covered))) { "Timestamp imprint mismatch" }
    require(info.genTime.time <= System.currentTimeMillis() + 300000L)
    val holders = token.certificates.getMatches(null)
    val holder = holders.single { token.sid.match(it) }
    val provider = DscCms.provider
    token.validate(JcaSimpleSignerInfoVerifierBuilder().setProvider(provider).build(holder))
    val converter = JcaX509CertificateConverter().setProvider(provider)
    val cert = converter.getCertificate(holder)
    cert.checkValidity(info.genTime)
    return Evidence(info.genTime, cert, holders.map { converter.getCertificate(it) }, token.toCMSSignedData())
  }
}
