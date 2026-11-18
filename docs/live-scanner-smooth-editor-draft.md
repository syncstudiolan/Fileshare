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
