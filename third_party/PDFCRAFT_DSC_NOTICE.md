# PDF Craft DSC reference and Android integration status

Upstream: https://github.com/storytold/pdfcraft
Pinned reference: 6e910675c68dd5092e889065cfe8d0274c1b2742
Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
The copied validation, trust/status types and status-layer sources are in
`third_party/pdfcraft-dsc-reference/`; the upstream MIT license is included.
These Rust files are reference source, not a compiled Android library.
No upstream branding is included.

The Android draft adapts PdfCraft's original-byte, explicit-trust and
three-state verification rules to File Share's existing Kotlin, PDFBox and
Bouncy Castle stack. It does not claim full PdfCraft cryptographic or
PDF-revision parity. Native Rust integration requires the transitive workspace
crates (including pinned craft-libs) and a Rust/NDK build/test environment.

## Draft implementation
- Detect PDF signature dictionaries/widgets, use the existing Jetpack PDF
  coordinate mapping, and open the signature panel on a tap.
- Real detached CMS verification, SHA-256/384/512 digest policy,
  CAdES signing-certificate-v2 binding, and original ByteRange checks.
- Explicit local CA trust import/removal; fingerprint confirmation at both
  UI and storage boundaries, current or trusted-time PKIX chain construction.
- Official CCA root certificate page and independent fingerprint confirmation
  guidance (https://cca.gov.in/root_certificate.html). No arbitrary root is
  silently installed or trusted based on its name. A bundled automatically
  provisioned root set requires independently verified official certificate
  bytes/fingerprints; these were not available in this environment.
- Bounded extraction of PDF DSS certificates, CRLs and OCSP responses;
  embedded CMS CRLs; issuer-authorized signed OCSP responses, CertID and
  freshness checks. Delegated OCSP responders without the no-check extension
  remain unverified rather than trusting an unchecked responder certificate.
- RFC3161 attached and standalone document timestamps: exact message imprint,
  TSA certificate/signature and chain/revocation verification. Historical
  signing time is used only when the timestamp itself has trusted evidence.
- Offline-first CRL/OCSP cache; cached evidence is independently rechecked
  every time, never treated as a stored green tick.
- Bounded HTTPS AIA issuer discovery and CRL/OCSP requests only as needed;
  fetched issuers do not become trust anchors. No redirect, proxy or private
  DNS connection. OCSP conveys certificate identifier data to a responder,
  not the PDF or any private key. HTTP-only endpoints remain unsupported
  rather than weakening the application's cleartext network policy.
- Valid only when currently implemented required checks pass. Unknown for
  unsupported algorithms/formats, incomplete evidence or later revisions.
  Revalidation hides previous green badges until a new verdict is available.
- Whole-document original-byte Cart/share and hash-bound Save snapshot;
  page extraction, compression and editor entry are blocked for signed or
  not-yet-inspected PDFs. Save errors do not report success.
- All modifications confined to Android and documentation/reference source.

## Local verification
Kotlin JVM 1.9 and local Bouncy Castle 1.80: original 12 real OpenSSL
CMS/CAdES tests passed again. New OCSP/RFC3161 core code compiled and
12 additional checks passed using generated signed fixtures (good, revoked,
unknown, wrong serial, wrong responder key, stale and malformed evidence,
request binding, trusted token cryptographic check, wrong imprint, standalone
timestamp zero padding and nonzero trailing bytes). Corresponding JUnit
regressions are in DscCryptoTest and DscAdvancedEvidenceTest. These tests
exercise the cryptographic primitives, not the full Android application.

## Unresolved / release blockers
Full Android compilation, Gradle tests, release APK, Jetpack viewer hit
testing on physical devices, real Indian DSC files and live CA endpoints
remain unverified. The full Rust engine is not linked. Official pinned
CCA root bundle provisioning, HTTP-only CA endpoint support, complete
DocMDP/FieldMDP and incremental revision classification, historical LTV
policy coverage, legacy adbe.pkcs7.sha1/adbe.x509.rsa_sha1 and other
unsupported signature formats remain incomplete. Later revisions are
reported Unknown rather than falsely marked Valid. A rendered status badge
is never burned into signed bytes; other readers independently verify
their own trust. Do not claim production readiness or legal certification.
Keep PR #30 draft. No workflow, build, release or merge requested.
