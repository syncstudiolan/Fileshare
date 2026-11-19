# File Share — release blockers and safe correction plan

Status as inspected on 19 November 2026. This is a **source-only preparation**.
No APK, EXE, workflow dispatch, installer or release was produced.

## Repository state
- Original Draft PR #6 is **already merged** into `main`.
- Original main commit when the fix branch was created: `7f6c9963a047b7df1b4d53d6f5914f65eb1eabe0`.
- Proposed corrections are held on branch `fix/release-preflight-no-build-20261119`.
- Do **not** merge this branch until the user authorizes further workflows/builds.

## Observed last failed workflow
GitHub Actions run: https://github.com/syncstudiolan/Fileshare/actions/runs/44482666841

### Android: missing stable signing credentials (external setup required)
Android passed all **62 Flutter tests** but failed `Configure stable production APK signing`.
The following GitHub Actions encrypted repository secrets were absent:
- `FILE_SHARE_ANDROID_KEYSTORE_BASE64`
- `FILE_SHARE_ANDROID_KEYSTORE_PASSWORD`
- `FILE_SHARE_ANDROID_KEY_ALIAS`
- `FILE_SHARE_ANDROID_KEY_PASSWORD`

Never replace these with the Android debug key or a regenerated random key for each build.
A stable key must be generated **once**, stored securely/backed up by the project owner,
and supplied privately through GitHub repository Settings → Secrets and variables →
Actions → New repository secret. Do not commit or paste keys/passwords into source files,
chat or workflow YAML.

For a first-ever production signing key, generate it **locally on a trusted computer**
using Java keytool, back it up offline, then encode the keystore to base64 and save
the four encrypted secrets on GitHub. If a production key already exists, use it
rather than creating a new one (otherwise future app updates can fail signature
matching). Signing cannot be fixed by source code while all secrets are absent.

### Windows: ONNX Runtime download/extraction failure
Windows passed all **62 Flutter tests**, but CMake failed:
`flutter_onnxruntime/windows/CMakeLists.txt:107`
`ONNX Runtime extraction directory doesn't exist`
for `onnxruntime-win-x64-1.28.3`.

The plugin tries to download a ZIP from `github.com/microsoft/onnxruntime`,
then extracts it without validating the HTTP download result before checking
the target directory. This makes GitHub outages/blocked archive downloads
fail during CMake configuration.

Proposed remedy: `tool/prepare_windows_onnxruntime.ps1`
- Fetches official Microsoft.ML.OnnxRuntime **1.28.0** from Microsoft NuGet.
  The NuGet version is pinned to the same 1.28 minor API series as the plugin's
  default 1.28.3; native ABI compatibility still requires a Windows compilation
  and inference test.
- Copies only x64 C++ headers, native import library and DLLs into a generated
  local SDK directory; checks required files are nonempty and prints DLL hash.
- Sets `USE_SYSTEM_ONNXRUNTIME=ON` and `ONNXRUNTIME_ROOT_DIR` before the
  generated Flutter plugin registration CMake code. Installs DLLs into Windows
  release output; the Inno Setup installer will include them.
- Is a preparation step only; it must be executed **after** `flutter create
  --platforms=windows` and **before** `flutter build windows`.
- The CI workflow was updated to call that script when builds are later
  authorized. The CMake/native runtime fix has **not been build-tested**.
- If NuGet itself is unreachable, the script intentionally fails with a clear
  dependency error rather than silently installing incomplete binaries.

### Earlier validation failures, resolved in earlier source revisions
- FilePicker v13 named parameter / ZIP entry widgets (Dart analyzer errors).
- Widget test lazy ToolBox grid lookups and preference mocks.
- Most recent combined Android and Windows runs had 62 passing Flutter tests.
- These tests cannot establish every application button or every hardware
  integration as error-free.

## What is already configured
- Android arm64-only, R8 shrink/minify, model download on first use.
- Windows Inno Setup `DefaultDirName={autopf}\\File Share` with
  `PrivilegesRequired=admin`, designed for Program Files installation.
- Windows tray and user-login startup logic are present in source, but live
  installed-system testing has not been completed.

## Before authorizing a release
1. Project owner supplies the existing stable Android production keystore and
   four GitHub Actions secrets (never in chat).
2. Run an **isolated Windows dependency preflight** / static check, then
   a single Windows build and actual inference test when authorized.
3. Verify production APK signing fingerprint, installation, background receive
   behavior, Windows signed-in startup/tray, Program Files installer and
   real file transfer.
4. Only then consider a tagged GitHub release.

No automatic workflow was started by committing to the fix branch; it is
neither `main` nor associated with a new PR.
