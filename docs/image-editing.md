# File Share → Toolbox → Image Editing

All work is on Draft PR #2. The user-facing title is **Image Editing** (not
"Image Editing Tools"). No production Worker, D1, R2 or Directory changes
are needed for any image operation.

## Entry and flow

- File Share sidebar → **Image Editing** → Choose Image or History.
- Received LAN/Guest QR file → Open in Tools → **Image Editing**.
- Windows opens a responsive workspace with side controls; Android uses
  the same editor with a compact controls panel below the image.
- The editor inherits the File Share Light/Dark/System Material theme.
- The editing preview always stays visible; crop/erase use pointer gestures
  and the other modes allow pinch zoom/pan. Slider preview uses a Flutter
  ColorFiltered GPU color matrix; high-resolution pixels render on an isolate.
- Every edit is non-destructive to the input file. Save, Share and Send to Cart
  are always available for the current output, not just the last step.

## Tools and engines

- Background removal: **Android** uses Google ML Kit selfie segmentation
  (fast recommended for people), applied as an alpha mask on full-res image.
  **Windows** uses 320×320 on-device U²-NetP via ONNX Runtime; first use
  downloads the 4.57 MB ONNX model once to app private support storage and
  verifies SHA256. Subsequent uses are local/offline. Both also have a plain
  color-distance background mask tool on non-Android platforms for simple
  backdrops. Transparent output remains PNG.
- Background replacement: supplied colors, custom RGB picker, or any gallery
  photo resized under the subject's alpha.
- Compression: PNG/JPEG, manually selected quality and target KB; a bounded
  JPEG quality search plus resolution reductions attempts the target. Some
  extremely small targets are impossible, so actual output size is shown.
- Crop: free drag and resize, 1:1, 4:3, 16:9, A4, flip, and rotation.
- Filters: Normal, Vivid, Warm, Cool, B&W, Vintage and Soft.
- Manual Erase/Restore: soft-brush alpha editing across full pointer stroke.
- Adjust: brightness, contrast, saturation and exposure, with GPU preview.
- Undo/Redo: up to 15 in-memory image revisions while the screen is open.
- Before/After: toggle original vs current output.

## Drafts, Cart and exports

- Initial image and every applied revision save an **editable continuation
  snapshot** with a list of edit steps under
  `getApplicationSupportDirectory()/image_editing`.
- History: Re-edit, Share, Send to Cart, Download, Delete.
- The editor creates a separate export snapshot in private
  `image_editing_cart`, then signals the existing Dashboard's staging queue.
  Tapping **Send to Cart** does NOT upload or transfer by itself; the main
  File Share Send button preserves the existing LAN transfer behavior.
- Save uses the platform's native file dialog with correct JPEG/PNG MIME.
- Data remains local unless the user initiates Share or Send; QR midnight
  cloud cleanup does not remove an explicitly created editing draft.

## Validation

Code, widget and image-algorithm tests have been added under
`test/image_editing_test.dart`. They have **not been executed** because no
workflow has been run. Actual Android and Windows APK/EXE compilation and device
tests are required before calling this release verified. No exact FPS is
guaranteed without device GPU measurements.

## Model provenance

The Windows 4.57 MB U²-NetP is served from
`https://huggingface.co/edgetools/u2netp/resolve/main/u2netp.onnx` and
is required to match SHA256
`309c8469258dda742793dce0ebea8e6dd393174f89934733ecc8b14c76f4ddd8`.
The algorithm and preprocessing are compatible with the U²-Net family used in
T8RIN/ImageToolbox. Google ML Kit is Android-only; it is **not** mistakenly
called from Windows. If Windows model download/inference fails, the editor
shows an error rather than pretending background removal succeeded.
