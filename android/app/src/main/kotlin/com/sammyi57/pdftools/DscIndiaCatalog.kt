package com.sammyi57.pdftools

import java.security.cert.X509Certificate
import java.util.Locale
import org.json.JSONObject

/** Official RCAI issuers are public chain material, never independent trust anchors. */
internal object DscIndiaCatalog {
  data class Entry(val name: String, val url: String, val aliases: List<String>)
  private fun normalized(s: String) = s.lowercase(Locale.ROOT).filter { it.isLetterOrDigit() }
  fun entries(): List<Entry> = appContext.assets.open("dsc/india-ca-catalog.json").use {
    val data = JSONObject(it.bufferedReader().readText())
    require(data.getString("root_sha256") == DscRoots.CURRENT)
    val items = data.getJSONArray("entries")
    require(items.length() in 1..64)
    (0 until items.length()).map { i ->
      val item = items.getJSONObject(i)
      val names = item.getJSONArray("aliases")
      val url = item.getString("url")
      require(url.startsWith("https://cca.gov.in/cca/sites/default/files/files/"))
      Entry(item.getString("name"), url, (0 until names.length()).map { j -> names.getString(j) })
    }
  }
  fun matching(issuer: String): List<Entry> = entries().filter { e ->
    e.aliases.any { normalized(issuer).contains(normalized(it)) }
  }
  fun authenticIssuer(cert: X509Certificate, roots: List<X509Certificate>): Boolean =
    cert.basicConstraints >= 0 && !cert.hasUnsupportedCriticalExtension() &&
      cert.subjectX500Principal != cert.issuerX500Principal &&
      (cert.keyUsage?.getOrElse(5) { false } ?: true) &&
      roots.any { root ->
        DscRoots.isPinned(root) && cert.issuerX500Principal == root.subjectX500Principal &&
          runCatching { cert.verify(root.publicKey); true }.getOrDefault(false)
      }
  fun bundled(): List<X509Certificate> = runCatching {
    val roots = DscRoots.bundled()
    appContext.assets.list("dsc/issuers").orEmpty().filter { it.endsWith(".pem") }.take(64)
      .mapNotNull { name -> runCatching {
        appContext.assets.open("dsc/issuers/$name").use {
          DscCertificates.decode(it.readBytes()).takeIf { cert -> authenticIssuer(cert, roots) }
        }
      }.getOrNull() }
  }.getOrDefault(emptyList())
}
