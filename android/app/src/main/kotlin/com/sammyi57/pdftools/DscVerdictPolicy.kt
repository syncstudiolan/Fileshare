package com.sammyi57.pdftools

/** A limited native verdict is not full CA/revocation validation. */
internal object DscVerdictPolicy {
  fun nativeVerified(integrity: Boolean, policy: Boolean, validAtTime: Boolean,
      chainTrusted: Boolean, nativeValid: Boolean, rejected: Boolean): Boolean =
    integrity && policy && validAtTime && chainTrusted && nativeValid && !rejected
}
