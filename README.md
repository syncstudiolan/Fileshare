# File Share

Independent Flutter-based file-sharing project (Android and Windows first; iOS/macOS planned).

## Phase 1 — application shell

- Lavender/pink responsive interface with light, dark, and system modes
- Appearance setting in the header, persisted locally
- Welcome: Login / Create Account or Skip to Offline LAN
- Login UI with local validation; **backend authentication is not implemented**
- Unified chat-dashboard foundation for LAN + guest QR files
- Native file picker and staging cards; **no real upload/download/send yet**
- Tools remain disabled until their features exist

## Run locally

Install Flutter SDK and Android SDK / Windows Visual Studio C++ desktop tools.

```sh
flutter create --project-name file_share --platforms=android,windows,ios,macos .
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

This source-only initial commit intentionally omits Flutter-generated native runner directories. Generate them using `flutter create` before building APK/EXE.

## Upcoming phases

1. Flutter platform runners and actual on-device verification
2. Direct LAN device discovery, transfers, progress, and retry
3. Secure app-account login; one-time personal Cloudflare API-token provisioning (Workers, D1, R2)
4. Permanent QR guest upload and unified feed, quotas, and cleanup
5. Background integrations and performance testing

**Constraints:** no purchased domain; guest QR uses user's `workers.dev`; Cloudflare per-user BYOC; LAN needs no sign-in; no extra Cloud polling while idle. Never upload production tokens to source control. The separate legacy projects are not part of this repository.
