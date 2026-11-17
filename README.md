# File Share — Android + Windows file-sharing application

Independent Flutter/Dart project at https://github.com/syncstudiolan/Fileshare. Android APK and Windows EXE are the first targets; iOS and macOS are future targets. Do not modify earlier Bank Setu or Sync Studio repositories.

## Current authentication and auto-provisioning (17 Nov 2026)

The single operator-run Central Directory Worker is deployed at
`https://fileshare-directory.modeltech0.workers.dev` with its own D1.
It is separate from each customer's own Cloudflare resources.

- On first setup, the user supplies their own Cloudflare Account ID and
  restricted API token in the app and taps **Verify & Auto Connect**.
- The app creates/reuses that account's own D1, R2 bucket and personal Worker,
  installs the Worker/D1 schema and QR upload page, configures a secret and
  cleanup schedule, and checks D1/R2 connectivity.
- The user creates their email/password account in their personal Worker.
  The app links that email to this Worker in the Central Directory using a
  signed login session verified directly by the personal Worker.
- The Directory does **not** send or verify email OTP. It has no email sender
  or external mail-provider credentials. **Mailbox ownership is not proved**.
- The first successful email-to-Worker binding is immutable. A different
  Cloudflare Worker cannot take over an already-linked email. The same
  Worker can safely retry. Personal Workers register one owner account.
- On a second device, only email and password are required. The Directory
  asks that same personal Worker to authenticate, then returns its signed
  session. The app independently verifies the session and stores it using
  OS secure storage.
- The Directory rate-limits requests and does not store user passwords,
  Cloudflare API tokens, owner secrets, or uploaded files.
- Existing users may still choose **Existing Worker? Link it once**.

**Security trade-off:** Without actual email or external identity
verification, someone could preemptively register another person's email
before the legitimate mailbox owner does. One-cloud locking prevents
subsequent takeover, not first-time email impersonation. Account migration
or recovery is not automatic.

Central Directory infrastructure and code are deployed. App-level personal
Worker provisioning, QR guest upload and cross-device login still need
real Android and Windows build/device tests. No APK/EXE, Build or Release
workflow is triggered by these changes. See `directory/README.md`.

## Draft update — Windows sidebar and personal Cloudflare accounts (17 Nov 2026)

All changes remain on Draft PR #1, NOT on main. By owner request,
the offline-validation GitHub Action now has ONLY a manual trigger.
NO new APK, Windows EXE, GitHub build, CI or release was run for these changes.

Windows opens maximized, with a fixed 248px left navigation menu. The
hamburger collapses and restores it. The main chat fills the remaining
width, and the light/dark toggle stays in the header. Small Android and
Windows layouts keep the familiar drawer.

### Account creation and first-time cloud connection

- Open Cloud Setup, enter the owner-provided Cloudflare Account ID and a
  restricted API token. Cloudflare token permissions: Workers Scripts
  Read/Write, D1 Read/Write, Workers R2 Storage Read/Write. User must
  first activate R2 and a workers.dev subdomain.
- The app verifies Cloudflare credentials, provisions/reuses the user's
  own D1 database, R2 bucket and Worker script, installs the schema,
  embeds the guest upload page, enables workers.dev and midnight IST
  cleanup, and runs a tiny, one-time R2+D1 connectivity check.
- The Cloudflare administrative API Token is NOT stored. Only a random
  owner bootstrap secret and signed login session are stored securely
  on the device. Partial setup retries reuse named resources. An
  unrecognized pre-existing Worker is NEVER overwritten.
- Create one owner account on that personal Worker using email and a
  password of at least 10 characters. The owner account is in their
  own D1. Password verification uses a salted PBKDF2 digest and limits
  repeated failed logins. The app stores 24-hour signed sessions.
- Logout clears local login but preserves setup and email so re-login
  needs only Worker URL, email and password, not a new Cloudflare token.
  Another device needs the SAME Worker URL, email and password.
  Offline LAN works with or without any cloud account.

### Verification and limitations

