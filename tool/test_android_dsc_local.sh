#!/usr/bin/env bash
# Local ARM64 development validation only: never publishes, signs, dispatches
# GitHub Actions, or modifies the main branch.
set -euo pipefail
cd "$(dirname "$0")/.."
for executable in flutter java cargo adb bash; do
  command -v "$executable" >/dev/null || { echo "Missing tool: $executable" >&2; exit 1; }
done
: "${ANDROID_NDK_HOME:?Point ANDROID_NDK_HOME at the installed Android NDK}"
test -d "$ANDROID_NDK_HOME/toolchains/llvm"
cargo ndk --version
rustc --version
test -n "${ANDROID_SERIAL:-}" || { echo "Set ANDROID_SERIAL to an attached ARM64 test phone" >&2; exit 1; }
test "$(adb -s "$ANDROID_SERIAL" get-state)" = device
test "$(adb -s "$ANDROID_SERIAL" shell getprop ro.product.cpu.abi | tr -d '\r')" = arm64-v8a
# Same runner generation as the existing production pipeline; no overwrite flag.
flutter create --project-name file_share --platforms=android .
flutter pub get
python3 tool/fix_legacy_inappwebview_gradle.py
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test --reporter expanded --timeout 2m
export ORG_GRADLE_PROJECT_fileshareDscRust=true
cd android
./gradlew :app:compileDebugKotlin :app:testDebugUnitTest :app:assembleDebug \
  -PfileshareDscRust=true --no-daemon --console=plain
./gradlew :app:connectedDebugAndroidTest -PfileshareDscRust=true \
  -Pandroid.testInstrumentationRunnerArguments.class=com.sammyi57.pdftools.DscDeviceTest \
  --no-daemon --console=plain
echo "Android DSC local compilation and instrumentation completed."
echo "Manual test still required: real Indian DSC, online CA endpoints, signature tap/zoom/rotation, Save/Cart and offline reopen."
