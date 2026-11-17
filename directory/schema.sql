-- Central File Share directory operated by the File Share publisher.
-- This database contains email -> first-linked personal Worker address ONLY.
-- No passwords, Cloudflare API tokens, files, Worker owner keys, or OTPs.
-- Initial claim requires an authenticated personal Worker session but DOES NOT
-- verify control of the mailbox; linked email -> Worker is immutable.
CREATE TABLE IF NOT EXISTS accounts (
  email TEXT PRIMARY KEY,
  worker_url TEXT NOT NULL,
  verified_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS limits (
  id TEXT PRIMARY KEY,
  count INTEGER NOT NULL,
  starts_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS limits_cleanup ON limits(starts_at);
