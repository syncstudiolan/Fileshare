-- Central File Share directory operated by the File Share publisher.
-- This database contains email -> personal Worker address ONLY.
-- No user passwords, no Cloudflare API tokens, no files, no Worker owner keys.
CREATE TABLE IF NOT EXISTS accounts (
  email TEXT PRIMARY KEY,
  worker_url TEXT NOT NULL,
  verified_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS claims (
  email TEXT PRIMARY KEY,
  worker_url TEXT NOT NULL,
  nonce TEXT NOT NULL,
  otp_hash TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS claims_expiry ON claims(expires_at);
CREATE TABLE IF NOT EXISTS limits (
  id TEXT PRIMARY KEY,
  count INTEGER NOT NULL,
  starts_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS limits_cleanup ON limits(starts_at);
