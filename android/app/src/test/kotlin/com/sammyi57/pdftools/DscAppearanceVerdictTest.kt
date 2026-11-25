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
      nativeVerdict: String? = null,
    ) = DscResult("0:Signature", "Original signer",status,"",
      integrity=intact,trusted=chainTrusted,revocation=revocation,nativeVerdict=nativeVerdict)

  @Test fun greenCheckRequiresSignatureIntegrityTrustedCAAndGoodRevocation() {
    assertEquals(DscAppearanceVerdict.VALID,
      dscAppearanceVerdict(result(DscStatus.VALID)))
    assertEquals(DscAppearanceVerdict.UNKNOWN,
      dscAppearanceVerdict(result(DscStatus.VALID,intact=false)))
    assertEquals(DscAppearanceVerdict.UNKNOWN,
      dscAppearanceVerdict(result(DscStatus.VALID,chainTrusted=false)))
    assertEquals(DscAppearanceVerdict.UNKNOWN,
      dscAppearanceVerdict(result(DscStatus.VALID,revocation="Not established")))
    assertEquals(DscAppearanceVerdict.INVALID,
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

  @Test fun nativeVerifiedLegacyShowsQualifiedMarkOnlyWithRealEvidence() {
    val legacy = DscStatus.LEGACY_NATIVE_VERIFIED
    assertEquals(DscAppearanceVerdict.VERIFIED_WITH_WARNINGS,
      dscAppearanceVerdict(result(legacy,revocation="Not established",nativeVerdict="valid")))
    assertEquals(DscAppearanceVerdict.UNKNOWN,
      dscAppearanceVerdict(result(legacy,intact=false,revocation="Not established",nativeVerdict="valid")))
    assertEquals(DscAppearanceVerdict.UNKNOWN,
      dscAppearanceVerdict(result(legacy,chainTrusted=false,revocation="Not established",nativeVerdict="valid")))
    assertEquals(DscAppearanceVerdict.UNKNOWN,
      dscAppearanceVerdict(result(legacy,revocation="Not established",nativeVerdict="unknown")))
    assertEquals(DscAppearanceVerdict.INVALID,
      dscAppearanceVerdict(result(legacy,revocation="Revoked",nativeVerdict="valid")))
  }

  @Test fun modernNativeCmsWithMissingRevocationShowsQualifiedStatus() {
    val modern = DscStatus.NATIVE_VERIFIED
    assertEquals(DscAppearanceVerdict.VERIFIED_WITH_WARNINGS,
      dscAppearanceVerdict(result(modern,revocation="Not established",nativeVerdict="valid")))
    assertEquals(DscAppearanceVerdict.UNKNOWN,
      dscAppearanceVerdict(result(modern,revocation="Not established",nativeVerdict="unknown")))
    assertEquals(DscAppearanceVerdict.UNKNOWN,
      dscAppearanceVerdict(result(modern,chainTrusted=false,revocation="Not established",nativeVerdict="valid")))
    assertEquals(DscAppearanceVerdict.INVALID,
      dscAppearanceVerdict(result(modern,revocation="Revoked",nativeVerdict="valid")))
  }

  @Test fun dynamicAppearanceUsesActualSignerAndNoDocumentTemplateText() {
    val sig = result(DscStatus.LEGACY_NATIVE_VERIFIED,
      revocation="Not established",nativeVerdict="valid")
      .copy(claimedSigningDate="2030-01-02 03:04:05 UTC")
    val facts = dscAppearanceFacts(sig, "Signed by Example Authority",
      "Approved", "Hyderabad", DscAppearanceVerdict.VERIFIED_WITH_WARNINGS)
    assertEquals(true, facts.any { it.contains("Signed by Example Authority") })
    assertEquals(true, facts.any { it.contains("2030-01-02") })
    assertEquals(true, facts.any { it.contains("Approved") })
    assertEquals(true, facts.any { it.contains("Hyderabad") })
    assertEquals(true, facts.any { it.contains("Legacy SHA-1") })
    assertEquals(true, facts.any { it.contains("Revocation: Not established") })
    val modern = sig.copy(status=DscStatus.NATIVE_VERIFIED)
    val modernFacts = dscAppearanceFacts(modern,"Another signer","","",
      DscAppearanceVerdict.VERIFIED_WITH_WARNINGS)
    assertEquals(false, modernFacts.any { it.contains("SHA-1") })
    assertEquals("Signature integrity verified*",
      dscAppearanceLabel(DscAppearanceVerdict.VERIFIED_WITH_WARNINGS))
    assertEquals("Signature invalid",dscAppearanceLabel(DscAppearanceVerdict.INVALID))
    assertEquals("Signature valid",dscAppearanceLabel(DscAppearanceVerdict.VALID))
  }

  @Test fun signedFieldMatchingRejectsReferencesWithDifferentByteRangeOrContents() {
    val range = intArrayOf(0, 15, 45, 20)
    val cms = byteArrayOf(1, 2, 3, 4)
    assertEquals(true, dscSameSignedData(
      range.copyOf(), cms.copyOf(), range, cms))
    assertEquals(false, dscSameSignedData(
      intArrayOf(0, 15, 44, 20), cms, range, cms))
    assertEquals(false, dscSameSignedData(
      range, byteArrayOf(1, 2, 3, 5), range, cms))
    assertEquals(false, dscSameSignedData(
      null, cms, range, cms))
  }
}
