DROP TABLE IF EXISTS scheduled_pings;
CREATE TABLE IF NOT EXISTS scheduled_pings (
	id INTEGER PRIMARY KEY,
	device_token TEXT NOT NULL,
	scheduled_time INTEGER NOT NULL,
	require_ack BOOLEAN NOT NULL,
	expire_on INTEGER,
	status TEXT NOT NULL DEFAULT 'PENDING',
	last_sent_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_pending_pings ON scheduled_pings (status, scheduled_time);
