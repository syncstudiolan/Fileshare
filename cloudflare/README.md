# Personal Cloudflare backend — user-owned Worker

This folder contains a Worker, D1 schema, private R2 binding, SQLite Durable Object and a static guest-upload page. It **does not require sharing your Cloudflare credentials with ChatGPT**.

## In-app automatic provisioning (primary path)

Users should not manually create Worker/D1/R2 resources. In Android or
Windows, open **Personal Cloud Setup**, enter your own Cloudflare Account ID
and restricted API token, and tap **Verify & Auto Connect**. The app:

1. Checks the token and existing resources in the user's own account.
2. Creates/reuses its private D1 database and R2 bucket, then applies the
   `schema.sql` tables.
3. Uploads the module Worker, embeds the guest HTML, configures D1/R2
   bindings, hibernating inbox notification object and an owner secret stored in OS secure storage.
4. Enables the personal workers.dev address, schedules cleanup, and runs
   a private D1/R2 storage round-trip self-test.
5. Allows one email/password account to be registered in the personal Worker;
   the app links it to the Central Directory with a signed Worker session.

On a second device, the user signs in via the Directory with email/password,
and is returned to the *same* personal Worker. Email OTP has been removed;
email address ownership is **not** verified. The first Directory binding
remains immutable to prevent subsequent use of a different Cloudflare Worker.
The Cloudflare admin API token is cleared and never stored by the app.

The account owner must first enable Cloudflare R2 and workers.dev as needed
and create a restricted token with permissions to manage D1, R2 and Workers.
No global API key, additional domain or email sender is required.

Manual Wrangler deployment below is an advanced debugging alternative, not
part of normal user onboarding. Do not manually create a Worker with the
automatic naming convention, as the app refuses to overwrite an unknown
existing Worker without its previously saved owner secret.

## API endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/q/{qr}` | Guest browser page, secure guest browser cookie |
| POST | `/v1/guest/session` | Reserve up to 200 MB and one of 4 sessions per IST calendar day |
| PUT | `/v1/guest/file/{session}/{file}` | Small file upload (<= 6 MiB) |
| POST | `/v1/guest/file/{session}/{file}/start` | Begin large multipart upload |
| PUT | `/v1/guest/file/{session}/{file}/part/{number}` | 6 MiB multipart chunk |
| POST | `/v1/guest/file/{session}/{file}/complete` | Complete multipart |
| POST | `/v1/guest/finish/{session}` | Confirm one batch; does NOT upload twice |
| GET/POST | `/v1/owner/qr` | Retrieve/create permanent Guest QR; there is no disable endpoint |
| POST | `/v1/owner/qr/regenerate` | Rotate QR token and immediately create a new active Guest QR |
| GET | `/v1/owner/files?offset=0` | Protected guest inbox, paginated |
| GET/DELETE | `/v1/owner/file/{id}` | Stream/download or delete the owner's file |
| GET (WebSocket) | `/v1/owner/events` | Authenticated live inbox invalidation; hibernating Durable Object |
| GET | `/health` | Basic public health check |

Owner endpoints require a valid signed personal Worker session or the setup-only `OWNER_TOKEN`. The owner secret is kept in the OS secure vault and never committed.

## Quotas, cleanup and request budgets

- Guest identity is a secure cookie + separate hashed IP. Browsers do **not** expose genuine hardware IDs; clearing cookies or switching browsers can bypass personal limits.
- Each QR/guest identity gets four sessions and 200 MiB of reserved files per IST calendar day. A session may contain many smaller files (up to 500 selections in the current implementation).
- Large files use 6 MiB R2 multipart chunks. No single 200 MB HTTP request is attempted.
- **Guest QR and logged-in device-to-device Cloud transfers** (up to 200 MiB per file) expire at the next **00:00 IST**, regardless of their upload time. LAN-only files retain their separate rolling 24-hour expiry. The Auto Cloud Transfer toggle defaults ON: a discovered LAN device always wins; with zero LAN peers the app chooses Cloud only if logged in and toggle ON. With toggle OFF or no login, outgoing files go to LAN Pending for automatic delivery when a nearby LAN device appears. The toggle never affects Guest QR uploads, QR availability, or incoming QR notifications.
- Files uploaded before the following 00:00 IST expire at that midnight. Expired R2 objects, D1 upload rows, D1 multipart-part records and unreferenced expired guest-session rows are deleted together; no persistent deletion queue is created. The per-guest quota resets at midnight IST.
- Cron jobs at 18:30, 20:30 and 22:30 UTC (00:00, 02:00, 04:00 IST) perform one cleanup and up to two delayed retries, instead of constant polling. R2 keys are deleted in batches; D1 records in <=100-ID statements to respect D1's 100-parameter limit. Successful progress causes **at most one WebSocket `files-changed` event per scheduled invocation**, not one event per file. Empty retries send no event or R2 delete request.
- The cleanup also aborts incomplete device-to-device R2 multipart uploads, removes device-transfer D1 records and multipart parts, and keeps no persistent cloud delete queue. Actual deletion runs at midnight IST via scheduled cleanup, with retry crons if a storage operation fails.
- The cleanup checks D1 first and **does not issue an R2 delete request when there are no expired files**. If R2 deletion fails, affected D1 upload records are retained for the retry cron; no separate queue records are stored. The app also removes expired QR cards locally at midnight without needing a network call. The permanent QR code and personal owner account remain intact.
- Each cleanup processes up to 20 batches of 500 files. Additional backlog waits for the next scheduled run.
- Client files already saved into the user's Downloads folder are NOT deleted by this cloud cleanup.

## Known limitations before production use

- Personal Worker auto-provisioning and account login are implemented in the app but have not been verified using a new real Android/Windows device setup. The separate Central Directory is already deployed.
- The Free-tier-friendly password KDF is peppered with the private Worker secret and includes login throttling, but still needs live CPU-budget validation.
- Event-based **foreground** QR inbox: a guest batch completion emits one small `files-changed` message from the Personal Worker to a hibernatable Durable Object and owner WebSocket. The app refreshes inbox metadata on that signal or reconnect, with no 15-second polling. Multiple devices may listen to the same private room. WebSocket connections and notifications still count toward Free quotas, but an idle hibernated object does not need an always-awake worker. This is not Android push when the app is terminated.
- When the app is in background or stopped, WebSockets cannot reliably deliver notifications. On resume it reconnects and reads D1 to recover missed files. Background notifications would require separate Android push integration.
- **Existing clients upgrading from an older Worker**: after merging this Draft and installing the corresponding APK, the owner must run **Verify & Auto Connect** again with a restricted Cloudflare token on the originally provisioned device. It reuses the existing personal Worker/D1/R2, applies the `InboxEvents` SQLite Durable Object migration and keeps the saved owner secret. Do not disconnect, clear app data or regenerate QR. A different device without the original bootstrap secret cannot overwrite that Worker.
- `404`/`503` from the legacy live endpoint is not retried every minute. The manual Refresh button continues working until upgrade.
- Browser cookie/IP checks are abuse deterrents, not strong person identity. Additional anti-abuse controls and guest session hardening need security testing.
- Cloudflare R2 operations, D1 rows and Worker requests use each user's own quotas/billing.
- Cloudflare's exact midnight execution timing and Android background behavior are not guaranteed to the second.

Keep this backend separate from any legacy project and never commit private secrets.