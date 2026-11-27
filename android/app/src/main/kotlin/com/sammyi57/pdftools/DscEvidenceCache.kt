package com.sammyi57.pdftools

import java.io.File

/**
 * Local bounded cache of untrusted raw revocation evidence. A cache hit
 * is NOT a trusted verdict: the caller must verify signatures, certificate
 * binding, scope and validity dates every time.
 */
internal object DscEvidenceCache {
  private const val MAX_ENTRIES = 64
  private const val MAX_TOTAL = 24L * 1024 * 1024
  private const val MAX_AGE = 30L * 24 * 60 * 60 * 1000
  private fun folder() = File(appContext.filesDir, "dsc_evidence").apply { mkdirs() }
  private fun key(kind: String, identity: String) =
    DscSignedBytes.sha256("$kind:$identity".toByteArray()) + ".bin"

  @Synchronized fun read(kind: String, identity: String, limit: Int): ByteArray? = runCatching {
    val file = File(folder(), key(kind, identity))
    if (!file.isFile || file.length() !in 1L..limit.toLong() ||
      System.currentTimeMillis() - file.lastModified() !in 0L..MAX_AGE) return null
    file.readBytes().takeIf { it.size <= limit }
  }.getOrNull()

  @Synchronized fun write(kind: String, identity: String, bytes: ByteArray, limit: Int) {
    if (bytes.size !in 1..limit) return
    runCatching {
      val dir = folder()
      val target = File(dir, key(kind, identity))
      val tmp = File.createTempFile("evidence-", ".tmp", dir)
      try {
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(target)) return
        val now = System.currentTimeMillis()
        val existing = dir.listFiles().orEmpty().filter { it.extension == "bin" }
        var size = 0L
        var count = 0
        for (file in existing.sortedByDescending { it.lastModified() }) {
          val age = now - file.lastModified()
          if (age !in 0L..MAX_AGE || ++count > MAX_ENTRIES || size + file.length() > MAX_TOTAL) file.delete()
          else size += file.length()
        }
      } finally { tmp.delete() }
    }
  }
}
