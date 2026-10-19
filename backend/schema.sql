DROP TABLE IF EXISTS scheduled_pings;
CREATE TABLE IF NOT EXISTS scheduled_pings (
	-- Random UUID, so ping IDs can't be guessed.
	id TEXT PRIMARY KEY,
	-- SHA-256 of the secret returned once by /schedule; /reschedule and /ack
	-- must present the secret.
	secret_hash TEXT NOT NULL,
	device_token TEXT NOT NULL,
	scheduled_time INTEGER NOT NULL,
	require_ack BOOLEAN NOT NULL,
	expire_on INTEGER,
	status TEXT NOT NULL DEFAULT 'PENDING',
	last_sent_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_pending_pings ON scheduled_pings (status, scheduled_time);
CREATE INDEX IF NOT EXISTS idx_pings_device ON scheduled_pings (device_token);
