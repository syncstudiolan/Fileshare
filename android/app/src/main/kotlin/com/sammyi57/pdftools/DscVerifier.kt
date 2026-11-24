package com.sammyi57.pdftools

import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDSignatureField
import org.bouncycastle.asn1.x509.CRLDistPoint
import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.asn1.x509.GeneralName
import org.bouncycastle.asn1.x509.GeneralNames
import org.bouncycastle.asn1.ASN1OctetString
import org.bouncycastle.cert.jcajce.JcaX509CRLConverter
import org.bouncycastle.cms.CMSSignedData
import java.io.File
import java.net.InetAddress
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import java.security.cert.*
import java.util.Date

internal enum class DscStatus { VALID, UNKNOWN, INVALID }
internal data class DscWidget(val page: Int, val left: Float, val top: Float, val right: Float, val bottom: Float)
internal data class DscResult(
  val id: String, val name: String, val status: DscStatus, val detail: String,
  val certificate: X509Certificate? = null, val chain: List<X509Certificate> = emptyList(),
  val integrity: Boolean = false, val trusted: Boolean = false,
  val revocation: String = "Not established", val widgets: List<DscWidget> = emptyList(),
)
internal data class DscDocument(val hash: String, val signatures: List<DscResult>)

internal object DscTrust {
  private val factory get() = CertificateFactory.getInstance("X.509")
  private fun directory() = File(appContext.filesDir, "dsc_trust").apply { mkdirs() }
  fun load(): List<X509Certificate> = directory().listFiles().orEmpty().take(256).mapNotNull { file ->
    runCatching { file.inputStream().use { factory.generateCertificate(it) as X509Certificate } }.getOrNull()
  }
  fun parse(bytes: ByteArray): List<X509Certificate> {
    require(bytes.size in 1..(2 * 1024 * 1024)) { "Certificate file exceeds limit" }
    return factory.generateCertificates(bytes.inputStream()).filterIsInstance<X509Certificate>()
      .also { require(it.isNotEmpty() && it.size <= 32) { "No supported certificates" } }
  }
  fun add(cert: X509Certificate) {
    val target = File(directory(), DscSignedBytes.sha256(cert.encoded) + ".cer")
    require(target.exists() || load().size < 256) { "Trust store is full" }
    val temp = File.createTempFile("cert-", ".tmp", directory())
    try { temp.writeBytes(cert.encoded); check(temp.renameTo(target)) { "Unable to save certificate" } }
    finally { temp.delete() }
  }
  fun remove(cert: X509Certificate) { File(directory(), DscSignedBytes.sha256(cert.encoded) + ".cer").delete() }
}

internal object DscVerifier {
  private val provider = DscCms.provider
  private const val MAX_PDF = 64 * 1024 * 1024L
  private val supported = setOf("adbe.pkcs7.detached", "ETSI.CAdES.detached")

