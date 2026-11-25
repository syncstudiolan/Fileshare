package com.sammyi57.pdftools

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.security.cert.X509Certificate

@Composable
internal fun DscValidationPanel(document: DscDocument, selected: String?,
    busy: Boolean, onValidate: () -> Unit, onClose: () -> Unit,
    onCart: () -> Unit, path: String, name: String,
    showOriginal: Boolean, onToggleOriginal: () -> Unit) {
  val context = LocalContext.current
  val scope = rememberCoroutineScope()
  var trusted by remember { mutableStateOf<List<X509Certificate>>(emptyList()) }
  var signers by remember { mutableStateOf<List<X509Certificate>>(emptyList()) }
  var trusting by remember { mutableStateOf(false) }
  var builtIn by remember { mutableStateOf<List<X509Certificate>>(emptyList()) }
  var imported by remember { mutableStateOf<List<X509Certificate>>(emptyList()) }
  var confirmedFingerprints by remember { mutableStateOf<Map<String,String>>(emptyMap()) }
  var message by remember { mutableStateOf("") }
  var managing by remember { mutableStateOf(false) }
  var issuers by remember { mutableStateOf<List<X509Certificate>>(emptyList()) }
  var syncingIndian by remember { mutableStateOf(false) }
  val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
  var saving by remember { mutableStateOf(false) }
  LaunchedEffect(managing) {
    if (managing) {
      trusted = withContext(Dispatchers.IO) { DscTrust.load() }
      signers = withContext(Dispatchers.IO) { DscSignerTrust.load() }
      builtIn = withContext(Dispatchers.IO) { DscRoots.bundled() }
      issuers = withContext(Dispatchers.IO) { DscImportedIssuers.load() }
    }
  }
  val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
    if (uri != null) scope.launch {
      try {
        imported = withContext(Dispatchers.IO) {
          val input = context.contentResolver.openInputStream(uri) ?: error("Cannot open certificate")
          input.use {
            val out = java.io.ByteArrayOutputStream()
            val buf = ByteArray(8192)
            while (true) {
              val count = it.read(buf)
              if (count < 0) break
              require(out.size() + count <= 2 * 1024 * 1024) { "Certificate too large" }
              out.write(buf, 0, count)
            }
            DscTrust.parse(out.toByteArray())
          }
        }
        managing = true
        message = "${imported.size} certificate(s) loaded. Select the import action below."
      } catch (e: Exception) { message = e.message ?: "Unable to import certificate" }
    }
  }
  ModalBottomSheet(onDismissRequest = onClose, sheetState = sheetState, containerColor = c.surface) {
    Column(Modifier.fillMaxWidth().navigationBarsPadding().verticalScroll(rememberScrollState()).padding(18.dp),
      verticalArrangement = Arrangement.spacedBy(12.dp)) {
      Text("Signature validation", style = MaterialTheme.typography.titleLarge, color = c.ink)
      Text(if (DscRustBridge.available) "PDF Craft native verifier available" else "Native verifier unavailable; advanced revision checks are limited", color = c.sub)
      if (busy) {
        LinearProgressIndicator(Modifier.fillMaxWidth())
        Text("Checking signature and certificate evidence…", color = c.sub)
      }
      if(message.isNotEmpty()) Text(message, color = c.ink)
      Button(enabled = !busy && !trusting, onClick = onValidate, modifier = Modifier.fillMaxWidth()) { Text(if(busy) "Validating…" else "Validate signature") }
      OutlinedButton(enabled = !busy && !trusting, onClick = { managing = true; pick.launch(arrayOf("*/*")) }, modifier = Modifier.fillMaxWidth()) { Text("Import downloaded certificate") }
      TextButton(onClick = onToggleOriginal) {
        Text(if (showOriginal) "Show validated signature appearance" else "Show original signature appearance")
      }
      val signatures = document.signatures.sortedBy { if (it.id == selected) 0 else 1 }
      for (sig in signatures) {
        val displayStatus = if(busy) DscStatus.UNKNOWN else sig.status
        val statusColor = when(displayStatus) {
          DscStatus.VALID -> Color(0xff18834b)
          DscStatus.PERSONALLY_TRUSTED, DscStatus.NATIVE_VERIFIED,
          DscStatus.LEGACY_NATIVE_VERIFIED, DscStatus.LEGACY_VERIFIED,
          DscStatus.UNKNOWN -> Color(0xffb57b13)
          DscStatus.INVALID -> Color(0xffc33232)
        }
        Column(Modifier.fillMaxWidth().border(1.dp, statusColor).padding(12.dp),
          verticalArrangement = Arrangement.spacedBy(5.dp)) {
          Text(when(displayStatus) {
            DscStatus.VALID -> "✓ Signature valid"
            DscStatus.NATIVE_VERIFIED -> "? Signature integrity verified; full CA/revocation status pending"
            DscStatus.PERSONALLY_TRUSTED -> "? Signer personally trusted; CA validity not established"
            DscStatus.LEGACY_NATIVE_VERIFIED -> "? Legacy signature integrity verified; modern validity not established"
            DscStatus.LEGACY_VERIFIED -> "✓* Signature integrity verified — legacy SHA-1"
            DscStatus.UNKNOWN -> "? Validity unknown"
            DscStatus.INVALID -> "✕ Signature invalid"
          }, color = statusColor, style = MaterialTheme.typography.titleMedium)
          Text(sig.certificate?.let(DscCertificates::displayName) ?: sig.name, color = c.ink)
          if (displayStatus == DscStatus.LEGACY_NATIVE_VERIFIED) {
            Text("Legacy SHA-1 is weak. Revocation: ${sig.revocation}. Not modern-policy validation.", color = Color(0xffb57b13))
          }
          Text(if(busy) "Rechecking — previous verdict is not current" else sig.detail, color = c.sub)
          if (sig.status == DscStatus.UNKNOWN && sig.canTrustSigner && !sig.personalTrust) {
            sig.certificate?.let { cert ->
              Text("Trust this signer only if you recognize the displayed identity. This is your personal trust decision, not automatic CA certification.", color = c.sub)
              Button(enabled = !busy && !trusting, onClick = {
                trusting = true
                scope.launch {
                  try {
                    withContext(Dispatchers.IO) {
                      require(DscSignedBytes.sha256(File(path).readBytes()) == document.hash) { "PDF changed. Reopen it first." }
                      DscSignerTrust.add(cert)
                    }
                    signers = withContext(Dispatchers.IO) { DscSignerTrust.load() }
                    message = "Signer trusted. Rechecking signature and available online certificate evidence."
                    onValidate()
                  } catch(e: Exception) { message = e.message ?: "Unable to trust signer" }
                  finally { trusting = false }
                }
              }, modifier = Modifier.fillMaxWidth()) { Text("Trust signer & validate") }
            }
          }
          if (sig.personalTrust) Text("Signer trust saved on this device", color = c.sub)
          else if(sig.trusted) Text("CA chain already trusted — no manual root download needed", color = c.sub)
          Text("Integrity: " + if(sig.integrity) "Verified" else "Not established", color = c.sub)
          Text("Trust: " + when { sig.trusted -> "CA chain verified"; sig.personalTrust -> "Personally trusted signer (not CA verified)"; else -> "Not established" }, color = c.sub)
          Text("Certificate revocation: " + if(sig.revocation == "Not established") "CA response not available; cancellation status not confirmed" else sig.revocation, color = c.sub)
          sig.nativeVerdict?.let { Text("PDF Craft result: $it", color = c.sub) }
          if(sig.certificateHosts.isNotEmpty()) Text("Certificate servers: " + sig.certificateHosts.joinToString(", "), color = c.sub)
          Text("Validation time: " + (sig.trustedTime?.toString() ?: "Current device time; no trusted timestamp"), color = c.sub)
          sig.certificate?.let { cert ->
            Text("Subject: ${cert.subjectX500Principal.name}", color = c.sub)
            Text("Issued by: ${cert.issuerX500Principal.name}", color = c.sub)
            Text("Serial: ${cert.serialNumber.toString(16)}", color = c.sub)
            Text("Validity: ${cert.notBefore} — ${cert.notAfter}", color = c.sub)
            Text("SHA-256: ${DscSignedBytes.sha256(cert.encoded)}", color = c.sub)
          }
          for (cert in sig.chain.drop(1)) Text("CA: ${cert.subjectX500Principal.name}", color = c.sub)

        }
      }
      if (signatures.isEmpty()) Text("No digital signature found", color = c.sub)
      OutlinedButton(enabled = !busy && !trusting && !syncingIndian, modifier = Modifier.fillMaxWidth(), onClick = {
        syncingIndian = true
        message = "Downloading official Indian CA certificates…"
        scope.launch {
          try {
            val result = withContext(Dispatchers.IO) { DscVerifier.syncIndianIssuers() }
            issuers = withContext(Dispatchers.IO) { DscImportedIssuers.load() }
            message = "${result.first}/${result.second} official CA entries checked and saved for offline use."
            onValidate()
          } catch(e: Exception) { message = e.message ?: "Certificate sync failed" }
          finally { syncingIndian = false }
        }
      }) { Text(if(syncingIndian) "Updating Indian certificates…" else "Update Indian CA certificates") }
      if(syncingIndian) LinearProgressIndicator(Modifier.fillMaxWidth())
      TextButton(onClick = { managing = !managing }) { Text(if(managing) "Hide certificate manager" else "Manage trusted certificates") }
      if (managing) {
        Text("Personally trusted signers", style = MaterialTheme.typography.titleMedium, color = c.ink)
        if(signers.isEmpty()) Text("No personally trusted signer yet. Use Trust signer & validate on an eligible signature, not this manager button.", color = c.sub)
        for (cert in signers) {
          Text(cert.subjectX500Principal.name, color = c.ink)
          Text(DscSignedBytes.sha256(cert.encoded), color = c.sub)
          TextButton(enabled = !busy && !trusting, onClick = { scope.launch {
            withContext(Dispatchers.IO) { DscSignerTrust.remove(cert) }
            signers = withContext(Dispatchers.IO) { DscSignerTrust.load() }
            onValidate()
          } }) { Text("Remove signer trust") }
        }
        Text("Imported issuer certificates", style = MaterialTheme.typography.titleMedium, color = c.ink)
        Text("Bundled Indian issuers and downloaded certificates are used automatically; they do not become independent trust roots.", color = c.sub)
        for (cert in issuers) {
          Text(cert.subjectX500Principal.name, color = c.ink)
          TextButton(enabled = !busy, onClick = { scope.launch {
            withContext(Dispatchers.IO) { DscImportedIssuers.remove(cert) }
            issuers = withContext(Dispatchers.IO) { DscImportedIssuers.load() }
            onValidate()
          } }) { Text("Remove issuer") }
        }
        Text("CA certificates (advanced)", style = MaterialTheme.typography.titleMedium, color = c.ink)
        if (builtIn.isEmpty()) Text("Built-in CCA certificate could not be loaded; verification remains limited.", color = c.sub)
        Text("Only independently verified CA certificates should be trusted. A PDF's embedded root is never trusted automatically.", color = c.sub)
        for (cert in builtIn) {
          Text("Built-in CCA trust root: " + cert.subjectX500Principal.name, color = c.ink)
          Text(DscSignedBytes.sha256(cert.encoded), color = c.sub)
        }
        for (cert in trusted) {
          Text(cert.subjectX500Principal.name, color = c.ink)
          Text(DscSignedBytes.sha256(cert.encoded), color = c.sub)
          TextButton(onClick = { scope.launch {
            withContext(Dispatchers.IO) { DscTrust.remove(cert) }
            trusted = withContext(Dispatchers.IO) { DscTrust.load() }
            onValidate()
          } }) { Text("Remove trust") }
        }
        TextButton(onClick = {
          runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW,
            android.net.Uri.parse("https://cca.gov.in/root_certificate.html"))) }
            .onFailure { message = "Unable to open CCA website" }
        }) { Text("Official CCA website (optional)") }
        Text("Download CER / CRT / PEM, tap Import downloaded certificate, then select the file in Downloads. Known CCA roots are checked automatically; unknown roots need independent fingerprint confirmation.", color = c.sub)
        OutlinedButton(onClick = { pick.launch(arrayOf("*/*")) }) { Text("Import CER / CRT / PEM") }
        for (cert in imported) {
          val fingerprint = DscSignedBytes.sha256(cert.encoded)
          Text(cert.subjectX500Principal.name, color = c.ink)
          Text("SHA-256: $fingerprint", color = c.sub)
          if(DscRoots.isPinned(cert)) {
            Button(enabled = !busy && !trusting, onClick = { scope.launch {
              try {
                withContext(Dispatchers.IO) { DscTrust.add(cert, fingerprint) }
                imported = imported.filterNot { it == cert }
                trusted = withContext(Dispatchers.IO) { DscTrust.load() }
                message = "Known CCA root imported. Validating again."
                onValidate()
              } catch(e: Exception) { message = e.message ?: "Import failed" }
            } }) { Text("Import verified CCA root & validate") }
          } else if(cert.basicConstraints >= 0 && cert.subjectX500Principal != cert.issuerX500Principal) {
            Button(enabled = !busy && !trusting, onClick = { scope.launch {
              try {
                withContext(Dispatchers.IO) { DscImportedIssuers.add(cert) }
                imported = imported.filterNot { it == cert }
                issuers = withContext(Dispatchers.IO) { DscImportedIssuers.load() }
                message = "Issuer imported. Checking chain against trusted roots."
                onValidate()
              } catch(e: Exception) { message = e.message ?: "Import failed" }
            } }) { Text("Import issuer & validate") }
          } else if(cert.basicConstraints < 0) {
            Text("This is a signer certificate, not a CA root. Use Trust signer on the matching PDF.", color = c.sub)
          } else {
          OutlinedTextField(value = confirmedFingerprints[fingerprint].orEmpty(),
            onValueChange = { confirmedFingerprints = confirmedFingerprints + (fingerprint to it.take(128)) },
            label = { Text("Independently verified SHA-256 fingerprint") }, singleLine = true,
            modifier = Modifier.fillMaxWidth())
          Text("Issuer: ${cert.issuerX500Principal.name}", color = c.sub)
          Button(enabled = cert.basicConstraints >= 0 && !busy &&
              confirmedFingerprints[fingerprint].orEmpty().replace(Regex("[ :\\s]"), "").equals(fingerprint, ignoreCase = true), onClick = {
            scope.launch {
              try {
                withContext(Dispatchers.IO) { DscTrust.add(cert, confirmedFingerprints[fingerprint].orEmpty()) }
                imported = imported.filterNot { it == cert }
                trusted = withContext(Dispatchers.IO) { DscTrust.load() }
                message = "CA added. Rechecking the actual signature."
                onValidate()
              } catch(e: Exception) { message = e.message ?: "Unable to save trust" }
            }
          }) { Text("Trust this CA fingerprint") }
          }
        }
      }
      if(message.isNotEmpty()) Text(message, color = c.ink)
      Text("Save preserves the original signature. Share or Cart defaults to a high-resolution unsigned visual copy when eligible; the displayed verification remains part of the page image. The original is unchanged.", color = c.sub)
      TextButton(onClick = onClose, modifier = Modifier.fillMaxWidth()) { Text("Back to PDF") }
      Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(enabled = !saving && !busy, onClick = {
          saving = true
          scope.launch {
            try {
              val snapshot = withContext(Dispatchers.IO) {
                val bytes = File(path).readBytes()
                require(DscSignedBytes.sha256(bytes) == document.hash) {
                  "PDF changed since validation. Reopen and verify again."
                }
                File.createTempFile("dsc-save-", ".pdf", context.cacheDir).apply { writeBytes(bytes) }
              }
              try {
                val result = saveToDevice(Saved(name, snapshot.path, snapshot.length(), snapshot.lastModified()))
                if(result.isNotEmpty()) message = "Original signed PDF saved to $result"
              } finally { withContext(Dispatchers.IO) { snapshot.delete() } }
            } catch(e: Exception) { message = e.message ?: "Save failed" }
            finally { saving = false }
          }
        }) { Text("Save PDF") }
        Button(enabled = !busy && !saving, onClick = onCart) { Text("Add to Cart") }
      }
    }
  }
}
