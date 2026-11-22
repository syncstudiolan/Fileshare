# File Share — PR #17 release candidate

Source: PR #17 merged into main on 22 November 2026.

## Included changes
- Dashboard rendering and individual file selection within grouped transfers
- Image editor snapshot export and lower-size JPEG quality improvements
- Signature crop, tilt/rotate, and full-resolution transfer between editors
- Android Advanced PDF Pro mode switching and A4/Legal ID-card layout tools
- Editor-to-editor handoff, including Android PDF-page image snapshots
- Login/logout confirmation and mobile header spacing

## Platform release policy
Use the single `.github/workflows/offline-validation.yml` workflow for
Android APK, Windows installer and unsigned iOS IPA.
Publish a release and update manifest entry only after successful jobs.
No release should be represented as tested until its job passes.

## iOS dependency note
The iOS photo enhancer uses its existing Dart image-processing implementation.
The native ONNX dependency required on Windows is isolated from the iOS
CocoaPods build. TLS and artifact checksum verification must not be bypassed.
Unsigned IPA requires external signing before device installation.

## Validation follow-up
The first merged-run analyzer failures were corrected in source. The next
run exposed outdated UI test expectations for platform notices, selection
confirmation and reduced-motion scrolling; all three expectations were
updated before the new combined release attempt.

## Final UI test-teardown correction
Third combined run proved the analyzer and core widget checks passed across
platforms except for an active five-second PDF notice timer at test teardown.
The test now advances the fake clock and disposes that notice before exit.
