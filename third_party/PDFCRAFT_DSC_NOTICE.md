# PDF Craft DSC reference and Android integration status

Upstream: https://github.com/storytold/pdfcraft
Pinned reference: 6e910675c68dd5092e889065cfe8d0274c1b2742
Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
The copied validation, trust/status types and status-layer sources are in
`third_party/pdfcraft-dsc-reference/`; the complete upstream MIT license is
included beside them. These Rust files are reference source, not a compiled
Android library. No upstream branding is included.

The draft Android implementation adapts PdfCraft's original-byte range,
explicit trust and three-state verification rules to File Share's existing
Kotlin, PDFBox and Bouncy Castle stack. It does not claim full PdfCraft
cryptographic or PDF-revision parity. Native Rust integration would require
vendoring its transitive workspace crates (including pinned craft-libs)
and an Android Rust/NDK build and test environment.

Implemented draft paths:
- Detect PDF signature dictionaries and visible widgets, map their coordinates
  to the existing Jetpack PDF viewer, and open the verification panel.
- Real detached CMS RSA/EC signature verification; SHA-256/384/512 digest
  policy, CAdES signing-certificate-v2 binding, original ByteRange checking.
- Local explicit CA trust import/removal; current-time PKIX chain building.
- Embedded CMS complete direct CRLs and bounded HTTPS CRL retrieval on
  already trusted paths. Network requests never upload the PDF. The
  transport disallows redirects, private-network DNS results and proxying.
- Only show Valid when all currently implemented required checks pass.
- Unknown for unsupported formats, incomplete evidence, later revisions,
  or unsupported policy. No automatic trust of a certificate from a PDF.
- Original-byte save and whole-document Cart/share with verified file hash;
  no page extraction or recompression when a signature is known or
  signature inspection is unavailable. Viewer edit is disabled for signed
  documents.

Not complete: native Rust port, automatic official Indian CCA trust-bundle
provisioning, AIA issuer discovery, embedded PDF DSS / OCSP, online OCSP,
HTTP-only CA endpoints, trusted RFC 3161 signing-time/LTV validation,
DocMDP/FieldMDP revision classification, and Android device/rotation/widget
geometry validation. The existing Jetpack viewer has its own OS extension
requirements. Do not treat an Unknown result as a valid signature. A
display badge is not written into signed bytes. Third-party readers must
verify independently.

Local tests performed: the exact DscCms.kt and DscSignedBytes.kt Git blobs
23643e98f39e4af7257cf0561e2553cc990c9586 and
fc1b4073a5094dfec2520eddba314eb969c2bd53 were compiled with Kotlin JVM 1.9
and local Bouncy Castle 1.80. Twelve checks passed using real OpenSSL RSA
detached CMS and CAdES fixtures: integrity, tamper, embedded content,
CAdES binding, missing binding, padding, trailing data, original signed
bytes, later revision, overlapping range, invalid hex and overflow.
The Android project uses its own dependency versions; full Android
compilation, Gradle tests, UI and real Indian DSC testing were NOT run.
No workflow, build or release was dispatched. Keep this PR draft.
