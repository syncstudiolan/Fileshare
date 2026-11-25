package com.sammyi57.pdftools

import com.tom_roush.pdfbox.cos.COSArray
import com.tom_roush.pdfbox.cos.COSDictionary
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.cos.COSStream
import com.tom_roush.pdfbox.pdmodel.PDDocument
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Best-effort DSS incremental augmentation, not a new signature or LTA claim.
 * Never rewrites a signed revision or replaces signature widget appearances.
 * The candidate is discarded unless independently validated after writing.
 */
internal suspend fun prepareDscEvidenceCopy(path: String, name: String, password: String?, expectedHash: String): File =
  withContext(Dispatchers.IO) {
    val original = File(path)
    require(original.length() in 1L..(64L*1024*1024)) { "PDF exceeds validation limit" }
    val bytes = original.readBytes()
    require(bytes.size <= 64*1024*1024 && DscSignedBytes.sha256(bytes) == expectedHash) { "PDF changed; reopen and verify" }
    val dir = File(appContext.cacheDir, "pdf_send").apply { mkdirs() }
    val snapshot = File.createTempFile("dsc-ltv-original-", ".pdf", dir)
    val candidate = File.createTempFile("dsc-ltv-candidate-", ".pdf", dir)
    var published = false
    try {
      snapshot.writeBytes(bytes)
      val evidence = DscValidatedEvidence()
      val before = DscVerifier.read(snapshot.path,password,online=true,collected=evidence)
      require(before.hash == expectedHash && before.signatures.isNotEmpty() &&
        before.signatures.all { hasVerifiedAppearance(it) && it.revocation == "Good" && it.certificate != null }) {
        "CA revocation evidence is incomplete. Send the unchanged original instead."
      }
      require(evidence.crls.isNotEmpty() || evidence.ocsps.isNotEmpty()) { "No authenticated revocation evidence available" }
      val certs = before.signatures.flatMap { it.chain }.distinctBy { DscSignedBytes.sha256(it.encoded) }
      require(certs.isNotEmpty() && certs.size <= 64)
      val encrypted = PDDocument.load(snapshot,password.orEmpty()).use { pdf ->
        // Never remove encryption or bypass document permissions.
        require(pdf.currentAccessPermission.canModify()) { "PDF permissions do not permit adding validation evidence" }
        val catalog = pdf.documentCatalog.cosObject
        val key = COSName.getPDFName("DSS")
        val previous = catalog.getDictionaryObject(key)
        require(previous == null || previous is COSDictionary) { "Existing DSS cannot be safely extended" }
        // Use a new DSS dictionary, preserving all existing standard entries.
        val dss = if (previous is COSDictionary) COSDictionary(previous) else COSDictionary()
        fun add(label: String, entries: Collection<ByteArray>) {
          if (entries.isEmpty()) return
          val n = COSName.getPDFName(label)
          val old = dss.getDictionaryObject(n)
          require(old == null || old is COSArray) { "Invalid existing DSS evidence array" }
          val arr = COSArray()
          if (old is COSArray) for (i in 0 until old.size()) {
            require(old.getObject(i) is COSStream) { "Invalid DSS evidence stream" }
            arr.add(old.get(i))
          }
          for (raw in entries) {
            val stream = pdf.document.createCOSStream()
            stream.createOutputStream().use { it.write(raw) }
            stream.isNeedToBeUpdated = true
            arr.add(stream)
          }
          require(arr.size() <= 256)
          arr.isNeedToBeUpdated = true
          dss.setItem(n,arr)
        }
        add("Certs",certs.map { it.encoded })
        add("CRLs",evidence.crls.values)
        add("OCSPs",evidence.ocsps.values)
        dss.isNeedToBeUpdated = true
        catalog.setItem(key,dss)
        catalog.isNeedToBeUpdated = true
        candidate.outputStream().use { pdf.saveIncremental(it) }
        pdf.isEncrypted
      }
      require(candidate.length() in (bytes.size.toLong()+1)..(64L*1024*1024)) { "Incremental PDF size invalid" }
      val updated = candidate.readBytes()
      require(updated.copyOfRange(0,bytes.size).contentEquals(bytes)) { "Original signed bytes not preserved" }
      // Check that actual signature values, ranges and encryption did not change.
      PDDocument.load(snapshot,password.orEmpty()).use { a ->
        PDDocument.load(candidate,password.orEmpty()).use { b ->
          require(b.isEncrypted == encrypted && a.numberOfPages == b.numberOfPages)
          val aa = a.signatureDictionaries
          val bb = b.signatureDictionaries
          require(aa.size == bb.size && aa.indices.all { i ->
            aa[i].byteRange.contentEquals(bb[i].byteRange) && aa[i].contents.contentEquals(bb[i].contents)
          }) { "Original signature dictionary changed" }
          val stored = DscDss.read(b)
          require(stored.crls.isNotEmpty() || stored.ocsps.isNotEmpty()) { "DSS evidence not written" }
        }
      }
      val after = DscVerifier.read(candidate.path,password,online=false)
      require(after.signatures.size == before.signatures.size &&
        before.signatures.zip(after.signatures).all { (a,b) ->
          a.id == b.id && a.certificate == b.certificate && hasVerifiedAppearance(b) &&
          b.revocation == "Good" && b.nativeVerdict == "valid"
        }) { "Validation data revision did not pass independent PDF Craft verification; use original" }
      // Native must explicitly classify the appended revision as permitted
      // for every signature, not simply accept a cryptographic digest.
      val roots = (DscRoots.bundled() + DscTrust.load()).distinctBy { DscSignedBytes.sha256(it.encoded) }
      val native = DscRustBridge.inspect(updated,password,roots)
      require(native.size == before.signatures.size && native.all {
        it.status == "valid" && it.modification == "allowed" && it.integrityChecked
      }) { "Native engine did not approve the incremental validation data" }
      val stem = cleanName(name.substringBeforeLast('.',name)).ifBlank { "document" }
      val output = File(dir,"${stem}_SIGNED_DSS_${System.nanoTime()}.pdf")
      check(candidate.renameTo(output)) { "Cannot stage signed evidence copy" }
      published = true
      output
    } finally {
      snapshot.delete()
      if (!published) candidate.delete()
    }
  }
