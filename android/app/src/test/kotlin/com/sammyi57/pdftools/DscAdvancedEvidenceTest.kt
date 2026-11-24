package com.sammyi57.pdftools

import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.X509CertificateHolder
import org.bouncycastle.cert.ocsp.*
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.bouncycastle.operator.jcajce.JcaDigestCalculatorProviderBuilder
import org.bouncycastle.asn1.x509.*
import org.bouncycastle.asn1.ASN1ObjectIdentifier
import org.bouncycastle.cms.jcajce.JcaSignerInfoGeneratorBuilder
import org.bouncycastle.cert.jcajce.JcaCertStore
import org.bouncycastle.tsp.*
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.math.BigInteger
import java.util.Date
import org.junit.Test

class DscAdvancedEvidenceTest {
 @Test fun signedOcspAndTimestampEvidence() {
  val p=DscCms.provider
  val now=Date()
  val kp=KeyPairGenerator.getInstance("RSA").apply{initialize(2048)}
  val root=kp.generateKeyPair();val leaf=kp.generateKeyPair();val other=kp.generateKeyPair()
  val name=X500Name("CN=Test CA")
  val before=Date(now.time-3600000);val after=Date(now.time+3600000)
  fun sign(k:java.security.KeyPair)=JcaContentSignerBuilder("SHA256withRSA").setProvider(p).build(k.private)
  fun cert(k:java.security.KeyPair,serial:Long,subject:X500Name,tsa:Boolean=false):X509CertificateHolder {
    val b=JcaX509v3CertificateBuilder(name,BigInteger.valueOf(serial),before,after,subject,k.public)
    if(tsa)b.addExtension(Extension.extendedKeyUsage,true,ExtendedKeyUsage(KeyPurposeId.id_kp_timeStamping))
    return b.build(sign(root))
  }
  val rh=cert(root,1,name);val lh=cert(leaf,2,X500Name("CN=Signer"))
  val conv=JcaX509CertificateConverter().setProvider(p);val rc=conv.getCertificate(rh);val lc=conv.getCertificate(lh)
  val dig=JcaDigestCalculatorProviderBuilder().setProvider(p).build()
  val id=CertificateID(dig.get(CertificateID.HASH_SHA1),rh,lc.serialNumber)
  fun response(status:CertificateStatus?,start:Date=Date(now.time-60000),end:Date=Date(now.time+60000),wrongId:Boolean=false,forged:Boolean=false):ByteArray {
    val b=BasicOCSPRespBuilder(RespID(name))
    b.addResponse(if(wrongId)CertificateID.deriveCertificateID(id,BigInteger.valueOf(9)) else id,status,start,end,null)
    val basic=b.build(sign(if(forged)other else root),arrayOf(rh),now)
    return OCSPRespBuilder().build(OCSPRespBuilder.SUCCESSFUL,basic).encoded
  }
  val good=response(null)
  check(DscOcsp.check(good,lc,rc,now,now)==DscOcsp.Verdict.GOOD)
  check(DscOcsp.check(response(RevokedStatus(Date(now.time-1000),0)),lc,rc,now,now)==DscOcsp.Verdict.REVOKED)
  check(DscOcsp.check(response(UnknownStatus()),lc,rc,now,now)==DscOcsp.Verdict.UNKNOWN)
  check(DscOcsp.check(response(null,wrongId=true),lc,rc,now,now)==DscOcsp.Verdict.UNKNOWN)
  check(DscOcsp.check(response(null,forged=true),lc,rc,now,now)==DscOcsp.Verdict.UNKNOWN)
  check(DscOcsp.check(response(null),lc,rc,Date(now.time+120000),now)==DscOcsp.Verdict.UNKNOWN)
  check(DscOcsp.check(byteArrayOf(1,2,3),lc,rc,now,now)==DscOcsp.Verdict.UNKNOWN)
  check(OCSPReq(DscOcsp.request(lc,rc)).requestList.single().certID==id)
  val tsa=cert(leaf,3,X500Name("CN=Test TSA"),true)
  val tsaCert=conv.getCertificate(tsa)
  val sig=JcaSignerInfoGeneratorBuilder(dig).build(sign(leaf),tsaCert)
  val generator=TimeStampTokenGenerator(sig,dig.get(AlgorithmIdentifier(org.bouncycastle.asn1.nist.NISTObjectIdentifiers.id_sha256)),ASN1ObjectIdentifier("1.2.3.4.5"))
  generator.addCertificates(JcaCertStore(listOf(tsaCert,rc)))
  val data="signed value".toByteArray()
  val req=TimeStampRequestGenerator().apply{setCertReq(true)}.generate(TSPAlgorithms.SHA256,MessageDigest.getInstance("SHA-256").digest(data))
  val token=generator.generate(req,BigInteger.ONE,now)
  check(DscTimestamp.check(token,data).signer==tsaCert)
  check(runCatching{DscTimestamp.check(token,"tampered".toByteArray())}.isFailure)
 }
}