Cloudflare provisioning and email/password endpoints have only been
statically reviewed. They have NOT been exercised against a real
Cloudflare account or Android/Windows build this iteration. The central account directory is deployed, but real device login is still unverified. Account recovery,
immediate server-side logout token revocation and push notifications
are still future work. A copied stateless token remains usable until
its 24-hour expiry; evaluate session revocation before production.
Verify password hashing performance against Cloudflare's 10ms CPU
limit on free Workers before release. The user will decide when to
run any further build or live-cloud test.

## Verified scope and current implementation status

| Area | Code status | Practical status |
| --- | --- | --- |
| Lavender/Pink light and dark UI | Implemented | Device-specific visual QA still required |
| Welcome, skip-to-LAN, login form | Per-owner Worker signup/login code implemented | Central Directory deployed; live account and device tests pending; email OTP intentionally removed |
| One unified chat for LAN + QR | Implemented | Real QR feed needs user's deployed Worker |
| LAN peer discovery | UDP broadcast engine implemented | Two-device discovery not yet tested; router/Windows Firewall may block |
| Direct LAN file transfer | TCP streamed send/receive and delivery acknowledgement implemented | No device-to-device test yet |
| Native file selection | Uses file_picker v13 | Android SAF/Windows testing still needed |
| Auto-start on selection | Starts sending to discovered LAN peers before Send | Send promotes existing progress into timeline |
| File metadata, grouping, sender/receiver actions | Implemented | Group preview, retry/resume and some device state edge cases remain |
| Receiver Save to Downloads | Streaming copy implemented | Android scoped-storage behavior needs testing |
| External native Share | share_plus wired | Actual platform share UI not tested |
| LAN 24-hour cleanup | History and private cache cleanup implemented | Background when Android is killed not guaranteed |
| QR guest web page | Implemented in cloudflare/public/guest.html | Automatically deployed to each owner's personal Worker; real Cloudflare test pending |
| Per-guest 200 MiB / 4 sessions | D1 conditional quota reservation implemented | Cookie/IP is not trustworthy hardware identity |
| 200MB large file | R2 multipart 6-MiB chunks implemented | Real upload/retry/network test required |
| Owner's QR generate/revoke/regenerate | Worker routes + app QR image integrated | Requires connected Worker and owner secret |
| QR files in unified feed | Integrated via PersonalCloud.refreshFiles | Manual refresh currently; real-time push not implemented |
| Midnight IST QR cleanup | Worker scheduled batch cleanup + app card expiry | Real Cron timing and error retries untested |
| One-time per-user Cloudflare Account ID/API Token provisioning | Implemented in code | Real user-owned Cloudflare deployment and permissions test NOT run |
| Personal Worker email/password account and cross-device login | Implemented in code | Same Worker URL required; no central global account directory or live auth test |
| Android background receiving | Foreground sockets only | Foreground service and OS/background tests remain |
| Native Android/Windows runners | Partially configured; Android Manifest committed | Generated platform files/builds not yet verified |
| LAN secure peer trust, retries and transfer resume | Not implemented | Needs robust production engineering |
| Performance 60/90/120 FPS | GPU-based Flutter UI architecture | Not profiled or guaranteed |

**Important:** Code has been committed, but it is not correct to call all functionality finished or verified. No actual APK/EXE is attached and no successful on-device LAN or Cloudflare transfer test has been reported.

## Files and responsibilities

- `lib/main.dart`: welcome/login forms, unified dashboard, sent/received/QR cards, file picker, dark/light themes, Cloud Setup and QR pages.
- `lib/lan_engine.dart`: UDP discovery, TCP streaming, local transfer records, 24h expiry and original-file protection.
- `lib/personal_cloud.dart`: secure owner Worker pairing, QR lifecycle, cloud inbox API and streamed downloads.
- `cloudflare/worker.js`: user-owned Worker guest upload endpoints, quota and cleanup.
- `cloudflare/schema.sql`: D1 schema, indexed for quota and expiring inbox.
- `cloudflare/public/guest.html`: browser QR upload UI; auto-upload on file selection, progress and disabled button until completion.
- `cloudflare/wrangler.jsonc`: manually provisioned R2/D1 bindings, guest assets and scheduled cleanup.
- `cloudflare/README.md`: deployment guidance without sharing secrets.
- `test/widget_test.dart`: Flutter UI and LAN model tests (not executed in this authoring environment).
- `.github/workflows/manual-test-builds.yml`: opt-in-only test builds, not automatically triggered.

