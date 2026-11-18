package com.sammyi57.pdftools

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json

/** Verify the actual upstream registry, not the removed Flutter list. */
class UpstreamToolCatalogTest {
  @Test fun originalTwentyFourToolsAreRegisteredExactlyOnce() {
    assertEquals(24, TOOLS.size)
    assertEquals(24, TOOLS.map { it.id }.toSet().size)
    assertTrue(TOOLS.any { it.id == "scan" })
    assertTrue(TOOLS.any { it.id == "workflow" })
    assertTrue(TOOLS.any { it.id == "ocr" })
    assertTrue(TOOLS.any { it.id == "fillSign" })
    assertTrue(TOOLS.any { it.id == "redact" })
  }

  @Test fun cameraScanProjectRemainsEditableWithCompressionPreference() {
    val picture = Shot("/private/camera/original.jpg", 1200, 1600,
      corners = listOf(0.1f, 0.2f, 0.9f, 0.2f, 0.9f, 0.9f, 0.1f, 0.9f),
      filter = "gray")
    val page = ScanPage("page-1", "doc", "A4-portrait", listOf(picture))
    val document = ScanDoc(
      "scan-1", "Invoice", 10L, 11L, listOf(page),
      compressionTargetKb = 200,
    )
    val restored = Json.decodeFromString<ScanDoc>(Json.encodeToString(document))
    assertEquals(200, restored.compressionTargetKb)
    assertEquals("gray", restored.pages.single().shots.single().filter)
    assertEquals(picture.corners, restored.pages.single().shots.single().corners)
    assertEquals(picture.src, restored.pages.single().shots.single().src)
  }

  @Test fun pageSelectionUsesZeroBasedIndicesWithoutMutatingDocument() {
    assertEquals(listOf(2), selectedPageIndices("current", 3, "", 7))
    assertEquals((0 until 7).toList(), selectedPageIndices("all", 2, "", 7))
    assertEquals(listOf(0,2,3,4), selectedPageIndices("range", 1, "1, 3-5", 7))
    assertEquals(listOf(0,1), selectedPageIndices("range", 1, "1-2, 2", 5))
  }

  @Test fun invalidPageRangesAreRejected() {
    listOf("", "0", "3-1", "7", "../data", "1;2").forEach { expression ->
      try {
        selectedPageIndices("range", 1, expression, 5)
        org.junit.Assert.fail("Should reject: $expression")
      } catch (_: IllegalArgumentException) { }
    }
  }

  @Test fun eachCategoryAndInputTypeRemainAvailable() {
    // Camera now lives beside Merge PDFs, not in a standalone section.
    assertEquals(1, toolById("scan")?.section)
    assertEquals("Camera", toolById("scan")?.title)
    assertTrue(TOOLS.map { it.section }.toSet().containsAll((1..5).toList()))
    assertTrue(TOOLS.any { it.input == Input.Pdf })
    assertTrue(TOOLS.any { it.input == Input.Pdfs })
    assertTrue(TOOLS.any { it.input == Input.Images })
    assertFalse(TOOLS.any { it.title.isBlank() })
  }
}
