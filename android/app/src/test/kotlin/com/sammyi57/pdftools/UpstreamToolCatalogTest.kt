package com.sammyi57.pdftools

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

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

  @Test fun eachCategoryAndInputTypeRemainAvailable() {
    assertTrue(TOOLS.map { it.section }.toSet().containsAll(0..5))
    assertTrue(TOOLS.any { it.input == Input.Pdf })
    assertTrue(TOOLS.any { it.input == Input.Pdfs })
    assertTrue(TOOLS.any { it.input == Input.Images })
    assertFalse(TOOLS.any { it.title.isBlank() })
  }
}
