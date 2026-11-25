package com.sammyi57.pdftools

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.example.file_share.FileShareApplication
import com.tom_roush.pdfbox.pdmodel.PDDocument
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** The same page-scope picker for Cart and Android global share.
 * Files are copied to File Share's own staging queue; nothing uploads until Send.
 */
@Composable
fun PdfSendPicker(
  path: String,
  name: String,
  currentPage: Int,
  pageCount: Int,
  toCart: Boolean,
  preserveSigned: Boolean = false,
  expectedSignedHash: String? = null,
  // Keep the callback last: legacy scanner/editor callers use trailing lambdas.
  onClose: () -> Unit,
) {
  val scope = rememberCoroutineScope()
  var selection by remember(preserveSigned) { mutableStateOf(if (preserveSigned) "all" else "current") }
  var pages by remember { mutableStateOf("") }
  var compressResult by remember(preserveSigned) { mutableStateOf(false) }
  var busy by remember { mutableStateOf(false) }
  var error by remember { mutableStateOf("") }
  AlertDialog(
    onDismissRequest = { if (!busy) onClose() },
    title = { Text(if (toCart) "Add PDF to File Share Cart" else "Share PDF") },
    text = {
      Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (preserveSigned) Text("Signed or unverified PDF: the complete original file will be sent unchanged. Page extraction and compression are disabled.")
        else listOf("current" to "Current page ($currentPage)", "all" to "Whole document ($pageCount pages)", "range" to "Choose pages").forEach { (id, label) ->
          Row(verticalAlignment = Alignment.CenterVertically) {
            RadioButton(selected = selection == id, onClick = { selection = id })
            Text(label)
          }
        }
        if (!preserveSigned && selection == "range") OutlinedTextField(
          value = pages,
          onValueChange = { pages = it },
          label = { Text("Pages (example: 1, 3-5)") },
          singleLine = true,
        )
        if (!preserveSigned) Row(verticalAlignment = Alignment.CenterVertically) {
          Checkbox(checked = compressResult, onCheckedChange = { compressResult = it })
          Text("Compress before sending")
        }
        if (error.isNotEmpty()) Text(error)
      }
    },
    confirmButton = {
      TextButton(enabled = !busy && pageCount > 0, onClick = {
        busy = true
        scope.launch {
          try {
            val file = preparePdfSend(path, name, if(preserveSigned) "all" else selection, currentPage, pages, !preserveSigned && compressResult, preserveSigned, expectedSignedHash)
            if (toCart) {
              val app = appContext as FileShareApplication
              check(app.stagePdfFromTools(file, file.name)) { "Unable to stage this PDF in File Share" }
              onClose()
              hostActivity?.finish() // returns to the existing File Share dashboard/cart
            } else {
              onClose()
              share(file.absolutePath, file.name)
            }
          } catch (e: Exception) {
            error = e.message ?: "Unable to prepare PDF"
          } finally { busy = false }
        }
      }) { Text(if (busy) "Preparing…" else if (toCart) "Add to Cart" else "Share") }
    },
    dismissButton = {
      TextButton(onClick = onClose, enabled = !busy) { Text("Cancel") }
    },
  )
}

/** Validate page selections before allocating output; never mutate the user's source. */
internal fun selectedPageIndices(mode: String, currentPage: Int, expression: String, count: Int): List<Int> {
  require(count > 0) { "The PDF has no pages" }
  if (mode == "all") return (0 until count).toList()
  if (mode == "current") return listOf((currentPage - 1).coerceIn(0, count - 1))
  require(mode == "range") { "Unknown page selection" }
  require(expression.length <= 200) { "Page range is too long" }
  val result = linkedSetOf<Int>()
  expression.split(',').forEach { token ->
    val item = token.trim()
    require(item.matches(Regex("[0-9]+(?:-[0-9]+)?"))) { "Use pages such as 1, 3-5" }
    val ends = item.split('-').map { it.toIntOrNull() ?: error("Invalid page number") }
    val start = ends.first()
    val finish = ends.last()
    require(start in 1..count && finish in start..count) { "Pages must be between 1 and $count" }
    (start..finish).forEach { result.add(it - 1) }
  }
  require(result.isNotEmpty()) { "Choose at least one page" }
  return result.toList()
}

suspend fun preparePdfSend(
  path: String,
  name: String,
  selection: String,
  currentPage: Int,
  range: String,
  compressResult: Boolean,
  preserveSigned: Boolean = false,
  expectedSignedHash: String? = null,
): File = withContext(Dispatchers.IO) {
  val source = File(path)
  require(source.isFile) { "PDF source unavailable" }
  val bytes = source.readBytes()
  if (expectedSignedHash != null) require(DscSignedBytes.sha256(bytes) == expectedSignedHash) {
    "PDF changed since verification. Reopen and verify it again."
  }
  val result = if (preserveSigned) {
    require(selection == "all" && !compressResult) { "Signed PDFs must be sent unchanged" }
    bytes
  } else PDDocument.load(bytes).use { pdf ->
    require(pdf.signatureDictionaries.isEmpty() || (selection == "all" && !compressResult)) {
      "This PDF contains a digital signature. Send the whole original PDF without compression."
    }
    val selected = selectedPageIndices(selection, currentPage, range, pdf.numberOfPages)
    val all = selected.size == pdf.numberOfPages && selected.indices.all { selected[it] == it }
    val subset = if (all) bytes else PDDocument().use { extracted ->
      selected.forEach { extracted.importPage(pdf.getPage(it)) }
      java.io.ByteArrayOutputStream().use { buffer -> extracted.save(buffer); buffer.toByteArray() }
    }
    if (compressResult) compress(subset, 60) else subset
  }
  val basename = cleanName(name.substringBeforeLast('.', name)).ifBlank { "document" }
  val marker = when (selection) {
    "all" -> "complete"
    "current" -> "page-$currentPage"
    else -> "selected-pages"
  }
  val dir = File(appContext.cacheDir, "pdf_send").apply { mkdirs() }
  File(dir, "${basename}_${marker}_${System.nanoTime()}.pdf").apply { writeBytes(result) }
}
