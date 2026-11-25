# PDF Craft DSC integration — Android draft PR #30

Upstream PDF Craft: https://github.com/storytold/pdfcraft
Pinned revision: 6e910675c68dd5092e889065cfe8d0274c1b2742
Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
The complete 24-file `crates/sign/src/` tree is copied under
`third_party/pdfcraft-dsc-reference/`, with the upstream MIT license.
All 24 source Git blob IDs were compared against the pinned upstream tree
and matched exactly. The standalone Cargo manifest adapts workspace dependencies
to pinned Git revisions. Transitive parser/font/cryptography dependencies
still require build-time Cargo resolution; they are not all vendored.
The app has no runtime download of executable Rust code.

## Android integration
- Native Rust JNI adapter (`android/dsc-rust`) calls the actual copied
  `pdfcraft-sign` signature listing and DocMDP/FieldMDP revision classifier.
- Explicit local ARM64 NDK build via `-PfileshareDscRust=true` and
  `tool/test_android_dsc_local.sh`. Native binary is packaged from the
  Gradle-generated JNI directory. It is not yet a default release dependency.
- Existing Kotlin/PDFBox and BC checks use original signed bytes, strict
  ByteRange, CMS/CAdES, certificate binding, PKIX, CRL/OCSP, DSS and RFC3161
  timestamps. Native revision verdicts are bound to field name, signed
  length and exact signer certificate fingerprint. Missing/mismatched
  native results cannot approve a later revision. Native availability is
  displayed in the signature panel.
- Legacy Adobe `adbe.pkcs7.sha1` (encapsulated SHA-1 digest) and
  `adbe.x509.rsa_sha1` (RSA signature) integrity checks added; weak SHA-1
  does not obtain a current-policy green tick. Unsupported variants remain
  Unknown.
- Embedded and bounded online AIA/OCSP/CRL plus revalidated offline cache.
  Android cleartext policy stays disabled globally, with exact exceptions
  for cca.gov.in, www.cca.gov.in, ocvs.gov.in, ca.igcar.gov.in and
  crl.care4sign.com. No redirects/proxy/private addresses. Plain HTTP data
  is not trusted until cryptographically checked. Other HTTP endpoints are
  not enabled; live endpoint interoperability remains untested.
- Built-in CCA India 2022 document-signing root automatically loads offline.
  Certificate bytes copied from
  https://github.com/danted4/eaadhaar-pdf-signature-verifier/blob/main/certs/CCAIndia2022.cer
  (Git blob bb42a24e86ab5d08b02cd4df1061598702171023), independently checked
  against the Microsoft CCADB certificate report:
  https://ccadb.my.salesforce-sites.com/microsoft/IncludedCACertificateReportForMSFT
  SHA-256: 9A3FD3176798E842DDCB12C262F11CFACCA70A8B84C6EA6FDA30842A95A94CD8.
  OpenSSL `verify -check_ss_sig` passed. Official root list:
  https://cca.gov.in/root_certificate.html ; official out-of-band verification:
  https://cca.gov.in/root_ca_faq.html. CCA India 2022 SPL is TLS-purpose in
  that report and is not automatically trusted for document signing.
  Historical 2014 fingerprint recognition is limited to available matching
  certificate bytes and trusted historical validation time; the expired root
  is not bundled. Other historical roots require separately verified
  certificate import. The certificate manager displays the built-in pin.
- Signature tap targets and status overlays, original-byte Save/Cart,
  hash-bound immutable export and no compression/extraction of signed PDFs.
  No changes to Windows, macOS or iOS implementation.

## Actual tests run
Local Kotlin/JVM and BC 1.80, not Android: recompiled updated DscCms.kt,
DscLegacy.kt and DscHttpPolicy.kt (exact Git blob IDs
396ece3575b28e86c92e01596e6177f068088088,
81fce51d8764e92126d060a26a4022a1e3349aa9,
fd24a9471c24951eb220e1a0d0617d2ed3696454), plus existing core files.
32 checks passed: 12 CMS/range, 12 OCSP/timestamp, 8 legacy/HTTP-policy.
Real OpenSSL-generated signatures were used for the legacy checks.
The bundled 2022 root fingerprint and self-signature were separately
verified using OpenSSL. JUnit regression source is committed.

## Device test entrypoint and release blockers
`tool/test_android_dsc_local.sh` requires Flutter, Android SDK/NDK, Rust
1.95+, cargo-ndk, Java and an authorized connected ARM64 Android device.
It generates the same missing Flutter runner as the existing workflow,
compiles and runs local unit tests, builds a debug APK with Rust enabled
and runs DscDeviceTest on the connected device. The instrumented test
source checks native loading, bundled root, synthetic signed PDF,
tampering, unauthorized incremental revision, and byte-preserving Cart.
These Android instrumented tests have NOT been run in this environment.

There is no Rust/Android SDK/NDK/Flutter toolchain or attached phone here;
network downloads from the local container are unavailable. Cargo lockfile
generation, actual Rust/NDK link, full Android compilation, instrumented
device results, real Indian DSC PDFs and live CA endpoint validation remain
unverified. Full historical LTV, all legacy algorithms and all HTTP-only
CA endpoints are not guaranteed. Do not claim production readiness or legal
certification. Keep PR #30 open as draft; do not merge or release.
No GitHub Actions workflow was initiated.

## Legacy encrypted PDF compatibility draft (2026-11-25)
A private user-supplied encrypted PDF was checked locally with Poppler and OpenSSL. Its complete signed byte range and encapsulated SHA-1 digest verified, and its embedded intermediate CA chain verified against the CCA India 2022 root whose SHA-256 matches the existing independent pin. Revocation was not established. The private PDF, password and end-entity certificate are NOT committed. Add a distinct warning-colored legacy verification status, never modern-policy green, and preserve offline results if online evidence fails. Future production builds must explicitly include the Rust native library; the existing main release pipeline already sets the required flag. Android/NDK integration and the new JUnit tests still need execution on a suitable toolchain. No workflow dispatch or release is requested.

## Android viewer parity follow-up
Device screenshots supplied by the user show native PDF Craft available, native verdict valid, integrity verified and CA chain verified; revocation is not established. The previous app status was deliberately amber for SHA-1 even when upstream returned valid. The static embedded PDF appearance still said Signature Not Verified. The new distinct native-confirmed legacy verdict requires the prior independent legacy policy gates, matching native valid and native integrity evidence; the viewer may show a green verification check with explicit SHA-1 and revocation caveats, not a modern-policy valid result. The overlay is reversible via the signature panel; it does not alter or flatten signed bytes. Upstream also draws validation badges separately from embedded appearances (crates/ui-egui/src/canvas/page_overlays.rs). Android compilation and phone testing remain pending. No build, workflow or release initiated by this draft.
