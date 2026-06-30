-- Runtime configuration persisted from the dashboard.
CREATE TABLE IF NOT EXISTS secure_settings (
    key TEXT PRIMARY KEY,
    encrypted_value BYTEA NOT NULL,
    key_version TEXT NOT NULL,
    description TEXT,
    updated_by TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);