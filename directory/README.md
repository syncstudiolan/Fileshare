# File Share Account Directory (one shared directory)

This is a **separate, minimal service operated by the File Share app
publisher**, not one of the customer's own Workers. It enables a person to
install File Share on a second Android/Windows device, type **only their email
and password**, and automatically reconnect to their original Cloudflare
Worker without entering its address or configuring Cloudflare again.

## Architecture

1. On first setup the user activates R2 in their own Cloudflare account,
   provisions their own Worker and D1, and creates an owner account there.
2. On that first device the app sends the owner's email, personal Worker
   **URL**, and *short-lived signed personal session* to this directory.
   The directory verifies the session directly with the personal Worker.
   It does not trust an unsigned claim of Worker ownership.
3. The directory sends an eight-digit verification code to that email.
   After confirmation it stores **email -> personal Worker URL** in its own
   D1 database. It stores **NO plaintext password, password hash, Cloudflare
   API token, secret, or transferred file**. The one-time code is only stored
   as a keyed HMAC, expires in 10 minutes, and has 5 tries.
4. On a new device File Share sends email + password via HTTPS to this
   directory. The directory looks up the verified Worker URL **privately**,
   forwards the credentials via HTTPS directly to the owner's Worker auth
   endpoint, then returns that Worker's signed, expiring login session and
   Worker URL to the client. The client independently verifies the session
   with the personal Worker before storing it in OS secure storage.
5. The user receives their files through the same private Worker, D1 and R2
   account. No repeated Cloudflare token or user-facing Worker URL is needed.
   Offline LAN mode never requires the central service.

This avoids two separate password databases. Directory transport may see
passwords transiently to forward the login request, but neither stores nor
logs them. Existing per-user Worker stores only its salted password verifier.
To avoid account takeover, claiming another email requires both a valid
Worker account session **and** proof of email ownership by OTP.

## Operator setup and deployment status — 2026-11-17

Operator infrastructure created (without Android/Windows builds):

- Cloudflare Worker `fileshare-directory` has been uploaded and enabled at
  `https://fileshare-directory.modeltech0.workers.dev`.
- Dedicated D1 `fileshare-directory-db` was created; `schema.sql` applied.
- Cloudflare bindings `DB` and `DIRECTORY_OTP_SECRET` were configured.
- Daily D1 cleanup schedule `0 3 * * *` configured.
- Both Flutter platform targets share `AccountDirectory`, now pointed at
  this operator-owned HTTPS endpoint by default.

**Not yet operational end-to-end:** no transactional sender credentials,
verified sender domain, or `EMAIL_FROM` have been configured. Therefore
`/v1/directory/claim` intentionally returns 503. Do not represent new-user
email verification, account creation, or second-device login as passed.
No personal user Worker was provisioned and no real Android/Windows login was
performed during this infrastructure-only setup.
Personal Worker auto-provisioning is implemented in the Flutter app (D1, R2,
Worker module, bindings, owner secret, schedules and storage self-test), and
the Cloudflare multipart metadata transport has been corrected. This is
code-level readiness, not a passed live provisioning test. Initial account
registration may continue locally if email linking is unavailable, but
**email-only login on a new device stays unavailable until OTP verification**. Do not run release/build
workflows without a separate instruction.

Remaining operator steps:

1. Keep the existing D1 binding and schema intact; do not create a duplicate.
2. Configure a transactional email sender (Resend is supported). Set
   Worker secrets **DIRECTORY_OTP_SECRET** (random 32+ bytes) and
   **RESEND_API_KEY**. Configure **EMAIL_FROM** with an authenticated sending
   address and, if needed, **ALLOWED_ORIGIN** for official web clients.
   Secrets stay in Cloudflare, NEVER in GitHub or the APK.
3. The directory Worker and default app URL are now configured. Confirm
   HTTPS `/health` and email delivery before enabling production sign-up.
   Override with **FILE_SHARE_DIRECTORY_URL** only for isolated staging.
4. Verify outbound email availability, usage/quota, TLS, abuse controls,
   D1 migrations, rate limiting and password security on a **test** account.
   Prefer free tiers; do not enable a paid provider without approval.
5. Monitor errors, provider limits and abuse protections. Enable Cloudflare
   WAF/Turnstile if the global public directory faces excessive traffic.

The directory URL is now configured in the shared Flutter app. This alone
DOES NOT make email-only login operational until OTP sending is configured,
a personal Worker is provisioned, and E2E tests pass. A prior-user personal
Worker manual-login fallback remains available in the app.

### Routes

- POST /v1/directory/claim: { email, workerUrl, personalSession } -> OTP email
- POST /v1/directory/verify: { email, code } -> verified mapping
- POST /v1/directory/login: { email, password } -> { workerUrl, session, expiresAt, email }
- GET /health: service status only; NEVER reveals user accounts

Controls: Strict *.workers.dev URL whitelist prevents SSRF, personal Worker
session proof, verified mailbox code, keyed OTP hash, short TTL, login and
send throttles, no password persistence, fixed single-account mapping,
no public email lookup, no redirects to arbitrary Workers, generic login
failure, cleanup cron, no-store responses. Directory currently supports
first-time binding only; changing an existing email's Worker requires
a deliberate recovery/migration protocol, not a blind overwrite.

**Important:** Resend's free tier currently includes a daily sending limit
and requires sender-domain verification for production recipients. Cloudflare
Email Service arbitrary-recipient sending may require Workers Paid.
The operator must explicitly choose a provider and plan before deployment.

The app has not been built, merged, or released. Only the separate directory
Cloudflare infrastructure has been deployed and its API resources inspected.
The code remains saved in the existing Draft PR #1.
