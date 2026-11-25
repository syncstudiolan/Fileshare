package com.sammyi57.pdftools

/** A limited native verdict is not full CA/revocation validation. */
internal object DscVerdictPolicy {
  fun nativeVerified(integrity: Boolean, policy: Boolean, validAtTime: Boolean,
      chainTrusted: Boolean, nativeValid: Boolean, rejected: Boolean): Boolean =
    integrity && policy && validAtTime && chainTrusted && nativeValid && !rejected
  /** A historical SHA-1 signature can be cryptographically verified without
   * claiming modern algorithm compliance or confirmed revocation. */
  fun legacyVerified(legacyFormat: Boolean, integrity: Boolean, revisionAllowed: Boolean,
      usageAllowed: Boolean, validAtTime: Boolean, chainTrusted: Boolean,
      nativeRejected: Boolean, revoked: Boolean): Boolean =
    legacyFormat && integrity && revisionAllowed && usageAllowed && validAtTime &&
      chainTrusted && !nativeRejected && !revoked
  // Match PDF Craft's verified identity/integrity result, but retain the
  // SHA-1 and unconfirmed-revocation qualifications in every presentation.
  fun legacyNativeVerified(legacyVerified: Boolean, nativeValid: Boolean,
      nativeIntegrity: Boolean): Boolean =
    legacyVerified && nativeValid && nativeIntegrity
  // Display eligibility is independent of density and zoom. Never promote
  // unknown, revoked, or in-progress results through the rendering path.
  fun replaceAppearance(verified: Boolean, showOriginal: Boolean,
      widthPx: Float, heightPx: Float): Boolean =
    verified && !showOriginal && widthPx.isFinite() && heightPx.isFinite() &&
      widthPx >= 1f && heightPx >= 1f
}
