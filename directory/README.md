# File Share Central Account Directory

This Worker is deployed separately from each user's personal Cloudflare account.
Official endpoint: `https://fileshare-directory.modeltech0.workers.dev`.
Operator-owned D1: `fileshare-directory-db`.

## How registration works (no email OTP)

1. On a new Android or Windows device, the user opens **Set up or connect personal Cloudflare**.
2. They provide their own Cloudflare Account ID and restricted API token.
3. **Verify & Auto Connect** provisions a user-owned Worker, D1, R2 bucket,
   applies the D1 schema, sets an owner secret, publishes the guest QR upload
   page, schedules cleanup, and confirms storage with a self-test.
4. The user creates one personal Worker account using an email and password.
5. The app sends the signed *personal Worker login session* and Worker URL to
   the Central Directory over HTTPS. The Directory verifies this session by
   calling the specific personal Worker's `/v1/auth/me` endpoint, then makes
   an immutable first binding `email -> personal Worker URL`.
6. On a second device, entering email and password makes the Directory
   authenticate against that same Worker. Its signed session is independently
   checked by the app before it is persisted in the OS secure storage.

No email is sent. No OTP is generated or checked. There are no Resend or
transactional email credentials. The account's password, API token, and files
are never written to Central D1. The API token is not persisted by the app.

**Important security limitation:** Without an external email-verification
provider, neither the app nor Cloudflare can prove mailbox ownership. The
first person to register and link a given email could be someone other than
the mailbox owner. The one-email-one-cloud constraint prevents *subsequent*
rebindings; it cannot protect against initial email impersonation. For
strong mailbox ownership proof in the future, add an actual email provider
or another external identity-verification mechanism.

## Cloud isolation and limits

- First binding is permanent: the same email cannot link a different
  personal Worker. An already-linked account can safely retry the same Worker.
- Each personal Worker registers exactly one owner account via an owner
  setup secret; its login verifies the stored salted password hash.
- The Directory accepts only exact HTTPS `*.workers.dev` hosts, no arbitrary
  URLs, ports, credentials, query strings, or redirects.
- Directory throttles link and login attempts using D1; personal Worker also
  limits failed logins. Do not disable brute-force protection.
- Each client's files stay in that client's own R2 and D1, not Central D1.
- Account recovery, email changes, and cloud migration are **not automated**.
  Do not bypass the immutable binding without a deliberate recovery procedure.

## Live configuration

The operator's Cloudflare account has the `fileshare-directory` Worker,
`fileshare-directory-db` D1, `DB` binding, `DIRECTORY_RATE_SECRET` secret,
and a daily maintenance trigger. Old email OTP bindings, claim table, and
verification endpoints have been removed. The official Flutter client uses
the deployed URL by default, with `FILE_SHARE_DIRECTORY_URL` override only
for isolated staging builds.

The Directory API:
- `GET /health`
- `POST /v1/directory/claim` — `{email, workerUrl, personalSession}`
  → `{ok:true,linked:true}` after authenticated first binding
- `POST /v1/directory/login` — `{email,password}`
  → `{workerUrl,session,expiresAt,email}` after Worker authentication

The personal Worker provides QR creation/regeneration, browser guest uploads
to private R2, owner inbox and cleanup schedules.

## Validation and release policy

The code is in existing Draft PR #1, branch `offline-lan-fixes`. App
build/release workflows must NOT be triggered until separately requested.
Cloudflare deployment alone does not prove first-device auto-provisioning,
email/password login on real Android/Windows builds, guest browser upload,
or cross-device sign-in. These require explicit device tests.
