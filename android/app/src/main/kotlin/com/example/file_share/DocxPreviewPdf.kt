package com.example.file_share

import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.File
import java.util.zip.ZipFile

/**
 * Offline, text-first DOCX preview-to-PDF bridge for File Share's built-in
 * Android PDF editor. Converts paragraphs without sending documents to cloud.
 * Complex DOCX tables, layout and images are NOT faithfully reproduced.
 * Legacy binary .doc remains unsupported instead of silently corrupting it.
 */
object DocxPreviewPdf {
    fun convert(source: File, cacheDir: File): File {
        require(source.isFile && source.canRead()) { "Document unavailable" }
        require(source.extension.equals("docx", true)) { "DOCX is required" }
        require(source.length() <= 32L * 1024L * 1024L) {
            "DOCX exceeds the offline conversion safety limit (32 MB)"
        }
        val lines = mutableListOf<String>()
        ZipFile(source).use { archive ->
            val entry = archive.getEntry("word/document.xml")
                ?: error("This DOCX has no document body")
            require(entry.size < 20L * 1024L * 1024L || entry.size < 0) {
                "Document XML is unusually large"
            }
            val parser = XmlPullParserFactory.newInstance().apply {
                isNamespaceAware = true
            }.newPullParser()
            archive.getInputStream(entry).use { input ->
                parser.setInput(input, "UTF-8")
                val current = StringBuilder()
                var chars = 0
                while (parser.eventType != XmlPullParser.END_DOCUMENT) {
                    when (parser.eventType) {
                        XmlPullParser.START_TAG -> when (parser.name) {
                            "t" -> {
                                val text = parser.nextText()
                                chars += text.length
                                require(chars < 2_000_000) {
                                    "DOCX text exceeds the conversion limit"
                                }
                                current.append(text)
                            }
                            "tab" -> current.append("    ")
                            "br" -> current.append("\n")
                        }
                        XmlPullParser.END_TAG -> if (parser.name == "p") {
                            lines.add(current.toString())
                            current.setLength(0)
                        }
                    }
                    parser.next()
                }
                if (current.isNotEmpty()) lines.add(current.toString())
            }
        }
        require(lines.isNotEmpty()) { "No readable DOCX text was found" }
        val pdf = PdfDocument()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.BLACK
            textSize = 13f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.NORMAL)
        }
        val paperWidth = 595
        val paperHeight = 842
        var pageNo = 0
        var page: PdfDocument.Page? = null
        var y = 50f
        fun nextPage() {
            page?.let { pdf.finishPage(it) }
            pageNo++
            page = pdf.startPage(
                PdfDocument.PageInfo.Builder(paperWidth, paperHeight, pageNo).create()
            )
            y = 50f
        }
        fun drawLine(text: String) {
            if (page == null || y > paperHeight - 48f) nextPage()
            page!!.canvas.drawText(text, 44f, y, paint)
            y += 19f
        }
        try {
            nextPage()
            for (paragraph in lines) {
                if (paragraph.isBlank()) {
                    y += 12f
                    continue
                }
                for (line in paragraph.split('\n')) {
                    var remaining = line
                    while (remaining.isNotEmpty()) {
                        var count = paint.breakText(remaining, true, paperWidth - 88f, null)
                        count = count.coerceAtLeast(1).coerceAtMost(remaining.length)
                        if (count < remaining.length) {
                            val whitespace = remaining.lastIndexOf(' ', count - 1)
                            if (whitespace > count / 2) count = whitespace + 1
                        }
                        drawLine(remaining.substring(0, count).trimEnd())
                        remaining = remaining.substring(count).trimStart()
                    }
                }
                y += 7f
            }
            page?.let { pdf.finishPage(it) }
            page = null
            val destination = File(cacheDir, "docx_pdf").apply { mkdirs() }
            val safe = source.nameWithoutExtension.replace(
                Regex("[^a-zA-Z0-9_-]"), "_").take(60).ifEmpty { "document" }
            val out = File(destination, "${safe}_${System.nanoTime()}.pdf")
            out.outputStream().use { pdf.writeTo(it) }
            require(out.length() > 0) { "DOCX conversion produced an empty PDF" }
            return out
        } finally {
            pdf.close()
        }
    }
}
