# File Share — Live Scanner + Smooth Photo Editor (Draft)

## Change scope
This is a **new Draft PR in the existing File Share repository**, not a fork or
a second application. Existing merged image editing, PDF tools, File Share Cart,
offline/online transfer, login and history APIs are preserved.

## Android Document Scanner
- Embedded Flutter Camera instead of launching the system camera activity.
- Camera preview with Document / Book / ID Card / Business Card / Whiteboard
  modes before capture, flash, switch camera, zoom, manual shutter, batch
  capture and optional **auto capture when the detected border is stable**.
- Android native `pdf.detectFrame` takes a throttled NV21 camera buffer and
  uses the existing pinned DocAligner/OpenCV detection stack. Detection falls
  back gracefully to manual shutter if live analysis isn't available.
- Review has **Perspective** with 4 independent corners and **Normal /
  Freeform** with 4 corners and 4 edge-midpoint handles. Native processing
  uses the selected mode; normal crops use the selected rectangular ROI, while
  perspective crops warp a quadrilateral.
- Color, Gray, B&W, and Enhance preview uses GPU color matrices before
  full-resolution export processing.
- Existing local scan history, renaming, reordering, output PDF and cart
  integration remain in place.

## Image Editing
- Tool navigation does **not** finalize/encode a selected filter or background
  swatch on every tab change.
- A compact bottom **tool card** uses distinct category-specific icons and
  scrollable labels: Background, Erase, Crop, Straighten, Filters, Adjust,
  Compress.
- **Straighten** is a continuously adjustable -45° to +45° slider at 0.5°
  increments, with an optional safe rectangle auto-crop. Live preview uses
  GPU rotation; final full-quality raster processing stays on a worker isolate.
- **Normal Crop** shows an instantaneous GPU-rendered cropped preview while
  the full-resolution crop is applied asynchronously.
- **Manual Erase** uses a GPU-drawn alpha mask along each touch path while
  work is queued serially off the UI thread. The full image is not redecoded
  on every pointer move. Restore is also shown in the preview via source image
  shader. Exports wait for queued brush operations.
- **Background Removal** retains existing Google ML Kit and ONNX fallback.
  A full-image sweep/sparkle painter replaces the tiny fixed corner spinner.
  Other editing operations no longer use a full-page loading screen.
- Camera and editor UI stay in the File Share's existing design. No backend
  authentication, LAN or Cloudflare changes.

## Known validation boundaries
- The source has been updated and static structural checks were run in this
  draft. GitHub Actions Flutter analyzer/widget tests are required before
  integration, and Android physical-device testing is required for camera
  NV21 support, edge-to-preview coordinate alignment and memory/performance.
- Auto-capture accuracy varies by lighting and document geometry.
- Initial AI model downloads may still take time, but the editor should not
  freeze during background segmentation.
- Performance targets (60/90/120 Hz) and installation size must be measured
  on a real release APK; they cannot be guaranteed from source changes alone.
- No APK/EXE release has been produced by this draft.

## Validation-only PR check
The existing `preview_validation` workflow runs Flutter analyzer and widget tests
for PRs. It does **not** assemble or upload an APK, Windows EXE, or release.

## Cross-tool continuation & Cart — November 18 update

### Shared contracts
- `lib/editor_transfer_session.dart` introduces `EditingFileRouter` for
  deterministic file typing and `EditorSessionStore` for local, resumable
  editing state. This is the intended integration contract for future tools.
- Every staged File Share attachment is an **independent, immutable copy**:
  sending to Cart never deletes or replaces the editable history source.
- After successful staging, editor navigation returns to the existing unified
  File Share dashboard/cart. No second Cart screen or cloud upload is created.
- The session JSON is persisted in application-support storage, with a backup
  during replacement and a local recovery read. Draft deletion clears its
  session data.
- Image editing history continues to own the actual edited photo bytes; PDF
  editing history continues to own the actual PDF bytes.

### Resume workflows
- Image Editor: pending eraser strokes finish in the ordered worker queue;
  selected filters, straighten, adjustments, crop and background swatch are
  finalized before the queued snapshot when processing permits. The editor's
  selected tool, crop handles/mode, brush settings, fine rotation, compression
  preferences and other controls are serialized for reopening its history.
- PDF Editor: before Add to Cart, persist current page, selected tool, crop
  ranges, pending redactions and signature placements, workflow steps and
  other editing options. A temporary PDF incorporating pending crop/signature/
  redaction edits is staged, leaving the original history PDF unchanged. The
  open-PDF prompt retains Current Page, Choose Page or Entire PDF.
- Scanner: raw captured photos are copied to persistent application-support
  storage; partial scan pages, crop rectangles/corners, filters and ordering
  can be reopened. Add to Cart exports the current partial multipage PDF to
  PDF history and stages a separate copy; it retains the scanner session.
  Finishing the PDF explicitly clears the active scanner session.

### Dashboard → Toolbox routing
- LAN and Guest QR selected files already arrive at
  `FileShareToolboxPage(sourcePath,sourceName)`, through the same dashboard
  route. The selected file is preserved when launching an available editor.
- Image Editing accepts image files only; incompatible videos/Office/PDF show
  an explanation rather than opening an empty editor.
- Advanced PDF Editing Tools accepts PDF and images. Image input first uses
  the existing local `pdf.fromImages` pipeline and opens the result in the
  PDF Workspace.
- DOC/DOCX/XLS/XLSX and ODT/ODS use a new Android-only offline converter,
  then open an editable PDF, leaving their original Office file intact.
  The lightweight converter preserves readable text, spreadsheet cell values
  and page breaks, but **does not promise pixel-perfect Microsoft Office
  layout fidelity** for charts, macros, embedded media and advanced formatting.
- Videos and unknown binary types cannot enter the PDF editor.
- Windows/macOS still show the Android-only notice for native PDF tools.

### Validation boundaries
A successful Flutter analyzer, widget test and Kotlin compile establish source
compatibility only; they do not verify file conversion fidelity, installation,
native CameraX/Google ML Kit runtime, background transfers or device FPS.
The draft is not ready for release or merge until Android device QA.
