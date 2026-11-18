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
