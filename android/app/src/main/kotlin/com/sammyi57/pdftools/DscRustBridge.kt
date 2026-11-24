package com.sammyi57.pdftools

import org.json.JSONObject
import java.security.cert.X509Certificate

/** The upstream engine is a local NDK library; no document is sent online.
 * Missing native library is not interpreted as a successful verification. */
internal object DscRustBridge {
  data class Result(val field: String, val length: Long, val fingerprint: String?,
    val status: String, val modification: String, val changes: List<String>)
  private val loaded = runCatching { System.loadLibrary("fileshare_dsc") }.isSuccess
  val available get() = loaded
  @JvmStatic private external fun verifyNative(bytes: ByteArray, password: String, roots: Array<ByteArray>): String?
  fun inspect(bytes: ByteArray, password: String?, trust: List<X509Certificate>): List<Result> {
    if (!loaded) return emptyList()
    return runCatching {
      val root = JSONObject(verifyNative(bytes,password.orEmpty(),trust.map { it.encoded }.toTypedArray())
        ?: error("Native result missing"))
      val signatures = root.getJSONArray("signatures")
      require(signatures.length() <= 64)
      (0 until signatures.length()).map { i ->
        val s = signatures.getJSONObject(i)
        val changes = s.getJSONArray("changes")
        Result(s.getString("field"), s.getLong("signed_len"),
          if(s.isNull("fingerprint")) null else s.getString("fingerprint"),
          s.getString("status"), s.getString("modification"),
          (0 until changes.length()).map { changes.getString(it) })
      }
    }.getOrDefault(emptyList())
  }
}
