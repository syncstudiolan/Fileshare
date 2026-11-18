# File Share — Android Advanced PDF Editing Tools (draft)

## Platform boundary
- **Android**: one Toolbox entry, `Advanced PDF Editing Tools`.
- **Windows/macOS**: one Android-only warning; no Kotlin/PDFBox code or
  Android PDF libraries are linked into their release applications.
- There are **no** extra PDF or Document Scanner Toolbox cards.
- Processing is local, through a separate MethodChannel on the cached
  Android FlutterEngine. File Share transfer, LAN, account, and cloud
  engines are unchanged.

## UI and user journeys
- Search replaces the old PDF promotional banner.
- Recent History (3 items) plus full persisted History view and filters.
- History stores real PDF snapshots in application-support storage; no
  automatic purge of these user projects.
- Rename at scan creation, in the open editor, and later from History.
- **Closed** PDF in History -> Add to Cart immediately, no question.
- **Open** PDF -> Cart always asks:
  1. Current page.
  2. Choose another page.
  3. Entire PDF.
  Cancelling never adds a file.
- Sending during a long operation copies the last successfully persisted
  draft to a temporary immutable snapshot, then queues it into the existing
  File Share Cart. The file being edited remains untouched.
- Original PDFs are not overwritten, and Cart snapshots remain independent
  of history/rename/delete operations.
- Save, Share, and Apply are independent of Add to Cart.

## Current native Android coverage
The Flutter catalogue contains the upstream 24 entries.
Supported in this draft's Android bridge: camera/gallery images into a
basic PDF, merge, alternate/mix, page-range extraction, page order selection,
rotation, horizontal image-backed flip, numeric rectangle crop, watermark
text, page numbers, PDF metadata title, JPEG-stream compression,
password protection, and password removal after authenticating.
All operations save to a fresh file. Some settings remain limited to
basic forms; quality/performance and output parity are unverified.

**Not completed**: full multi-output split by text/bookmarks/size,
all ZIP workflow output routing, vector-preserving flip, n-up,
full Fill & Sign with positional signature/graphics, secure redaction,
searchable OCR, workflow-builder pipeline, automatic document edge
detection with perspective correction, multi-shot scanner review.
Their entries are visibly disabled rather than claiming success.

The upstream source is Kotlin/Compose with Android PDFBox, OpenCV,
CameraX, ML Kit and DocAligner. This draft does **not** copy its Compose
UI. Source attribution is documented in
`third_party/PDF_TOOLS_ATTRIBUTION.md`.

## Validation and release
- No APK, EXE, or distributable built as part of this change.
- No manual GitHub Actions workflow dispatch.
- Native PDF module and UI need Android compile/device regression testing
  and output comparisons before any release.
- In particular test: large PDFs, encryption/passwords, corrupted files,
  document resources after page import, crop rotations, Unicode fonts,
  PDF compression, one-page/other-page/full-PDF cart selections,
  rename persistence and editing during Cart staging.
- Measure final APK size after release builds are explicitly allowed.
