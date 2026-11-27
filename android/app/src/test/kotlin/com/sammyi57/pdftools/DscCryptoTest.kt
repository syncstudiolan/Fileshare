package com.sammyi57.pdftools

import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.cert.jcajce.JcaCertStore
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cms.CMSProcessableByteArray
import org.bouncycastle.cms.CMSSignedDataGenerator
import org.bouncycastle.cms.jcajce.JcaSignerInfoGeneratorBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.bouncycastle.operator.jcajce.JcaDigestCalculatorProviderBuilder
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.util.Date
import org.junit.Assert.*
import org.junit.Test

class DscCryptoTest {
  private val bytes = "PDF signature test bytes".toByteArray()
  private fun signature(attached: Boolean = false): ByteArray {
    val provider = DscCms.provider
    val key = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
    val name = X500Name("CN=File Share synthetic DSC test")
    val now = System.currentTimeMillis()
    val holder = JcaX509v3CertificateBuilder(name, BigInteger.ONE,
      Date(now - 60000), Date(now + 600000), name, key.public)
      .build(JcaContentSignerBuilder("SHA256withRSA").setProvider(provider).build(key.private))
    val cert = JcaX509CertificateConverter().setProvider(provider).getCertificate(holder)
    val generator = CMSSignedDataGenerator()
    generator.addSignerInfoGenerator(JcaSignerInfoGeneratorBuilder(
      JcaDigestCalculatorProviderBuilder().setProvider(provider).build()).build(
      JcaContentSignerBuilder("SHA256withRSA").setProvider(provider).build(key.private), cert))
    generator.addCertificates(JcaCertStore(listOf(cert)))
    return generator.generate(CMSProcessableByteArray(bytes), attached).encoded
  }

  @Test fun realDetachedCmsAndTampering() {
    val cms = signature()
    assertTrue(DscCms.check(bytes, cms, false).intact)
    assertTrue(DscCms.check(bytes, cms, false).strong)
    assertFalse(DscCms.check(bytes.copyOf().apply { this[0] = 0 }, cms, false).intact)
  }

  @Test fun noFalsePadesCertificateBinding() {
    val checked = DscCms.check(bytes, signature(), true)
    assertTrue(checked.intact)
    assertFalse(checked.strong)
  }

  @Test fun rejectsEmbeddedContentAndTrailingData() {
    assertTrue(runCatching { DscCms.check(bytes, signature(true), false) }.isFailure)
    val cms = signature()
    assertTrue(DscCms.check(bytes, cms + ByteArray(64), false).intact)
    assertTrue(runCatching { DscCms.check(bytes, cms + byteArrayOf(1), false) }.isFailure)
  }

  @Test fun preservesSignedBytesAndDetectsLaterRevision() {
    val raw = "abc<0102>def".toByteArray()
    val range = intArrayOf(0,3,9,3)
    val parts = DscSignedBytes.read(raw, range)
    assertArrayEquals("abcdef".toByteArray(), parts.signed)
    assertArrayEquals(byteArrayOf(1,2), parts.cms)
    assertTrue(parts.whole)
    assertFalse(DscSignedBytes.read(raw + "new".toByteArray(), range).whole)
  }

  @Test fun rejectsMalformedRanges() {
    val raw = "abc<0102>def".toByteArray()
    assertTrue(runCatching { DscSignedBytes.read(raw, intArrayOf(0,5,4,3)) }.isFailure)
    assertTrue(runCatching { DscSignedBytes.read(raw, intArrayOf(0,3,9,Int.MAX_VALUE)) }.isFailure)
    assertTrue(runCatching { DscSignedBytes.read("abc<GGGG>def".toByteArray(), intArrayOf(0,3,9,3)) }.isFailure)
  }
}