  fun read(path: String, password: String?, online: Boolean = false): DscDocument {
    val file = File(path)
    require(file.length() in 1..MAX_PDF) { "PDF exceeds DSC verification safety limit (64 MB)" }
    val bytes = file.readBytes()
    require(bytes.size.toLong() <= MAX_PDF) { "PDF exceeds DSC verification safety limit" }
    val trust = DscTrust.load()
    val results = PDDocument.load(bytes, password.orEmpty()).use { pdf ->
      val fields = pdf.documentCatalog.acroForm?.fieldTree?.filterIsInstance<PDSignatureField>().orEmpty()
      val signatures = pdf.signatureDictionaries
      require(signatures.size <= 64) { "Too many signatures to check safely" }
      signatures.mapIndexed { index, sig ->
        val field = fields.firstOrNull { it.signature?.cosObject === sig.cosObject }
        val widgets = field?.widgets.orEmpty().mapNotNull { widget ->
          val rect = widget.rectangle ?: return@mapNotNull null
          val pageIndex = (0 until pdf.numberOfPages).firstOrNull { n ->
            val p = pdf.getPage(n)
            widget.page?.cosObject === p.cosObject || p.annotations.any { it.cosObject === widget.cosObject }
          } ?: return@mapNotNull null
          val p = pdf.getPage(pageIndex)
          val box = p.cropBox
          val rotation = ((p.rotation % 360) + 360) % 360
          fun point(x: Float, y: Float): Pair<Float,Float> {
            val u = x - box.lowerLeftX
            val v = y - box.lowerLeftY
            return when(rotation) {
              90 -> v to u
              180 -> (box.width-u) to v
              270 -> (box.height-v) to (box.width-u)
              else -> u to (box.height-v)
            }
          }
          val corners = listOf(point(rect.lowerLeftX, rect.lowerLeftY), point(rect.upperRightX, rect.upperRightY))
          DscWidget(pageIndex, corners.minOf { it.first }, corners.minOf { it.second },
            corners.maxOf { it.first }, corners.maxOf { it.second })
        }
        val id = "$index:" + (field?.fullyQualifiedName ?: "Signature")
        fun unknown(message: String) = DscResult(id, "Signature ${index+1}", DscStatus.UNKNOWN, message, widgets=widgets)
        if (sig.subFilter !in supported) unknown("Unsupported signature format: ${sig.subFilter}")
        else {
          val parts = try { DscSignedBytes.read(bytes, sig.byteRange) } catch(e: Exception) {
            return@mapIndexed DscResult(id, "Signature ${index+1}", DscStatus.INVALID, e.message ?: "Invalid byte range", widgets=widgets)
          }
          try {
            // Bind the excluded raw bytes to the parsed signature dictionary.
            require(parts.cms.contentEquals(sig.contents)) { "Signature dictionary does not match the excluded contents" }
            val checked = DscCms.check(parts.signed, parts.cms, sig.subFilter == "ETSI.CAdES.detached")
            val cert = checked.cert
            val embedded = checked.embedded
            val cms = checked.cms
            val intact = checked.intact
                if (!intact) DscResult(id, cert.subjectX500Principal.name, DscStatus.INVALID,
                  "Cryptographic signature does not match signed bytes", cert, widgets=widgets)
                else {
                  val chain = buildChain(cert, embedded, trust)
                  val signingUsage = cert.keyUsage?.let { it.getOrElse(0){false} || it.getOrElse(1){false} } ?: true
                  val documentEku = cert.extendedKeyUsage?.any { it in setOf("2.5.29.37.0", "1.3.6.1.5.5.7.3.36", "1.2.840.113583.1.1.5", "1.3.6.1.4.1.311.10.3.12") } ?: true
                  val strong = checked.strong
                  val rev = if (chain.size < 2) "Not established" else checkRevocation(chain, cms, online)
                  val detail = when {
                    rev == "Revoked" -> "Certificate is revoked"
                    !parts.whole -> "Signed bytes intact; later revisions require DocMDP analysis"
                    !signingUsage || !documentEku -> "Certificate key usage does not allow document signing"
                    !strong -> "Legacy or unsupported digest policy"
                    chain.isEmpty() -> "Certificate identity is not trusted or not currently valid"
                    rev != "Good" -> "Integrity and trust verified; current revocation status not established"
                    else -> "Original signed bytes, trusted certificate chain and current CRLs verified"
                  }
                  val status = when {
                    rev == "Revoked" -> DscStatus.INVALID
                    parts.whole && signingUsage && documentEku && strong && chain.isNotEmpty() && rev == "Good" -> DscStatus.VALID
                    else -> DscStatus.UNKNOWN
                  }
                  DscResult(id, cert.subjectX500Principal.name, status, detail, cert, chain, true,
                    chain.isNotEmpty(), rev, widgets)
                }
          } catch(e: Exception) { unknown("Signature could not be completely checked: ${e.message ?: e.javaClass.simpleName}") }
        }
      }
    }
    return DscDocument(DscSignedBytes.sha256(bytes), results)
  }

