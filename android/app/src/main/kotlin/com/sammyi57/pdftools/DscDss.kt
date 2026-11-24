package com.sammyi57.pdftools

import com.tom_roush.pdfbox.cos.COSArray
import com.tom_roush.pdfbox.cos.COSDictionary
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.cos.COSStream
import com.tom_roush.pdfbox.pdmodel.PDDocument
import java.io.ByteArrayOutputStream
import java.security.cert.X509Certificate
import java.security.cert.X509CRL
import java.security.cert.CertificateFactory

/** Untrusted embedded evidence. Only cryptographically authenticated entries
 * can influence the result. Bounded decoding, no modification of the PDF. */
internal object DscDss {
  data class Evidence(val certificates: List<X509Certificate> = emptyList(),
    val crls: List<X509CRL> = emptyList(), val ocsps: List<ByteArray> = emptyList())
  fun read(pdf: PDDocument): Evidence {
    val dss = pdf.documentCatalog.cosObject.getDictionaryObject(COSName.getPDFName("DSS"))
      as? COSDictionary ?: return Evidence()
    var total = 0
    var count = 0
    val seen = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<COSStream, Boolean>())
    fun entries(name: String): List<ByteArray> {
      val array = dss.getDictionaryObject(COSName.getPDFName(name)) as? COSArray ?: return emptyList()
      require(array.size() <= 1024) { "DSS entry limit exceeded" }
      val result = mutableListOf<ByteArray>()
      for(i in 0 until array.size()) {
        val stream = array.getObject(i) as? COSStream ?: continue
        if(!seen.add(stream)) continue
        require(++count <= 256) { "DSS entry limit exceeded" }
        val out = ByteArrayOutputStream()
        stream.createInputStream().use { input ->
          val buffer = ByteArray(8192)
          while(true) {
            val n = input.read(buffer)
            if(n < 0) break
            total += n
            require(total <= 16 * 1024 * 1024 && out.size()+n <= 4 * 1024 * 1024) {
              "DSS evidence size limit exceeded"
            }
            out.write(buffer,0,n)
          }
        }
        result.add(out.toByteArray())
      }
      return result
    }
    val factory = CertificateFactory.getInstance("X.509")
    return Evidence(
      entries("Certs").mapNotNull { runCatching { factory.generateCertificate(it.inputStream()) as X509Certificate }.getOrNull() },
      entries("CRLs").mapNotNull { runCatching { factory.generateCRL(it.inputStream()) as X509CRL }.getOrNull() },
      entries("OCSPs"))
  }
}
