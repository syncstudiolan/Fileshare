package com.sammyi57.pdftools

import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.cos.COSString
import com.tom_roush.pdfbox.cos.COSArray
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDSignatureField
import org.bouncycastle.asn1.x509.CRLDistPoint
import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.asn1.x509.GeneralName
import org.bouncycastle.asn1.x509.GeneralNames
import org.bouncycastle.asn1.ASN1OctetString
import org.bouncycastle.cms.CMSSignedData
import java.io.File
import java.net.InetAddress
import java.net.Proxy
import java.util.concurrent.TimeUnit
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.bouncycastle.asn1.x509.AuthorityInformationAccess
import org.bouncycastle.asn1.x509.AccessDescription
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.security.cert.*
import java.util.Date

internal enum class DscStatus { VALID, NATIVE_VERIFIED, PERSONALLY_TRUSTED, LEGACY_VERIFIED, UNKNOWN, INVALID }
internal data class DscWidget(val page: Int, val left: Float, val top: Float, val right: Float, val bottom: Float)
internal data class DscResult(
  val id: String, val name: String, val status: DscStatus, val detail: String,
  val certificate: X509Certificate? = null, val chain: List<X509Certificate> = emptyList(),
  val integrity: Boolean = false, val trusted: Boolean = false,
  val revocation: String = "Not established", val widgets: List<DscWidget> = emptyList(),
  val trustedTime: Date? = null,
  val personalTrust: Boolean = false,
  val canTrustSigner: Boolean = false,
  val nativeVerdict: String? = null,
  val certificateHosts: List<String> = emptyList(),
)
internal data class DscDocument(val hash: String, val signatures: List<DscResult>)

