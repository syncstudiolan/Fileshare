package com.sammyi57.pdftools

import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.Signature
import java.util.Date
import org.bouncycastle.asn1.DEROctetString
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaCertStore
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.cms.CMSProcessableByteArray
import org.bouncycastle.cms.CMSSignedDataGenerator
import org.bouncycastle.cms.jcajce.JcaSignerInfoGeneratorBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.bouncycastle.operator.jcajce.JcaDigestCalculatorProviderBuilder
import org.junit.Assert.*
import org.junit.Test

class DscLegacyPolicyTest {
  @Test fun bothLegacyAdobeFormatsVerifyButDoNotReceiveCurrentPolicyGreenTick() {
    val provider = DscCms.provider
    val bytes = "synthetic PDF signed bytes".toByteArray()
    val key = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
    val name = X500Name("CN=Test legacy signature")
    val now = System.currentTimeMillis()
    fun signer() = JcaContentSignerBuilder("SHA256withRSA").setProvider(provider).build(key.private)
    val cert = JcaX509CertificateConverter().setProvider(provider).getCertificate(
      JcaX509v3CertificateBuilder(name, BigInteger.ONE, Date(now-60000), Date(now+60000), name,key.public)
        .build(signer()))
    val generator = CMSSignedDataGenerator()
    generator.addSignerInfoGenerator(JcaSignerInfoGeneratorBuilder(
      JcaDigestCalculatorProviderBuilder().setProvider(provider).build()).build(signer(),cert))
    generator.addCertificates(JcaCertStore(listOf(cert)))
    val sha1 = MessageDigest.getInstance("SHA-1").digest(bytes)
    val cms = generator.generate(CMSProcessableByteArray(sha1),true).encoded
    val result = DscCms.check(bytes,cms,false,true)
    assertTrue(result.intact)
    assertFalse(result.strong)
    assertFalse(DscCms.check(bytes+1,cms,false,true).intact)
    assertTrue(runCatching { DscCms.check(bytes,cms,false) }.isFailure)
    val detached = generator.generate(CMSProcessableByteArray(bytes),false).encoded
    assertTrue(runCatching { DscCms.check(bytes,detached,false,true) }.isFailure)
    val legacy = Signature.getInstance("SHA1withRSA",provider).run {
      initSign(key.private); update(bytes); DEROctetString(sign()).encoded
    }
    assertTrue(DscLegacy.verify(bytes,legacy,cert))
    assertFalse(DscLegacy.verify(bytes+1,legacy,cert))
    assertTrue(DscLegacy.verify(bytes,legacy+ByteArray(32),cert))
    assertTrue(runCatching { DscLegacy.verify(bytes,legacy+byteArrayOf(1),cert) }.isFailure)
  }

  @Test fun legacyVerificationRequiresRealIntegrityAndTrustedChain() {
    fun verdict(format: Boolean = true, integrity: Boolean = true, revision: Boolean = true,
        usage: Boolean = true, current: Boolean = true, trusted: Boolean = true,
        nativeRejected: Boolean = false, revoked: Boolean = false) =
      DscVerdictPolicy.legacyVerified(format, integrity, revision, usage, current, trusted, nativeRejected, revoked)
    assertTrue(verdict())
    assertFalse(verdict(format = false))
    assertFalse(verdict(integrity = false))
    assertFalse(verdict(revision = false))
    assertFalse(verdict(usage = false))
    assertFalse(verdict(current = false))
    assertFalse(verdict(trusted = false))
    assertFalse(verdict(nativeRejected = true))
    assertFalse(verdict(revoked = true))
  }

  @Test fun nativeLegacyPresentationRequiresBothIndependentProofs() {
    assertTrue(DscVerdictPolicy.legacyNativeVerified(true,true,true))
    assertFalse(DscVerdictPolicy.legacyNativeVerified(false,true,true))
    assertFalse(DscVerdictPolicy.legacyNativeVerified(true,false,true))
    assertFalse(DscVerdictPolicy.legacyNativeVerified(true,true,false))
  }

  @Test fun onlyExplicitCleartextEvidenceHostsAreAllowed() {
    assertTrue(DscHttpPolicy.allowed("OCVS.GOV.IN"))
    assertTrue(DscHttpPolicy.allowed("cca.gov.in"))
    assertFalse(DscHttpPolicy.allowed("ocvs.gov.in.example.org"))
    assertFalse(DscHttpPolicy.allowed("127.0.0.1"))
    assertFalse(DscHttpPolicy.allowed("example.org"))
  }
}
