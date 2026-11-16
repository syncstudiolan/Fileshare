# File Share — Flutter UI Design Preview

Independent cross-platform file-sharing project: Android APK and Windows EXE first, iOS/macOS later.
Repository: https://github.com/syncstudiolan/Fileshare

## Designed now

- Lavender/pink glass-like unified chat dashboard with light, dark and system themes; theme choice remembered.
- Welcome, Login / Create Account, Skip to Offline LAN.
- ONE unified chat for LAN and guest QR; no separate QR inbox.
- Received-left cards: Download, Delete, Share externally, Share to Toolbox.
- Sent-right cards: Delete and Share actions only; no Download.
- Sample four-photo group with per-item disabled actions and Download All display.
- Image, video, document and Guest QR sample cards labelled with device and route.
- Files/Preview Tray, History, Devices, My QR, Cloud BYOC Setup, Settings and Profile designs.
- All/Sent/Received UI filter, navigation, theme and login/register demo toggles.
- File picking, Send, Refresh, Download, Delete, sharing, QR regeneration and provisioning are not live.

All file cards and devices are explicitly SAMPLE DATA. The QR preview is NOT scannable.
No file is uploaded, downloaded, shared or deleted. No cloud/network requests are made.

## Still needed

1. Flutter native Android/Windows platform runners and real device builds.
2. Real file picker, preview metadata, upload progress and transfer lifecycle.
3. Offline LAN peer discovery, streaming, retries and delivery status.
4. Secure app login and personal Cloudflare BYOC setup (Worker, D1, R2).
5. Guest QR browser upload and guest-specific rolling 24-hour quotas.
6. QR delivery into the ONE dashboard, LAN 24h cleanup, cloud midnight-IST cleanup.
7. Security, performance, accessibility and full cross-platform testing.

## How to run after installing Flutter

Install current Flutter SDK (Dart 3.11+), Android SDK, and/or Windows Visual Studio desktop C++ tooling.
Execute these commands in the repository root:

    flutter create --project-name file_share --platforms=android,windows,ios,macos .
    flutter pub get
    flutter analyze
    flutter test
    flutter run -d windows

The checked-in repository currently has Flutter source and tests but NO generated native runners.
These runner files are necessary platform files, not duplicate patch files.

## Important product constraints

- Flutter/Dart GPU-based UI, optional Kotlin/Windows native integration.
- Light/dark mode supported on Android and Windows.
- Optional app login for LAN, required for permanent QR and BYOC.
- Own Cloudflare account per user via restricted API token, workers.dev link, no custom domain.
- Cloud requests minimized: no idle polling, event-driven notifications and bounded cleanup retries.
- LAN data expires 24h from each batch; QR cloud temporary data expires at midnight IST.
- Do not commit API tokens, passwords, or production secrets.
- This project is independent from legacy Bank Setu and Sync Studio repos.

## Verification

Widget test cases are committed, but Flutter SDK/native toolchains are unavailable here.
flutter analyze, flutter test, actual Android APK/Windows EXE build and FPS tests have NOT been run.
UI illustrations or browser mockups are NOT screenshots of a running Flutter build.
