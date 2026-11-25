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
}
