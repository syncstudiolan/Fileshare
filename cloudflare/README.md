# Personal Cloudflare backend — user-owned Worker

This folder contains a Worker, D1 schema, private R2 binding and a static guest-upload page. It **does not require sharing your Cloudflare credentials with ChatGPT**.

## Manual deployment for testing

1. Create a separate Cloudflare account (or use your own) and activate R2 as required by Cloudflare. The free allowance does not prevent billing if exceeded.
2. In `cloudflare/`, run `npx wrangler d1 create fileshare-personal-db` and copy the displayed D1 database ID into `wrangler.jsonc`.
3. Run `npx wrangler r2 bucket create fileshare-personal-files`.
4. Run `npx wrangler d1 execute fileshare-personal-db --remote --file=./schema.sql`.
5. Choose a random, strong OWNER_TOKEN of at least 32 characters and set it with `npx wrangler secret put OWNER_TOKEN`. Never put it in git, code, screenshots or chat.
6. Run `npx wrangler deploy`. Note the assigned HTTPS `*.workers.dev` URL.
7. Open the File Share app → Cloud Setup → enter that Worker URL and the **Worker OWNER_TOKEN**. This is a manual integration-test connection. It is **NOT** the Cloudflare Account API token.
8. Open My QR → Generate Permanent QR → share the QR URL with a guest. The guest's ordinary camera opens the browser upload page.

Worker setup permissions require one-time Cloudflare authorization by the account owner. `Account ID + restricted Cloudflare API token -> fully automatic provisioning` is NOT implemented yet, and app email/password authentication is not live.

## API endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/q/{qr}` | Guest browser page, secure guest browser cookie |
| POST | `/v1/guest/session` | Reserve up to 200 MB and one of 4 sessions in rolling 24 hours |
| PUT | `/v1/guest/file/{session}/{file}` | Small file upload (<= 6 MiB) |
| POST | `/v1/guest/file/{session}/{file}/start` | Begin large multipart upload |
| PUT | `/v1/guest/file/{session}/{file}/part/{number}` | 6 MiB multipart chunk |
| POST | `/v1/guest/file/{session}/{file}/complete` | Complete multipart |
| POST | `/v1/guest/finish/{session}` | Confirm one batch; does NOT upload twice |
| GET/POST/DELETE | `/v1/owner/qr` | Retrieve/create/revoke permanent QR |
| POST | `/v1/owner/qr/regenerate` | Revoke old QR and generate a new one |
| GET | `/v1/owner/files?offset=0` | Protected guest inbox, paginated |
| GET/DELETE | `/v1/owner/file/{id}` | Stream/download or delete the owner's file |
| GET | `/health` | Basic public health check |

Owner endpoints require `Authorization: Bearer <OWNER_TOKEN>`. The secret must only be stored in an OS encrypted vault on client devices.

## Quotas, cleanup and request budgets

- Guest identity is a secure cookie + separate hashed IP. Browsers do **not** expose genuine hardware IDs; clearing cookies or switching browsers can bypass personal limits.
- Each QR/guest identity gets four sessions and 200 MiB of reserved files over a rolling 24-hour window. A session may contain many smaller files (up to 500 selections in the current implementation).
- Large files use 6 MiB R2 multipart chunks. No single 200 MB HTTP request is attempted.
- Files uploaded before the following 00:00 IST expire at that midnight. Guest quota records survive until their rolling 24h window ends.
- Cron jobs at 18:30, 20:30 and 22:30 UTC (00:00, 02:00, 04:00 IST) perform one cleanup and up to two delayed retries, instead of constant polling.
- The cleanup checks D1 first and **does not issue an R2 delete request when there are no expired files**.
- Each cleanup processes up to 20 batches of 500 files. Additional backlog waits for the next scheduled run.
- Client files already saved into the user's Downloads folder are NOT deleted by this cloud cleanup.

## Known limitations before production use

- The Worker and D1/R2 configuration have NOT been deployed or tested against a live Cloudflare account here.
- No full authentication system, centralized account directory, multi-device secure token pairing or automatic Cloudflare provisioning is shipped yet.
- No real-time WebSocket push notification / Android background push; the owner app currently refreshes its QR feed manually.
- Browser cookie/IP checks are abuse deterrents, not strong person identity. Additional anti-abuse controls and guest session hardening need security testing.
- Cloudflare R2 operations, D1 rows and Worker requests use each user's own quotas/billing.
- Cloudflare's exact midnight execution timing and Android background behavior are not guaranteed to the second.

Keep this backend separate from any legacy project and never commit private secrets.