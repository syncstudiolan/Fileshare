# Android / Windows Photo Enhancer QA matrix

This is the QA plan and sign-off record for Draft PR #6.
**No Flutter SDK, Android emulator/device or Windows runner was available in the
source-editing environment. Tests are not claimed as run.**

## Implemented source paths
- `lib/photo_enhancer_engine.dart`: verified Real-ESRGAN x2 ONNX, tiled CPU
  processing, 2x or sequential 4x, strength blending, existing history/undo.
- `lib/face_restoration_engine.dart`: verified GFPGAN v1.4 ONNX, selected face
  crop, RGB [-1, 1], output blend with feathered boundary. Requires an
  approximately aligned face: **no automatic detector or landmark alignment**.
- `lib/image_editing_page.dart`: single-page Android/Windows UI, mode selector,
  model size indication, face region choice, progress and error display.
- `test/photo_enhancer_preflight_test.dart`: source-level input guards.

## Required Flutter compile and correctness checks (not executed)
1. `flutter pub get`
2. `dart format --output=none --set-exit-if-changed lib/photo_enhancer_engine.dart lib/face_restoration_engine.dart lib/image_editing_page.dart`
3. `flutter analyze`
4. `flutter test test/photo_enhancer_preflight_test.dart`
5. `flutter build apk --debug` (validation only, never publish)
6. `flutter build windows --debug` (validation only, never publish)

## On-device test matrix (not executed)
- Android: 2× HD and 4×, portrait/landscape, RGB and transparent PNG,
  large images, airplane mode after initial verified download, network error,
  canceled/failed download recovery, low-memory device, file history & Undo.
- Windows: CPU fallback without discrete GPU, first-run model download,
  2× / 4×, memory and responsive editing controls, export to Cart/Downloads.
- Face Restore: centered portrait, face selected in Crop, face out of frame,
  small face, identity consistency, skin edges, background unchanged, slider
  blending, re-edit and undo.
- Quality: test images with known high-resolution ground truth, bicubic baseline,
  PSNR/SSIM and qualitative checks. AI output is not objectively guaranteed to
  contain authentic details; document any generated facial features.
- Performance: measure model initialization, inference latency, peak RSS,
  GPU/CPU utilization and scroll/preview frame timing on actual hardware.

## Important blockers before asserting ready to release
- Actual Android and Windows Flutter compilation not performed.
- Models (67 MB + 170 MB) were **not downloaded or executed** on devices.
- GFPGAN does **not** yet have automatic face detection/landmark alignment.
  Manual crop selection works at code level but needs device usability QA.
- Exact compatibility of CPU ONNX Runtime, operators, plugin configuration,
  target architecture and memory limits remains unverified.
- Model / training dataset licenses and full license notices require sign-off.
- No production release, PR merge, workflow dispatch or deployment authorized.

## Model verification metadata
- Real-ESRGAN x2plus ONNX fp32, pinned revision `8166b63`,
  SHA256 `7eb5e9eb507df603c0c04b49b23c86a362e0a01575bfbbac891d970f9c331888`,
  67,076,136 bytes.
- GFPGAN v1.4 ONNX fp16 weights, pinned revision `3777aaa`,
  SHA256 `6b12e9428c2a0983b2726604f09c4eec9e2e250370c79946a31b139f9befc1ea`,
  approximately 170 MB.
