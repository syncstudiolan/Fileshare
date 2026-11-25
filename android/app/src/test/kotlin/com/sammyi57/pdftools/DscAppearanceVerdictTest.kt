package com.sammyi57.pdftools

import org.junit.Assert.assertEquals
import org.junit.Test

/** Never show an authoritative green check without a full validation. */
class DscAppearanceVerdictTest {
  private fun result(
      status: DscStatus,
      intact: Boolean = true,
      chainTrusted: Boolean = true,
      revocation: String = "Good",
    ) = DscResult("0:Signature", "Original signer",status,"",
      integrity=intact,trusted=chainTrusted,revocation=revocation)

  @Test fun greenCheckRequiresSignatureIntegrityTrustedCAAndGoodRevocation() {
    assertEquals(DscAppearanceVerdict.VALID,
      dscAppearanceVerdict(result(DscStatus.VALID)))
    assertEquals(DscAppearanceVerdict.UNKNOWN,
      dscAppearanceVerdict(result(DscStatus.VALID,intact=false)))
    assertEquals(DscAppearanceVerdict.UNKNOWN,
      dscAppearanceVerdict(result(DscStatus.VALID,chainTrusted=false)))
    assertEquals(DscAppearanceVerdict.UNKNOWN,
      dscAppearanceVerdict(result(DscStatus.VALID,revocation="Not established")))
    assertEquals(DscAppearanceVerdict.UNKNOWN,
      dscAppearanceVerdict(result(DscStatus.VALID,revocation="Revoked")))
  }

  @Test fun invalidShowsCrossAndIncompleteVerificationStaysQuestionMark() {
    assertEquals(DscAppearanceVerdict.INVALID,
      dscAppearanceVerdict(result(DscStatus.INVALID,intact=false)))
    for(status in listOf(DscStatus.UNKNOWN, DscStatus.NATIVE_VERIFIED,
      DscStatus.PERSONALLY_TRUSTED, DscStatus.LEGACY_VERIFIED,
      DscStatus.LEGACY_NATIVE_VERIFIED)) {
      assertEquals("Partial evidence must not display green: $status",
        DscAppearanceVerdict.UNKNOWN,dscAppearanceVerdict(result(status)))
    }
  }
}
