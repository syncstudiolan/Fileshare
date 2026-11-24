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
    onCart: () -> Unit, path: String, name: String) {
  val context = LocalContext.current
  val scope = rememberCoroutineScope()
  var trusted by remember { mutableStateOf<List<X509Certificate>>(emptyList()) }
  var builtIn by remember { mutableStateOf<List<X509Certificate>>(emptyList()) }
  var imported by remember { mutableStateOf<List<X509Certificate>>(emptyList()) }
  var confirmedFingerprints by remember { mutableStateOf<Map<String,String>>(emptyMap()) }
  var message by remember { mutableStateOf("") }
  var managing by remember { mutableStateOf(false) }
  var saving by remember { mutableStateOf(false) }
  LaunchedEffect(managing) {
    if (managing) {
      trusted = withContext(Dispatchers.IO) { DscTrust.load() }
      builtIn = withContext(Dispatchers.IO) { DscRoots.bundled() }
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
        message = "Compare the SHA-256 fingerprint with an independent official CA source before trusting."
      } catch (e: Exception) { message = e.message ?: "Unable to import certificate" }
    }
  }
  ModalBottomSheet(onDismissRequest = onClose, containerColor = c.surface) {
    Column(Modifier.fillMaxWidth().navigationBarsPadding().verticalScroll(rememberScrollState()).padding(18.dp),
      verticalArrangement = Arrangement.spacedBy(12.dp)) {
      Text("Signature validation", style = MaterialTheme.typography.titleLarge, color = c.ink)
      Text(if (DscRustBridge.available) "PDF Craft native verifier available" else "Native verifier unavailable; advanced revision checks are limited", color = c.sub)
      if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
      val signatures = document.signatures.sortedBy { if (it.id == selected) 0 else 1 }
      for (sig in signatures) {
        val displayStatus = if(busy) DscStatus.UNKNOWN else sig.status
        val statusColor = when(displayStatus) {
          DscStatus.VALID -> Color(0xff18834b)
          DscStatus.UNKNOWN -> Color(0xffb57b13)
          DscStatus.INVALID -> Color(0xffc33232)
        }
        Column(Modifier.fillMaxWidth().border(1.dp, statusColor).padding(12.dp),
          verticalArrangement = Arrangement.spacedBy(5.dp)) {
          Text(when(displayStatus) {
            DscStatus.VALID -> "✓ Signature valid"
            DscStatus.UNKNOWN -> "? Validity unknown"
            DscStatus.INVALID -> "✕ Signature invalid"
          }, color = statusColor, style = MaterialTheme.typography.titleMedium)
          Text(sig.name, color = c.ink)
          Text(if(busy) "Rechecking — previous verdict is not current" else sig.detail, color = c.sub)
          Text("Integrity: " + if(sig.integrity) "Verified" else "Not established", color = c.sub)
          Text("Trust: " + if(sig.trusted) "Trusted chain" else "Not established", color = c.sub)
          Text("Revocation: ${sig.revocation}", color = c.sub)
          Text("Validation time: " + (sig.trustedTime?.toString() ?: "Current device time; no trusted timestamp"), color = c.sub)
          sig.certificate?.let { cert ->
            Text("Issued by: ${cert.issuerX500Principal.name}", color = c.sub)
            Text("Serial: ${cert.serialNumber.toString(16)}", color = c.sub)
            Text("Validity: ${cert.notBefore} — ${cert.notAfter}", color = c.sub)
            Text("SHA-256: ${DscSignedBytes.sha256(cert.encoded)}", color = c.sub)
          }
          for (cert in sig.chain.drop(1)) Text("CA: ${cert.subjectX500Principal.name}", color = c.sub)
        }
      }
      if (signatures.isEmpty()) Text("No digital signature found", color = c.sub)
      TextButton(onClick = { managing = !managing }) { Text(if(managing) "Hide trusted certificates" else "Trusted certificates") }
      if (managing) {
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
        }) { Text("Official Indian CCA root certificates") }
        Text("Confirm the root fingerprint through CCA (verifyroot@cca.gov.in) before importing.", color = c.sub)
        OutlinedButton(onClick = { pick.launch(arrayOf("*/*")) }) { Text("Import CER / CRT / PEM") }
        for (cert in imported) {
          val fingerprint = DscSignedBytes.sha256(cert.encoded)
          Text(cert.subjectX500Principal.name, color = c.ink)
          Text("SHA-256: $fingerprint", color = c.sub)
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
      if(message.isNotEmpty()) Text(message, color = c.sub)
      Button(enabled = !busy, onClick = onValidate, modifier = Modifier.fillMaxWidth()) { Text("Validate again") }
      Text("Save and Cart preserve the original signed bytes, not a flattened green tick.", color = c.sub)
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
