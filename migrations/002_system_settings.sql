-- System settings for feature flags
CREATE TABLE system_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT 'false',
    description TEXT,
    updated_by TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO system_settings (key, value, description) VALUES
    ('copilot_metrics_sync_enabled', 'false', 'Enable GitHub Copilot Metrics sync worker'),
    ('audit_search_enabled', 'false', 'Enable audit log search API endpoint'),
    ('advanced_metrics_enabled', 'false', 'Enable detailed sticky/rebind/overflow metrics'),
    ('model_catalog_json', '[{"exposed":"gpt-4o","upstream":"gpt-4o","enabled":true},{"exposed":"gpt-4o-mini","upstream":"gpt-4o-mini","enabled":true},{"exposed":"claude-sonnet-4-20250514","upstream":"claude-sonnet-4-20250514","enabled":true},{"exposed":"claude-3.5-sonnet","upstream":"claude-3.5-sonnet","enabled":true},{"exposed":"o3-mini","upstream":"o3-mini","enabled":true}]', 'Model catalog exposed to downstream clients');
