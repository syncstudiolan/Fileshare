# File Share — Android upstream PDF Tools + preserved Image Editor (Draft PR #6)

## Source-of-truth decision (18 November 2026)
- The Android PDF toolbox embeds the **actual source** of https://github.com/sammyZi/pdf-tools, retaining all original 24 tools, scanner, viewer, OCR, processing paths, input prompts and animations.
- Android launch: Flutter Toolbox `openUpstreamPdfTools` -> Android activity `com.sammyi57.pdftools.MainActivity` -> original Jetpack Compose App. A PDF file can be passed in for import; other file types open the native tool selection interface.
- UI colors/light-dark are adapted to File Share violet/lavender. Original PDF tool logic is not reimplemented in Flutter. File Share's onboarding precedes the native screen.
- Windows has **no PDF editor/scanner processing code**; the Toolbox warning is exactly “These tools are only available on Android/mobile.”
- MIT and third-party license texts are retained under `android/UPSTREAM_PDF_TOOLS_*`.

## Legacy code removed from the Draft branch
- Old Flutter PDF editor, PDF scanner, PDF history, PDF signature pad and PDF-only live camera UI.
- Old custom Kotlin PDF bridge and PDF scanner/Office converter/advanced operations implementation.
- Old custom PDF-only tests and obsolete Apache POI/Flutter camera dependencies.
- Removed code is **not** reintroduced under a new file or parallel implementation.
- The source changes exist only in this Draft PR; main is not merged.

## Image Editing — preserve without regression
- Keep the existing native-feeling Flutter Photo/Image Editor on **both Android and Windows**.
- Retain background removal, ML Kit and existing fallbacks, GPU previews, manual erase/restore, normal/perspective crop, fine straighten, filters, adjustments, compression, snapshots and Photo Cart history.
- Image Editor uses `image_editing_page.dart`, `image_editing_engine.dart`, `image_editing_storage.dart` and `editor_transfer_session.dart`. Do not delete these shared pieces in PDF cleanup.
- File Share LAN, online transfer, unified dashboard/cart, login, Cloudflare and account flows remain unchanged.

## Validation and release gate
- CI checks Flutter analyzer, Flutter tests, original Compose Kotlin compilation and JVM tests of the **original 24-tool catalog**.
- Draft PR #6 additionally creates an ARM64 **debug-signed APK**, verifies its signature and uploads the APK artifact for user-side testing.
- A successful build alone does **not** prove scanner hardware, OCR accuracy, each of the 24 tools, file import/export, third-party Drive sync, or every Android version. These need follow-up practical tests.
- Keep PR **Draft**; do not merge, release publicly, deploy Cloudflare or claim production readiness until checks and device acceptance are complete.
