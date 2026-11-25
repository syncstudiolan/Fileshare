package com.sammyi57.pdftools

import org.junit.Assert.*
import org.junit.Test
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.util.Date

class DscPersonalTrustTest {
  @Test fun personalTrustCannotOverrideFailedChecks() {
    assertTrue(DscPersonalPolicy.accepted(true,true,true,true,true,false))
    assertFalse(DscPersonalPolicy.accepted(false,true,true,true,true,false))
    assertFalse(DscPersonalPolicy.accepted(true,false,true,true,true,false))
    assertFalse(DscPersonalPolicy.accepted(true,true,false,true,true,false))
    assertFalse(DscPersonalPolicy.accepted(true,true,true,false,true,false))
    assertFalse(DscPersonalPolicy.accepted(true,true,true,true,false,false))
    assertFalse(DscPersonalPolicy.accepted(true,true,true,true,true,true))
  }
  @Test fun certificateDecodedWithoutPrivateProviderFactory() {
    val key = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
    val name = X500Name("CN=DSC certificate decoding test")
    val now = System.currentTimeMillis()
    val holder = JcaX509v3CertificateBuilder(name, BigInteger.ONE,Date(now-60000),
      Date(now+60000),name,key.public).build(
      JcaContentSignerBuilder("SHA256withRSA").setProvider(DscCms.provider).build(key.private))
    val cert = DscCertificates.certificate(holder)
    assertArrayEquals(holder.encoded,cert.encoded)
    assertArrayEquals(key.public.encoded,cert.publicKey.encoded)
    cert.verify(key.public)
  }
}