## Build/test without a local Flutter SDK

GitHub Actions → **Manual Android and Windows test builds** → **Run workflow** (main).

Only workflow_dispatch is configured; saving code does not start builds. Running it uses GitHub Actions quota and may expose compilation problems needing further fixes. On success it provides:

- `file-share-android-debug-apk`: debug APK for Android testing.
- `file-share-windows-debug-bundle`: Windows EXE with necessary DLLs and data; keep the whole folder, not EXE alone.

For direct local work, install current Flutter SDK (Dart 3.11+), Android SDK, Visual Studio Desktop C++ tools, then in the repository root:

    flutter create --project-name file_share --platforms=android,windows .
    flutter pub get
    flutter analyze
    flutter test
    flutter run -d windows

Existing source files should be edited IN PLACE. Generating missing native runner files is necessary and does not mean duplicating modified files.

## Cloudflare test without giving anybody your credentials

See `cloudflare/README.md`. Every owner uses their own Worker + D1 + R2 and secret OWNER_TOKEN. This is distinct from a limited Cloudflare API token used for initial deployment. The current app has an **advanced/manual Worker pairing screen** for isolated testing; it is not yet the promised fully automatic Account-ID/API-Token self-provisioning system. Never commit owner secrets, API tokens, passwords, or real guest files.

## Business and cleanup rules

- Skip Login → full local LAN mode, no PIN. QR requires identity and personal cloud in the planned production product.
- Sent cards on the right have no Download; received cards on the left have Download, Delete, external Share and future Toolbox.
- LAN transfers use local disk streaming and are not app-size-limited, but disk space/network speed remain physical constraints.
- Sender originals are never deleted by local cleanup. App-owned temporary received copies expire 24h after receiving; expired batches and temporary records are pruned.
- QR guest browser files are available only to the owner's secret-authorized Worker clients, and expire at midnight IST. Guest quota accounting survives until its rolling 24h end.
- Idle cloud polling is disabled. Cloud inbox needs explicit Refresh until push notification/real-time delivery is built.
- A browser does not reveal a permanent hardware ID. Guest cookie and hashed IP are abuse signals, not guaranteed person identity.

## Still required before a finished release

First get the manual test build green, then test Android↔Windows real LAN transfers (several files, 0 B, 1GB+, disconnect/reconnect); fix plugin/manifest/firewall issues; implement reliable resume and Android background operation; secure cross-device login and full API-token auto-provisioning; test 200 MB/4-session Worker quota and midnight cleanup on a user-owned account; implement event-driven delivery; do security review, load testing and release signing.

Repository may be publicly visible. Assume all committed code is public; protect tokens and secrets.


## Draft PR #1 — Offline LAN improvements (not merged)

- Receive photo card thumbnail opens a full-screen pinch/zoom preview. Download on receiver only, Delete, Open in Other App, External Share and future Toolbox icons are shown.
- Android system Sharesheet receives shared WhatsApp/gallery/documents as private pending items. **Selecting a file never transmits it.**
- The Send action explicitly commits copies to a 24-hour persistent local queue. Send works without nearby devices; discovery later triggers automatic delivery to newly connected peers. Successful delivery is tracked per unique device and file.
- Files menu now contains Images / Documents / Folders (transfer-batch groups). Devices shows the actual live LAN list. History and Tools are removed from the navigation drawer.
- Header Refresh has a spinning animation. Android adds an optional foreground service and Wi-Fi multicast lock.
- Cloud and QR code are unchanged. Menu Login/Logout is currently derived from the optional manually paired Worker session, **not** a production email/password login. Local sign-out keeps encrypted Worker configuration, but account-based re-login/cross-device restoration are still NOT implemented.
- Android 15+ dataSync foreground services have a six-hour background time limit; a service cannot guarantee perpetual discovery after OS kill/reboot. A future native receive/background scheduling audit remains essential.
- Windows has Flutter UI and Dart LAN engine parity but still requires native build and firewall/LAN tests.
- No automated LAN E2E test has yet proven actual two-device delivery. Do not use confidential files on untrusted Wi-Fi: local LAN transfers currently have no pairing or encryption.