  private fun buildChain(leaf: X509Certificate, embedded: List<X509Certificate>,
      trusted: List<X509Certificate>): List<X509Certificate> = runCatching {
    leaf.checkValidity()
    // Only explicitly imported CA certificates are trust anchors. Embedded
    // self-signed roots and arbitrary TLS trust stores never establish DSC trust.
    val anchors = trusted.filter { it.basicConstraints >= 0 && !it.hasUnsupportedCriticalExtension() &&
      (it.keyUsage?.getOrElse(5){false} ?: true) && runCatching { it.checkValidity(); true }.getOrDefault(false) }.map { TrustAnchor(it, null) }.toSet()
    if (anchors.isEmpty()) return emptyList()
    val selector = X509CertSelector().apply { certificate = leaf }
    val params = PKIXBuilderParameters(anchors, selector).apply {
      isRevocationEnabled = false // evaluated explicitly below
      date = Date()
      maxPathLength = 8
      addCertStore(CertStore.getInstance("Collection", CollectionCertStoreParameters(embedded + trusted)))
    }
    val path = CertPathBuilder.getInstance("PKIX").build(params) as PKIXCertPathBuilderResult
    path.certPath.certificates.filterIsInstance<X509Certificate>() + path.trustAnchor.trustedCert
  }.getOrDefault(emptyList())

  private fun checkRevocation(chain: List<X509Certificate>, cms: CMSSignedData, online: Boolean): String {
    val now = Date()
    val crls = cms.getCRLs().getMatches(null).mapNotNull { holder ->
      runCatching { JcaX509CRLConverter().setProvider(provider).getCRL(holder) }.getOrNull()
    }
    var complete = true
    for ((cert, issuer) in chain.zipWithNext()) {
      val evidence = crls.toMutableList()
      if (online) {
        for (url in crlUrls(cert).take(2)) {
          fetchCrl(url)?.let(evidence::add)
        }
      }
      val valid = evidence.filter { crl ->
        runCatching {
          // Only complete direct CRLs, not delta/indirect/scope-limited CRLs.
          crl.issuerX500Principal == issuer.subjectX500Principal &&
            crl.getExtensionValue("2.5.29.27") == null &&
            crl.getExtensionValue("2.5.29.28") == null &&
            !crl.hasUnsupportedCriticalExtension() &&
            (issuer.keyUsage?.getOrElse(6){false} ?: true) &&
            crl.thisUpdate <= now && crl.nextUpdate?.let { it >= now } == true &&
            run { crl.verify(issuer.publicKey, provider); true }
        }.getOrDefault(false)
      }
      if (valid.any { it.isRevoked(cert) }) return "Revoked"
      if (valid.isEmpty()) complete = false
    }
    return if (complete) "Good" else "Not established"
  }

  private fun crlUrls(cert: X509Certificate): List<String> = runCatching {
    val raw = cert.getExtensionValue(Extension.cRLDistributionPoints.id) ?: return emptyList()
    CRLDistPoint.getInstance(ASN1OctetString.getInstance(raw).octets).distributionPoints.flatMap { point ->
      val name = point.distributionPoint ?: return@flatMap emptyList()
      if (name.type != 0) emptyList() else GeneralNames.getInstance(name.name).names
        .filter { it.tagNo == GeneralName.uniformResourceIdentifier }.map { it.name.toString() }
    }.distinct()
  }.getOrDefault(emptyList())

  // Only after an explicitly trusted PKIX path is built. Never follow redirects,
  // send a PDF, use private LAN hosts, or downgrade to HTTP.
  private fun fetchCrl(address: String): X509CRL? = runCatching {
    val url = URL(address)
    require(url.protocol == "https" && url.userInfo == null && url.port in listOf(-1,443))
    require(url.host.contains('.') && InetAddress.getAllByName(url.host).all {
      !it.isAnyLocalAddress && !it.isLoopbackAddress && !it.isLinkLocalAddress &&
        !it.isSiteLocalAddress && !it.isMulticastAddress && it.address.size == 4 &&
        (it.address[0].toInt() and 255) !in listOf(0, 100, 127, 169, 192, 198, 203)
    })
    val connection = url.openConnection() as HttpsURLConnection
    try {
      connection.instanceFollowRedirects = false
      connection.connectTimeout = 5000
      connection.readTimeout = 5000
      require(connection.responseCode == 200)
      require(connection.contentLengthLong <= 4L * 1024 * 1024)
      val out = java.io.ByteArrayOutputStream()
      connection.inputStream.use { input ->
        val buffer = ByteArray(8192)
        while (true) {
          val n = input.read(buffer)
          if (n < 0) break
          require(out.size() + n <= 4 * 1024 * 1024)
          out.write(buffer, 0, n)
        }
      }
      CertificateFactory.getInstance("X.509").generateCRL(out.toByteArray().inputStream()) as X509CRL
    } finally { connection.disconnect() }
  }.getOrNull()
}
