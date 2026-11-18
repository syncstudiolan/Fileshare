# Photo Enhancer third-party model notice

Photo Enhancer uses an optional download-on-first-use ONNX export of
**Real-ESRGAN x2plus** (RRDBNet, 23-block, 2x super resolution).

- Original architecture and pretrained weights: Copyright (c) 2021 Xintao Wang.
- Upstream: https://github.com/xinntao/Real-ESRGAN
- License: BSD 3-Clause, including copyright/conditions/disclaimer.
- Model delivery and conversion metadata:
  https://huggingface.co/skillsafe-ai/realesrgan-x2plus
- Model ONNX SHA-256:
  7eb5e9eb507df603c0c04b49b23c86a362e0a01575bfbbac891d970f9c331888
- The model is downloaded once over HTTPS and SHA-256 checked before local
  inference. Images are processed locally, not sent to the model registry.
- The 4x option runs the same 2x model twice; it is not the separately
  pretrained Real-ESRGAN x4plus model.

BSD-3-Clause redistribution requires retaining the license notice and
disclaimer when shipping a model copy. Confirm that these notices ship in
the release before distributing the APK or EXE. This document does not
supersede licenses of other packages or models.

Original BSD-3-Clause license:
https://github.com/xinntao/Real-ESRGAN/blob/master/LICENSE

No claims of perfect recovered detail, exact face identity, or guaranteed
performance should be made from AI image restoration.

## Optional GFPGAN face-restoration model

- Model: GFPGAN v1.4 ONNX export, half-precision weights, Float32 RGB I/O, 512×512.
- Original GFPGAN project and model: https://github.com/TencentARC/GFPGAN (Apache-2.0).
- ONNX conversion: https://huggingface.co/sidkonduru/gfpgan-v1.4-onnx
- Pinned revision: `3777aaa`, artifact `gfpgan14-fp16.onnx`.
- Expected SHA-256: `6b12e9428c2a0983b2726604f09c4eec9e2e250370c79946a31b139f9befc1ea`.
- File size: approximately 170 MB. Downloaded on first use, SHA-verified,
  and processed locally. A manual face region is required; no automatic
  detection, landmark alignment, identity preservation, or face swap is claimed.
- Model may hallucinate details or alter apparent identity, and works best
  on approximately aligned front-facing portraits.
- Preserve the upstream Apache 2.0 license and attribution for redistributed
  binaries. Review original training data provenance before commercial release.

## Engineering and verification status

Only source-level wiring and checks are committed in the Draft PR.
Android/Windows Flutter builds, ONNX model downloads, actual tensor execution,
performance measurement, side-by-side output comparison, low-memory device
behavior, and face-region accuracy are **not verified**. No APK/EXE was
built or deployed. A preflight Flutter test file exists but has not been run.
