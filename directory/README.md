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

## Operator setup — NOT run as part of this draft

The app publisher (NOT each end-user) must:

1. Create a dedicated Cloudflare D1 database named
   "fileshare-directory-db" and replace the placeholder D1 database ID in
   wrangler.jsonc. Run directory/schema.sql in this D1.
2. Configure a transactional email sender (Resend is supported). Set
   Worker secrets **DIRECTORY_OTP_SECRET** (random 32+ bytes) and
   **RESEND_API_KEY**. Configure **EMAIL_FROM** with an authenticated sending
   address and, if needed, **ALLOWED_ORIGIN** for official web clients.
   Secrets stay in Cloudflare, NEVER in GitHub or the APK.
3. Deploy directory/worker.js under a single permanent HTTPS URL. Set the
   official app build variable **FILE_SHARE_DIRECTORY_URL** to that URL.
   This is operator configuration in a future approved build, NOT a setting
   individual users must enter.
4. Verify outbound email availability, usage/quota, TLS, abuse controls,
   D1 migrations, rate limiting and password security on a **test** account.
   Prefer free tiers; do not enable a paid provider without approval.
5. Monitor errors, provider limits and abuse protections. Enable Cloudflare
   WAF/Turnstile if the global public directory faces excessive traffic.

The directory's Worker URL is NOT hardcoded here because no directory has
yet been deployed. Without an official configured directory endpoint, the
app retains the existing personal Worker URL manual-login fallback. Do not
claim global email-only login works until this global service is actually
deployed, the official build points to it, and E2E tests pass.

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

The current project has intentionally *not* built, run, deployed or merged
this new code, per project-owner instructions. Directory code and tests
are saved on the same draft pull request.
