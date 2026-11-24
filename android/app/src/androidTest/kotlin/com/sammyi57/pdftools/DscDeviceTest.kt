package com.sammyi57.pdftools

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.interactive.digitalsignature.PDSignature
import com.tom_roush.pdfbox.pdmodel.interactive.digitalsignature.SignatureInterface
import com.tom_roush.pdfbox.cos.COSName
import kotlinx.coroutines.runBlocking
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.BasicConstraints
import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.asn1.x509.KeyUsage
import org.bouncycastle.cert.jcajce.JcaCertStore
import org.bouncycastle.cert.jcajce.JcaCRLStore
import org.bouncycastle.cert.jcajce.JcaX509CRLConverter
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v2CRLBuilder
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.cms.CMSProcessableByteArray
import org.bouncycastle.cms.CMSSignedDataGenerator
import org.bouncycastle.cms.jcajce.JcaSignerInfoGeneratorBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.bouncycastle.operator.jcajce.JcaDigestCalculatorProviderBuilder
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.util.Date

/**
 * Run on an ARM64 Android device with -PfileshareDscRust=true.
 * Uses an isolated synthetic CA, generated for this test only. Never uses
 * customer PDF data, signing keys or a live CA server.
 */
@RunWith(AndroidJUnit4::class)
class DscDeviceTest {
  @Before fun init() {
    appContext = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
    PDFBoxResourceLoader.init(appContext)
  }

  @Test fun nativeEngineAndPinnedRootArePackaged() {
    assertTrue("Native Rust library is absent or cannot be loaded", DscRustBridge.available)
    val root = DscRoots.bundled().single()
    assertEquals(DscRoots.CURRENT, DscSignedBytes.sha256(root.encoded))
    assertTrue(DscRoots.isPinned(root))
    assertTrue(DscRustBridge.inspect(byteArrayOf(1,2,3), null, listOf(root)).isEmpty())
  }

  @Test fun realPdfSignatureTamperAndBytePreservingCart() = runBlocking {
    val p = DscCms.provider
    val now = System.currentTimeMillis()
    val generator = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }
    val rootKey = generator.generateKeyPair()
    val leafKey = generator.generateKeyPair()
    val rootName = X500Name("CN=File Share synthetic DSC CA " + now)
    val leafName = X500Name("CN=File Share synthetic document signer")
    val rootSigner = { JcaContentSignerBuilder("SHA256withRSA").setProvider(p).build(rootKey.private) }
    val leafSigner = { JcaContentSignerBuilder("SHA256withRSA").setProvider(p).build(leafKey.private) }
    val from = Date(now - 600000L)
    val until = Date(now + 600000L)
    val cv = JcaX509CertificateConverter().setProvider(p)
    val root = cv.getCertificate(JcaX509v3CertificateBuilder(rootName,BigInteger.ONE,from,until,rootName,rootKey.public)
      .addExtension(Extension.basicConstraints,true,BasicConstraints(true))
      .addExtension(Extension.keyUsage,true,KeyUsage(KeyUsage.keyCertSign or KeyUsage.cRLSign))
      .build(rootSigner()))
    val leaf = cv.getCertificate(JcaX509v3CertificateBuilder(rootName,BigInteger.valueOf(2),from,until,leafName,leafKey.public)
      .addExtension(Extension.basicConstraints,true,BasicConstraints(false))
      .addExtension(Extension.keyUsage,true,KeyUsage(KeyUsage.digitalSignature))
      .build(rootSigner()))
    val crl = JcaX509CRLConverter().setProvider(p).getCRL(
      JcaX509v2CRLBuilder(rootName,Date(now-60000)).setNextUpdate(Date(now+300000)).build(rootSigner()))
    val input = File.createTempFile("dsc-device-original-", ".pdf", appContext.cacheDir)
    val signed = File.createTempFile("dsc-device-signed-", ".pdf", appContext.cacheDir)
    val changed = File.createTempFile("dsc-device-tampered-", ".pdf", appContext.cacheDir)
    var cart: File? = null
    try {
      DscTrust.add(root,DscSignedBytes.sha256(root.encoded))
      PDDocument().use { it.addPage(PDPage()); it.save(input) }
      PDDocument.load(input).use { pdf ->
        val sig = PDSignature().apply {
          setFilter(PDSignature.FILTER_ADOBE_PPKLITE)
          setSubFilter(PDSignature.SUBFILTER_ADBE_PKCS7_DETACHED)
          setSignDate(java.util.Calendar.getInstance())
        }
        pdf.addSignature(sig, SignatureInterface { stream ->
          val cms = CMSSignedDataGenerator()
          cms.addSignerInfoGenerator(JcaSignerInfoGeneratorBuilder(
            JcaDigestCalculatorProviderBuilder().setProvider(p).build()).build(leafSigner(),leaf))
          cms.addCertificates(JcaCertStore(listOf(leaf,root)))
          cms.addCRLs(JcaCRLStore(listOf(crl)))
          cms.generate(CMSProcessableByteArray(stream.readBytes()),false).encoded
        })
        signed.outputStream().use { pdf.saveIncremental(it) }
      }
      val verdict = DscVerifier.read(signed.path,null).signatures.single()
      assertTrue("Signature must be cryptographically intact",verdict.integrity)
      assertTrue("Synthetic chain must build",verdict.trusted)
      assertEquals("Good",verdict.revocation)
      assertEquals(DscStatus.VALID,verdict.status)
      val native = DscRustBridge.inspect(signed.readBytes(),null,listOf(root))
      assertTrue("Native signature discovery and certificate binding must work",
        native.any { it.fingerprint == DscSignedBytes.sha256(leaf.encoded) && it.status != "invalid" })
      val hash = DscSignedBytes.sha256(signed.readBytes())
      cart = preparePdfSend(signed.path,"signed.pdf","all",1,"",false,true,hash)
      assertArrayEquals(signed.readBytes(),cart.readBytes())
      val bytes = signed.readBytes()
      // Change only the header version digit, keeping offsets and PDF parsing intact.
      assertTrue(String(bytes.copyOfRange(0,5), Charsets.US_ASCII) == "%PDF-")
      bytes[7] = if(bytes[7] == '4'.code.toByte()) '5'.code.toByte() else '4'.code.toByte()
      changed.writeBytes(bytes)
      val invalid = DscVerifier.read(changed.path,null).signatures.single()
      assertEquals(DscStatus.INVALID,invalid.status)
      assertTrue(runCatching { preparePdfSend(changed.path,"changed.pdf","all",1,"",false,true,hash) }.isFailure)
    } finally {
      DscTrust.remove(root)
      input.delete(); signed.delete(); changed.delete(); cart?.delete()
    }
  }
}
