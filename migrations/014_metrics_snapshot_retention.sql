CREATE INDEX IF NOT EXISTS idx_copilot_metrics_snapshots_org_synced
    ON copilot_metrics_snapshots(org_id, synced_at DESC);