internal object DscTrust {
  private val factory get() = CertificateFactory.getInstance("X.509")
  private fun directory() = File(appContext.filesDir, "dsc_trust").apply { mkdirs() }
  fun load(): List<X509Certificate> = directory().listFiles().orEmpty().filter { it.extension == "cer" }.take(256).mapNotNull { file ->
    runCatching { file.inputStream().use { factory.generateCertificate(it) as X509Certificate } }.getOrNull()
  }
  fun parse(bytes: ByteArray): List<X509Certificate> {
    require(bytes.size in 1..(2 * 1024 * 1024)) { "Certificate file exceeds limit" }
    return factory.generateCertificates(bytes.inputStream()).filterIsInstance<X509Certificate>()
      .also { require(it.isNotEmpty() && it.size <= 32) { "No supported certificates" } }
  }
  fun add(cert: X509Certificate, confirmedFingerprint: String) {
    require(confirmedFingerprint.replace(Regex("[ :\\s]"), "").equals(DscSignedBytes.sha256(cert.encoded), ignoreCase = true)) { "Certificate fingerprint mismatch" }
    require(cert.basicConstraints >= 0 && !cert.hasUnsupportedCriticalExtension() &&
      (cert.keyUsage?.getOrElse(5){false} ?: true)) { "Certificate is not an eligible CA" }
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
  private val supported = setOf("adbe.pkcs7.detached", "ETSI.CAdES.detached", "ETSI.RFC3161", "adbe.pkcs7.sha1", "adbe.x509.rsa_sha1")

  fun read(path: String, password: String?, online: Boolean = false): DscDocument {
    val file = File(path)
    require(file.length() in 1..MAX_PDF) { "PDF exceeds DSC verification safety limit (64 MB)" }
    val bytes = file.readBytes()
    require(bytes.size.toLong() <= MAX_PDF) { "PDF exceeds DSC verification safety limit" }
    val trust = (DscRoots.bundled() + DscTrust.load()).distinctBy { DscSignedBytes.sha256(it.encoded) }
    val cachedIssuers = (DscImportedIssuers.load() + DscIndiaCatalog.bundled()).distinctBy { DscSignedBytes.sha256(it.encoded) }
    val fetchedCrls = mutableMapOf<String, X509CRL?>()
    val fetchedOcsp = mutableMapOf<String, ByteArray?>()
    val fetchedIssuers = mutableMapOf<String, List<X509Certificate>>()
    val results = PDDocument.load(bytes, password.orEmpty()).use { pdf ->
      val dss = DscDss.read(pdf)
      val fields = pdf.documentCatalog.acroForm?.fieldTree?.filterIsInstance<PDSignatureField>().orEmpty()
      val signatures = pdf.signatureDictionaries
      require(signatures.size <= 64) { "Too many signatures to check safely" }
      val native = if (signatures.isNotEmpty()) DscRustBridge.inspect(bytes, password, trust + dss.certificates.filter(DscRoots::isPinned)) else emptyList()
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
            val covered = sig.byteRange[2].toLong() + sig.byteRange[3].toLong()
            fun nativeFor(cert: X509Certificate) = native.singleOrNull {
              field != null && it.field == field.fullyQualifiedName &&
                it.length == covered && it.fingerprint == DscSignedBytes.sha256(cert.encoded)
            }
            fun revisionAllowed(result: DscRustBridge.Result?) =
              parts.whole || (result?.status == "valid" && result.modification == "allowed")
            if (sig.subFilter == "ETSI.RFC3161") {
              val stamp = DscTimestamp.document(parts.cms, parts.signed)
              var chain = buildChain(stamp.signer, stamp.certificates + dss.certificates + cachedIssuers, trust, stamp.time)
              if(chain.isEmpty() && online && trust.isNotEmpty()) {
                val extra = discoverIssuers(stamp.signer, stamp.certificates + dss.certificates + cachedIssuers, trust, fetchedIssuers)
                chain = buildChain(stamp.signer, extra, trust, stamp.time)
              }
              val rev = if(chain.size >= 2) checkRevocation(chain, stamp.cms, dss, online,
                fetchedCrls, fetchedOcsp, stamp.time) else "Not established"
              val trustedTime = if(rev == "Good" && chain.size >= 2) stamp.time else null
              val nativeResult = nativeFor(stamp.signer)
              val status = when {
                rev == "Revoked" || nativeResult?.status == "invalid" -> DscStatus.INVALID
                trustedTime != null && revisionAllowed(nativeResult) -> DscStatus.VALID
                else -> DscStatus.UNKNOWN
              }
              return@mapIndexed DscResult(id, "Document timestamp: " + stamp.signer.subjectX500Principal.name,
                status, if(status == DscStatus.VALID) "Trusted RFC3161 timestamp covers this document"
                  else "Timestamp integrity verified; trust, revision or revocation requires further evidence",
                stamp.signer, chain, true, chain.isNotEmpty(), rev, widgets, trustedTime)
            }
            if (sig.subFilter == "adbe.x509.rsa_sha1") {
              val obj = sig.cosObject.getDictionaryObject(COSName.getPDFName("Cert"))
              val rawCerts = when(obj) {
                is COSString -> listOf(obj.bytes)
                is COSArray -> (0 until obj.size()).mapNotNull { (obj.getObject(it) as? COSString)?.bytes }
                else -> emptyList()
              }
              require(rawCerts.size in 1..32)
              val pool = rawCerts.flatMap { DscTrust.parse(it) }
              val cert = pool.first()
              val intact = DscLegacy.verify(parts.signed, parts.cms, cert)
              val chain = if(intact) buildChain(cert, pool + dss.certificates + cachedIssuers, trust) else emptyList()
              return@mapIndexed DscResult(id, cert.subjectX500Principal.name,
                if(!intact || nativeFor(cert)?.status == "invalid") DscStatus.INVALID else DscStatus.UNKNOWN,
                if(!intact) "Legacy RSA signature does not match signed bytes"
                else if(nativeFor(cert)?.status == "invalid") "PDF Craft rejected this legacy signature or its revisions"
                else "Legacy RSA/SHA-1 integrity verified; weak algorithm cannot establish current-policy validity",
                cert, chain, intact, chain.isNotEmpty(), widgets = widgets)
            }
            val checked = DscCms.check(parts.signed, parts.cms, sig.subFilter == "ETSI.CAdES.detached",
              legacySha1 = sig.subFilter == "adbe.pkcs7.sha1")
            val cert = checked.cert
            val embedded = checked.embedded
            val cms = checked.cms
            val intact = checked.intact
                if (!intact) DscResult(id, cert.subjectX500Principal.name, DscStatus.INVALID,
                  "Cryptographic signature does not match signed bytes", cert, widgets=widgets)
                else {
                  var pool = embedded + dss.certificates + cachedIssuers
                  val personalTrust = DscSignerTrust.contains(cert)
                  val stamp = DscTimestamp.attached(cms)
                  val tsaChain = stamp?.let { buildChain(it.signer, it.certificates + pool, trust, it.time) }.orEmpty()
                  val trustedTime = if (stamp != null && tsaChain.size >= 2 &&
                    checkRevocation(tsaChain, stamp.cms, dss, online, fetchedCrls, fetchedOcsp, stamp.time) == "Good")
                    stamp.time else null
                  val at = trustedTime ?: Date()
                  var chain = buildChain(cert, pool, trust, at)
                  if (chain.isEmpty() && online) {
                    pool = (pool + discoverIssuers(cert, pool, trust, fetchedIssuers))
                      .distinctBy { DscSignedBytes.sha256(it.encoded) }
                    chain = buildChain(cert, pool, trust, at)
                  }
                  val signingUsage = cert.keyUsage?.let { it.getOrElse(0){false} || it.getOrElse(1){false} } ?: true
                  val documentEku = cert.extendedKeyUsage?.any { it in setOf("2.5.29.37.0", "1.3.6.1.5.5.7.3.36", "1.2.840.113583.1.1.5", "1.3.6.1.4.1.311.10.3.12") } ?: true
                  val strong = checked.strong
                  // Same one-click trust as upstream, scoped to this exact signer.
                  // Do not supply personal certificates as global CA/TSA anchors.
                  val nativeResult = if (personalTrust) {
                    DscRustBridge.inspect(bytes, password, (trust + cert).distinctBy {
                      DscSignedBytes.sha256(it.encoded)
                    }).singleOrNull {
                      field != null && it.field == field.fullyQualifiedName &&
                        it.length == covered && it.fingerprint == DscSignedBytes.sha256(cert.encoded)
                    }
                  } else nativeFor(cert)
                  // Only a matching native verdict and allowed revision classification
                  // can relax the original whole-file requirement. A missing library,
                  // unknown verdict or field mismatch never approves modifications.
                  val revisionAccepted = revisionAllowed(nativeResult)
                  val nativeRejected = nativeResult?.status == "invalid"
                  // Even without a trusted CA chain, obtain signer revocation evidence
                  // from a cryptographically matching issuer; never treat this as CA trust.
                  val revChain = if (chain.size >= 2) chain else {
                    val issuer = pool.firstOrNull { candidate ->
                      candidate != cert && candidate.basicConstraints >= 0 &&
                        candidate.subjectX500Principal == cert.issuerX500Principal &&
                        (candidate.keyUsage?.getOrElse(5){false} ?: true) &&
                        runCatching { cert.verify(candidate.publicKey, provider); true }.getOrDefault(false)
                    }
                    if (issuer == null) emptyList() else listOf(cert, issuer)
                  }
                  val rev = if (revChain.size < 2) "Not established" else checkRevocation(revChain, cms, dss, online, fetchedCrls, fetchedOcsp, at)
                  val currentValidity = runCatching { cert.checkValidity(at); true }.getOrDefault(false)
                  val nativeVerified = DscVerdictPolicy.nativeVerified(intact, revisionAccepted && signingUsage && documentEku && strong,
                    currentValidity, chain.isNotEmpty(), nativeResult?.status == "valid" && nativeResult?.integrityChecked == true,
                    rev == "Revoked" || nativeRejected)
                  val hosts = (if(revChain.isEmpty()) listOf(cert) else revChain.dropLast(1)).flatMap {
                    crlUrls(it) + aiaUrls(it, AccessDescription.id_ad_ocsp)
                  }.mapNotNull { runCatching { it.toHttpUrl().host }.getOrNull() }.distinct()
                  val canTrust = (revisionAccepted || nativeResult?.modification == "allowed") && signingUsage && documentEku && strong && currentValidity && !nativeRejected && rev != "Revoked"
                  val personalAccepted = DscPersonalPolicy.accepted(personalTrust, intact,
                    revisionAccepted && signingUsage && documentEku && strong, currentValidity,
                    nativeResult?.status == "valid", rev == "Revoked" || nativeRejected)
                  val legacyVerified = DscVerdictPolicy.legacyVerified(sig.subFilter == "adbe.pkcs7.sha1", intact,
                    revisionAccepted, signingUsage && documentEku, currentValidity, chain.isNotEmpty(), nativeRejected, rev == "Revoked")
                  val detail = when {
                    rev == "Revoked" -> "Certificate is revoked"
                    nativeRejected -> "PDF Craft rejected this signature or its later revisions"
                    !revisionAccepted -> "Signed bytes intact; later revisions are not established as permitted"
                    !signingUsage || !documentEku -> "Certificate key usage does not allow document signing"
                    !currentValidity -> "Certificate is not valid at the checked time"
                    legacyVerified -> "Original signed bytes and trusted CA chain verified. Legacy SHA-1 is weak; revocation: $rev. Not modern-policy validation."
                    sig.subFilter == "adbe.pkcs7.sha1" && chain.isEmpty() -> "Legacy SHA-1 signature integrity verified; certificate chain not trusted"
                    !strong -> "Legacy or unsupported digest policy"
                    personalAccepted && (chain.isEmpty() || rev != "Good") ->
                      "Signature integrity verified by PDF Craft; you personally trust this exact signer. CA/revocation verification is separate."
                    chain.isEmpty() -> "Signer identity not trusted. Review the signer and tap Trust signer."
                    nativeVerified && rev != "Good" -> "PDF Craft verified the signature and CA chain. Revocation evidence is not confirmed; this is not full validation."
                    rev != "Good" -> "Integrity and trust verified; current revocation status not established"
                    !parts.whole -> "Verified signature; permitted later revisions: " + nativeResult?.changes.orEmpty().joinToString(", ")
                    else -> "Original signed bytes, trusted certificate chain and revocation evidence verified"
                  }
                  val status = when {
                    rev == "Revoked" || nativeRejected -> DscStatus.INVALID
                    revisionAccepted && signingUsage && documentEku && strong && currentValidity && chain.isNotEmpty() && rev == "Good" -> DscStatus.VALID
                    legacyVerified -> DscStatus.LEGACY_VERIFIED
                    nativeVerified -> DscStatus.NATIVE_VERIFIED
                    personalAccepted -> DscStatus.PERSONALLY_TRUSTED
                    else -> DscStatus.UNKNOWN
                  }
                  DscResult(id, cert.subjectX500Principal.name, status, detail, cert, chain, true,
                    chain.isNotEmpty(), rev, widgets, trustedTime, personalTrust, canTrust, nativeResult?.status, hosts)
                }
          } catch(e: Exception) {
            // Preserve the native engine's signer metadata even if Java's
            // provider has trouble. Only native integrity proof for the exact
            // field/byte-range counts; never infer it from a certificate alone.
            val covered = sig.byteRange[2].toLong() + sig.byteRange[3].toLong()
            val match = native.singleOrNull { field != null &&
              it.field == field.fullyQualifiedName && it.length == covered }
            val cert = match?.certificate
            if (match == null || cert == null) {
              unknown("Signature could not be completely checked: ${e.javaClass.simpleName}: ${e.message ?: "unknown error"}")
            } else {
              val personal = DscSignerTrust.contains(cert)
              val result = if(personal) DscRustBridge.inspect(bytes,password,(trust + cert).distinctBy {
                DscSignedBytes.sha256(it.encoded)
              }).singleOrNull { it.field == match.field && it.length == covered &&
                it.fingerprint == match.fingerprint } ?: match else match
              val bad = result.status == "invalid"
              // Native-only fallback is deliberately limited to ordinary
              // detached CMS and provider failures. CAdES ESS binding and
              // legacy/other formats must still pass their stricter checks.
              val providerFailure = generateSequence<Throwable>(e) { it.cause }
                .take(8).any { it is java.security.NoSuchAlgorithmException ||
                  it is java.security.cert.CertificateException || it is java.security.ProviderException }
              val current = runCatching { cert.checkValidity(); true }.getOrDefault(false)
              val usage = cert.keyUsage?.let { it.getOrElse(0){false} || it.getOrElse(1){false} } ?: true
              val eku = cert.extendedKeyUsage?.any { it in setOf("2.5.29.37.0", "1.3.6.1.5.5.7.3.36",
                "1.2.840.113583.1.1.5", "1.3.6.1.4.1.311.10.3.12") } ?: true
              val policy = providerFailure && sig.subFilter == "adbe.pkcs7.detached" &&
                result.digest in setOf("SHA-256","SHA-384","SHA-512") &&
                ((cert.publicKey as? java.security.interfaces.RSAPublicKey)?.modulus?.bitLength() ?: 2048) >= 2048 &&
                usage && eku && current && (parts.whole || result.modification == "allowed")
              val accepted = DscPersonalPolicy.accepted(personal,result.integrityChecked,policy,current,
                result.status == "valid",bad)
              DscResult(id,cert.subjectX500Principal.name,
                if(bad) DscStatus.INVALID else if(accepted) DscStatus.PERSONALLY_TRUSTED else DscStatus.UNKNOWN,
                if(bad) "PDF Craft rejected this signature"
                else if(accepted) "PDF Craft verified the signed bytes; personally trusted signer. CA/revocation check unavailable."
                else "PDF Craft signer recovered; Android certificate check incomplete: ${e.javaClass.simpleName}: ${e.message.orEmpty()}",
                cert, integrity = result.integrityChecked, widgets = widgets,
                personalTrust = personal, canTrustSigner = policy && result.integrityChecked && !bad)
            }
          }
        }
      }
    }
    return DscDocument(DscSignedBytes.sha256(bytes), results)
  }

  private fun buildChain(leaf: X509Certificate, embedded: List<X509Certificate>,
      trusted: List<X509Certificate>, at: Date = Date()): List<X509Certificate> = runCatching {
    leaf.checkValidity(at)
    // Only explicitly imported CA certificates are trust anchors. Embedded
    // self-signed roots and arbitrary TLS trust stores never establish DSC trust.
    val anchors = (trusted + embedded.filter(DscRoots::isPinned)).distinctBy { DscSignedBytes.sha256(it.encoded) }.filter { it.basicConstraints >= 0 && !it.hasUnsupportedCriticalExtension() &&
      (it.keyUsage?.getOrElse(5){false} ?: true) && runCatching { it.checkValidity(at); true }.getOrDefault(false) }.map { TrustAnchor(it, null) }.toSet()
    if (anchors.isEmpty()) return emptyList()
    val selector = X509CertSelector().apply { certificate = leaf }
    val params = PKIXBuilderParameters(anchors, selector).apply {
      isRevocationEnabled = false // evaluated explicitly below
      date = at
      maxPathLength = 8
      addCertStore(CertStore.getInstance("Collection", CollectionCertStoreParameters(embedded + trusted)))
    }
    val path = CertPathBuilder.getInstance("PKIX").build(params) as PKIXCertPathBuilderResult
    path.certPath.certificates.filterIsInstance<X509Certificate>() + path.trustAnchor.trustedCert
  }.getOrDefault(emptyList())

  private fun checkRevocation(chain: List<X509Certificate>, cms: CMSSignedData, dss: DscDss.Evidence,
      online: Boolean, fetched: MutableMap<String, X509CRL?>, ocspCache: MutableMap<String, ByteArray?>, at: Date): String {
    val now = Date()
    val crls = cms.getCRLs().getMatches(null).mapNotNull { holder ->
      runCatching { DscCertificates.crl(holder) }.getOrNull()
    }
    var complete = true
    for ((cert, issuer) in chain.zipWithNext()) {
      val evidence = (crls + dss.crls).toMutableList()
      val identity = DscSignedBytes.sha256(cert.encoded) + ":" + DscSignedBytes.sha256(issuer.encoded)
      val crlEndpoints = crlUrls(cert).take(2)
      val ocspEndpoints = aiaUrls(cert, AccessDescription.id_ad_ocsp).take(2)
      fun validCrl(crl: X509CRL): Boolean = runCatching {
        crl.issuerX500Principal == issuer.subjectX500Principal &&
          crl.getExtensionValue("2.5.29.27") == null &&
          crl.getExtensionValue("2.5.29.28") == null &&
          !crl.hasUnsupportedCriticalExtension() &&
          (issuer.keyUsage?.getOrElse(6){false} ?: true) &&
          crl.thisUpdate <= at && crl.thisUpdate <= now &&
          crl.nextUpdate?.let { it >= at } == true &&
          run { crl.verify(issuer.publicKey, provider); true }
      }.getOrDefault(false)
      for (url in crlEndpoints) {
        DscEvidenceCache.read("crl", identity + ":" + url, 4 * 1024 * 1024)?.let { bytes ->
          runCatching { CertificateFactory.getInstance("X.509").generateCRL(bytes.inputStream()) as X509CRL }
            .getOrNull()?.let(evidence::add)
        }
      }
      val ocsp = dss.ocsps.map { DscOcsp.check(it, cert, issuer, at, now) }.toMutableList()
      for (url in ocspEndpoints) {
        DscEvidenceCache.read("ocsp", identity + ":" + url, 1024 * 1024)?.let {
          ocsp.add(DscOcsp.check(it, cert, issuer, at, now))
        }
      }
      var valid = evidence.filter(::validCrl)
      if (valid.any { it.getRevokedCertificate(cert)?.revocationDate?.let { date -> date <= at } == true } ||
          DscOcsp.Verdict.REVOKED in ocsp) return "Revoked"
      if (online && valid.isEmpty() && DscOcsp.Verdict.GOOD !in ocsp) {
        for (url in ocspEndpoints) {
          val key = url + ":" + identity
          if (key !in ocspCache && ocspCache.size < 4) {
            ocspCache[key] = fetchEvidence(url, 1024 * 1024, DscOcsp.request(cert, issuer))
          }
          ocspCache[key]?.let { raw ->
            val verdict = DscOcsp.check(raw, cert, issuer, at, now)
            ocsp.add(verdict)
            if (verdict != DscOcsp.Verdict.UNKNOWN)
              DscEvidenceCache.write("ocsp", identity + ":" + url, raw, 1024 * 1024)
          }
        }
        if (DscOcsp.Verdict.REVOKED in ocsp) return "Revoked"
        if (DscOcsp.Verdict.GOOD !in ocsp) for (url in crlEndpoints) {
          if (url !in fetched && fetched.size < 4) fetched[url] = fetchCrl(url)
          fetched[url]?.takeIf(::validCrl)?.let {
            evidence.add(it)
            DscEvidenceCache.write("crl", identity + ":" + url, it.encoded, 4 * 1024 * 1024)
          }
        }
        valid = evidence.filter(::validCrl)
      }
      if (valid.any { it.getRevokedCertificate(cert)?.revocationDate?.let { date -> date <= at } == true }) return "Revoked"
      if (valid.isEmpty() && DscOcsp.Verdict.GOOD !in ocsp) complete = false
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

  // Restrict the *actual* connection's DNS answers (not a separate
  // preflight lookup), no redirect/proxy, and cap requests per document.
  private fun publicIpv4(ip: InetAddress): Boolean {
    if(ip.address.size != 4 || ip.isAnyLocalAddress || ip.isLoopbackAddress ||
      ip.isLinkLocalAddress || ip.isSiteLocalAddress || ip.isMulticastAddress) return false
    val a = ip.address[0].toInt() and 255
    val b = ip.address[1].toInt() and 255
    val c = ip.address[2].toInt() and 255
    return a in 1..223 && a !in listOf(10,127,169) &&
      !(a == 100 && b in 64..127) && !(a == 172 && b in 16..31) &&
      !(a == 192 && (b == 168 || b == 0 || (b == 88 && c == 99))) &&
      !(a == 198 && (b in 18..19 || (b == 51 && c == 100))) &&
      !(a == 203 && b == 0 && c == 113)
  }

  private val http = OkHttpClient.Builder()
    .dns(object : Dns {
      override fun lookup(hostname: String): List<InetAddress> {
        require(hostname.contains('.')) { "Public CA host required" }
        val ips = Dns.SYSTEM.lookup(hostname)
        // Return only vetted IPv4 addresses; dual-stack DNS must not fail just because AAAA is present.
        val ipv4 = ips.filter { it.address.size == 4 }
        require(ipv4.isNotEmpty() && ipv4.all(::publicIpv4)) { "Non-public or unavailable CA address refused" }
        return ipv4
      }
    })
    .proxy(Proxy.NO_PROXY)
    .followRedirects(false).followSslRedirects(false)
    .connectTimeout(4, TimeUnit.SECONDS).readTimeout(4, TimeUnit.SECONDS)
    .callTimeout(7, TimeUnit.SECONDS).retryOnConnectionFailure(false)
    .build()

  private fun aiaUrls(cert: X509Certificate, method: org.bouncycastle.asn1.ASN1ObjectIdentifier): List<String> = runCatching {
    val raw = cert.getExtensionValue(Extension.authorityInfoAccess.id) ?: return emptyList()
    AuthorityInformationAccess.getInstance(ASN1OctetString.getInstance(raw).octets).accessDescriptions
      .filter { it.accessMethod == method && it.accessLocation.tagNo == GeneralName.uniformResourceIdentifier }
      .map { it.accessLocation.name.toString() }.distinct()
  }.getOrDefault(emptyList())

  private fun discoverIssuers(leaf: X509Certificate, embedded: List<X509Certificate>,
      trust: List<X509Certificate>, cache: MutableMap<String, List<X509Certificate>>): List<X509Certificate> {
    val pool = (embedded + trust).toMutableList()
    val visited = mutableSetOf<String>()
    var current = leaf
    repeat(8) {
      if (!visited.add(DscSignedBytes.sha256(current.encoded))) return pool
      if (trust.any { it == current }) return pool
      fun issuerOf(candidate: X509Certificate): Boolean = candidate.basicConstraints >= 0 &&
        candidate.subjectX500Principal == current.issuerX500Principal &&
        runCatching { current.verify(candidate.publicKey, provider); true }.getOrDefault(false)
      var parent = pool.firstOrNull(::issuerOf)
      if (parent == null) {
        for(url in aiaUrls(current, AccessDescription.id_ad_caIssuers).take(2)) {
          if(url !in cache && cache.size < 4) {
            cache[url] = fetchEvidence(url, 2 * 1024 * 1024)?.let {
              runCatching { DscTrust.parse(it) }.getOrDefault(emptyList())
            }.orEmpty()
          }
          pool.addAll(cache[url].orEmpty().filter(::issuerOf))
        }
        parent = pool.firstOrNull(::issuerOf)
        if (parent == null) {
          // Official directory fallback when a PDF omits its CA or AIA fails.
          for (entry in runCatching { DscIndiaCatalog.matching(current.issuerX500Principal.name) }.getOrDefault(emptyList()).take(2)) {
            if (entry.url !in cache && cache.size < 6) {
              cache[entry.url] = fetchEvidence(entry.url, 128 * 1024)?.let { raw ->
                runCatching { DscTrust.parse(raw).filter { DscIndiaCatalog.authenticIssuer(it, DscRoots.bundled()) } }.getOrDefault(emptyList())
              }.orEmpty()
            }
            for (candidate in cache[entry.url].orEmpty()) {
              if (issuerOf(candidate)) {
                pool.add(candidate)
                runCatching { DscImportedIssuers.add(candidate) }
              }
            }
          }
          parent = pool.firstOrNull(::issuerOf)
        }
      }
      current = parent ?: return pool
    }
    return pool
  }

  /** Explicit one-time refresh; all fetched certificates must chain to a pinned root. */
  fun syncIndianIssuers(onProgress: (Int, Int) -> Unit = { _, _ -> }): Pair<Int, Int> {
    val roots = DscRoots.bundled()
    require(roots.isNotEmpty()) { "Pinned CCA root unavailable" }
    val entries = DscIndiaCatalog.entries()
    var success = 0
    for ((index, entry) in entries.withIndex()) {
      val raw = fetchEvidence(entry.url, 128 * 1024)
      val certs = raw?.let { runCatching { DscTrust.parse(it) }.getOrDefault(emptyList()) }.orEmpty()
      if (certs.any { cert -> DscIndiaCatalog.authenticIssuer(cert, roots) &&
            runCatching { DscImportedIssuers.add(cert); true }.getOrDefault(false) }) success++
      onProgress(index + 1, entries.size)
    }
    return success to entries.size
  }

  private fun fetchCrl(address: String): X509CRL? = fetchEvidence(address, 4 * 1024 * 1024)?.let {
    runCatching { CertificateFactory.getInstance("X.509").generateCRL(it.inputStream()) as X509CRL }.getOrNull()
  }

  private fun fetchEvidence(address: String, limit: Int, request: ByteArray? = null): ByteArray? = runCatching {
    val url = address.toHttpUrl()
    val cleartextCa = url.scheme == "http" && url.port == 80 && DscHttpPolicy.allowed(url.host)
    require((url.isHttps && url.port == 443 || cleartextCa) && url.username.isEmpty() &&
      url.password.isEmpty() && url.host.contains('.'))
    val builder = Request.Builder().url(url)
    if (request != null) builder.header("Accept", "application/ocsp-response")
      .post(request.toRequestBody("application/ocsp-request".toMediaType()))
    else builder.get()
    http.newCall(builder.build()).execute().use { response ->
      require(response.isSuccessful)
      val body = response.body ?: error("Empty evidence")
      require(body.contentLength() <= limit.toLong())
      val out = java.io.ByteArrayOutputStream()
      body.byteStream().use { input ->
        val buffer = ByteArray(8192)
        while (true) {
          val n = input.read(buffer)
          if (n < 0) break
          require(out.size() + n <= limit)
          out.write(buffer, 0, n)
        }
      }
      out.toByteArray()
    }
  }.getOrNull()
}
