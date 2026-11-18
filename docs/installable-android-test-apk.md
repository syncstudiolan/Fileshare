# Installable Android test APK

This is a **testing** package, not a production-distribution build.

- Android application ID: `com.example.file_share.testing` (separate from an existing File Share install).
- Signing: Android Gradle **debug test key** applied to a minified release build; no production signing credentials involved. Future CI rebuilds may use a different debug key and may require removing an older **test** app before upgrading; do not delete the original File Share app.
- Native ABIs packaged: **arm64-v8a only**; x86_64 and 32-bit ARM are explicitly excluded.
- CI verifies `apksigner verify`, checks the packaged native libraries, and fails on an unexpectedly large APK.
- APK artifact: `file-share-arm64-signed-test-apk` produced by `.github/workflows/offline-validation.yml`.
- After extracting the artifact ZIP, install `FileShare-ARM64-Signed-Test.apk` on an ARM64 Android phone. Enable installation from the file manager only if Android prompts.
- This does not establish feature correctness; PDF, document scanner, image editing and transfers still need device-level functional testing.

- Standard push builds skip the separate emulator job; the emulator verification runs only during an explicit `workflow_dispatch` when its debug APK is requested. This prevents an unrelated missing-artifact error from marking a signed release APK run as failed.
