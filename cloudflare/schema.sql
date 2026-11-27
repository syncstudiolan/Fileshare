-- Run once per user-owned D1 database before deploying the Worker.
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS qr_codes (
  token TEXT PRIMARY KEY,
  active INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS one_active_qr
  ON qr_codes(active) WHERE active = 1;

CREATE TABLE IF NOT EXISTS guest_sessions (
  id TEXT PRIMARY KEY,
  qr TEXT NOT NULL REFERENCES qr_codes(token),
  guest_key TEXT NOT NULL,
  ip_hash TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  reserved_bytes INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  completed INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS rolling_guest_quota
  ON guest_sessions(qr, guest_key, created_at);

CREATE TABLE IF NOT EXISTS uploads (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES guest_sessions(id) ON DELETE CASCADE,
  file_index INTEGER NOT NULL,
  name TEXT NOT NULL,
  size INTEGER NOT NULL,
  object_key TEXT NOT NULL UNIQUE,
  upload_id TEXT,
  completed INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  UNIQUE(session_id, file_index)
);
CREATE INDEX IF NOT EXISTS completed_inbox
  ON uploads(completed, expires_at, created_at);
CREATE INDEX IF NOT EXISTS expired_uploads
  ON uploads(expires_at);

CREATE TABLE IF NOT EXISTS upload_parts (
  file_id TEXT NOT NULL REFERENCES uploads(id) ON DELETE CASCADE,
  part_number INTEGER NOT NULL,
  etag TEXT NOT NULL,
  PRIMARY KEY(file_id, part_number)
);

CREATE TABLE IF NOT EXISTS accounts (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
  email TEXT UNIQUE NOT NULL,
  salt TEXT NOT NULL,
  hash TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS auth_attempts (
  id TEXT PRIMARY KEY,
  failures INTEGER NOT NULL,
  changed_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS auth_attempts_expiry ON auth_attempts(changed_at);

-- Account-only cross-network transfers: separate from Guest QR quota,\n-- but both use next-midnight-IST expiry (LAN has rolling 24h retention).
-- Applied automatically by the SAME first-time API provisioning operation.
CREATE TABLE IF NOT EXISTS device_transfers (
  id TEXT PRIMARY KEY,
  sender_id TEXT NOT NULL,
  sender_name TEXT NOT NULL,
  name TEXT NOT NULL,
  size INTEGER NOT NULL CHECK(size>0 AND size<=209715200),
  object_key TEXT NOT NULL UNIQUE,
  upload_id TEXT,
  completed INTEGER NOT NULL DEFAULT 0,
  received_at INTEGER,
  received_by TEXT,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS device_transfers_inbox
  ON device_transfers(completed,expires_at,created_at);
CREATE TABLE IF NOT EXISTS device_transfer_parts (
  file_id TEXT NOT NULL REFERENCES device_transfers(id) ON DELETE CASCADE,
  part_number INTEGER NOT NULL,
  etag TEXT NOT NULL,
  PRIMARY KEY(file_id,part_number)
);
