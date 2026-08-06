-- 001_init.sql
-- GHCP Pool Proxy consolidated development schema.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE github_orgs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    github_org_id TEXT NOT NULL UNIQUE,
    login TEXT NOT NULL,
    display_name TEXT,
    copilot_plan TEXT NOT NULL,
    metrics_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    last_metrics_sync_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE github_teams (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES github_orgs(id),
    github_team_id TEXT,
    slug TEXT NOT NULL,
    name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    provider TEXT NOT NULL,
    account_source TEXT NOT NULL,
    github_login TEXT,
    org_id UUID REFERENCES github_orgs(id),
    team_id UUID REFERENCES github_teams(id),
    copilot_plan TEXT,
    seat_status TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    risk_score INT NOT NULL DEFAULT 0,
    priority INT NOT NULL DEFAULT 100,
    max_concurrency INT NOT NULL DEFAULT 6,
    current_failure_count INT NOT NULL DEFAULT 0,
    last_success_at TIMESTAMPTZ,
    last_failure_at TIMESTAMPTZ,
    last_failure_reason TEXT,
    next_token_probe_at TIMESTAMPTZ,
    token_probe_claim_id UUID,
    token_probe_claimed_by TEXT,
    token_probe_claimed_until TIMESTAMPTZ,
    last_token_probe_at TIMESTAMPTZ,
    last_token_probe_success_at TIMESTAMPTZ,
    last_token_probe_failure_at TIMESTAMPTZ,
    last_token_probe_failure_reason TEXT,
    next_re_admission_at TIMESTAMPTZ,
    re_admission_claim_id UUID,
    re_admission_claimed_by TEXT,
    re_admission_claimed_until TIMESTAMPTZ,
    last_re_admission_at TIMESTAMPTZ,
    last_re_admission_success_at TIMESTAMPTZ,
    last_re_admission_failure_at TIMESTAMPTZ,
    last_re_admission_failure_reason TEXT,
    re_admission_attempt_count INT NOT NULL DEFAULT 0,
    health_version BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_accounts_status ON accounts(status);
CREATE INDEX idx_accounts_source ON accounts(account_source);
CREATE INDEX idx_accounts_due_token_probe
    ON accounts (next_token_probe_at, id)
    WHERE status IN ('active', 'degraded');
CREATE INDEX idx_accounts_due_re_admission
    ON accounts (next_re_admission_at, id)
    WHERE status = 'degraded';

CREATE TABLE copilot_seats (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID REFERENCES accounts(id),
    org_id UUID REFERENCES github_orgs(id),
    team_id UUID REFERENCES github_teams(id),
    github_user_login TEXT NOT NULL,
    seat_type TEXT NOT NULL,
    status TEXT NOT NULL,
    assigned_at TIMESTAMPTZ,
    last_activity_at TIMESTAMPTZ,
    last_synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE credentials (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES accounts(id),
    type TEXT NOT NULL,
    status TEXT NOT NULL,
    encrypted_payload BYTEA NOT NULL,
    key_version TEXT NOT NULL,
    expires_at TIMESTAMPTZ,
    last_used_at TIMESTAMPTZ,
    last_rotated_at TIMESTAMPTZ,
    source TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_credentials_account ON credentials(account_id);

CREATE TABLE backend_pools (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    allocation_mode TEXT NOT NULL DEFAULT 'shared' CHECK (allocation_mode IN ('shared', 'user_binding', 'session_binding')),
    load_balance_strategy TEXT NOT NULL DEFAULT 'risk_weighted' CHECK (load_balance_strategy IN ('risk_weighted', 'round_robin', 'least_concurrency')),
    binding_max_concurrency INT NOT NULL DEFAULT 10,
    binding_ttl_seconds INT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE pool_accounts (
    pool_id UUID NOT NULL REFERENCES backend_pools(id),
    account_id UUID NOT NULL REFERENCES accounts(id),
    weight INT NOT NULL DEFAULT 100,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (pool_id, account_id)
);

CREATE UNIQUE INDEX idx_pool_accounts_account_unique ON pool_accounts(account_id);

CREATE TABLE client_profiles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    api_key_hash TEXT NOT NULL UNIQUE,
    pool_id UUID NOT NULL REFERENCES backend_pools(id) ON DELETE RESTRICT,
    default_request_format TEXT NOT NULL,
    default_response_format TEXT NOT NULL,
    default_model TEXT,
    model_aliases JSONB NOT NULL DEFAULT '{}',
    tool_format TEXT,
    sticky_mode TEXT NOT NULL DEFAULT 'soft',
    affinity_strategy TEXT NOT NULL DEFAULT 'session_then_prefix',
    sticky_ttl_seconds INT NOT NULL DEFAULT 1800,
    sticky_session_header TEXT,
    cache_affinity_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    max_sticky_load_ratio NUMERIC(5,2) NOT NULL DEFAULT 0.85,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE usage_ledger (
    id UUID NOT NULL DEFAULT gen_random_uuid(),
    trace_id TEXT NOT NULL,
    account_id UUID,
    pool_id UUID,
    client_profile_id UUID,
    model TEXT,
    request_format TEXT,
    response_format TEXT,
    affinity_key_hash TEXT,
    sticky_hit BOOLEAN,
    status TEXT NOT NULL,
    input_tokens INT NOT NULL DEFAULT 0,
    cached_input_tokens INT NOT NULL DEFAULT 0,
    cache_write_tokens INT NOT NULL DEFAULT 0,
    output_tokens INT NOT NULL DEFAULT 0,
    reasoning_tokens INT NOT NULL DEFAULT 0,
    nano_aiu BIGINT NOT NULL DEFAULT 0,
    estimated_ai_credits NUMERIC(20,9) NOT NULL DEFAULT 0,
    token_details JSONB NOT NULL DEFAULT '[]'::jsonb,
    estimated_cost NUMERIC(20,8) NOT NULL DEFAULT 0,
    latency_ms INT,
    error_type TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now()
) PARTITION BY RANGE (created_at);

DO $partitions$
DECLARE
    partition_day DATE;
    partition_name TEXT;
BEGIN
    FOR partition_day IN
        SELECT generate_series(
            (current_timestamp AT TIME ZONE 'UTC')::date,
            (current_timestamp AT TIME ZONE 'UTC')::date + 7,
            interval '1 day'
        )::date
    LOOP
        partition_name := 'usage_ledger_p' || to_char(partition_day, 'YYYYMMDD');
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF usage_ledger FOR VALUES FROM (%L) TO (%L)',
            partition_name,
            partition_day::text || ' 00:00:00+00',
            (partition_day + 1)::text || ' 00:00:00+00'
        );
    END LOOP;
END
$partitions$;

CREATE TABLE usage_ledger_default PARTITION OF usage_ledger DEFAULT;
CREATE INDEX idx_usage_ledger_created_brin ON usage_ledger USING BRIN(created_at);
CREATE INDEX idx_usage_ledger_ingested_brin ON usage_ledger USING BRIN(ingested_at);
CREATE VIEW usage_ledger_all AS SELECT * FROM usage_ledger;

CREATE TABLE usage_ledger_legacy_state (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    max_created_at TIMESTAMPTZ,
    truncated_at TIMESTAMPTZ
);

CREATE TABLE copilot_metrics_snapshots (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    scope_type TEXT NOT NULL,
    scope_id TEXT NOT NULL,
    org_id UUID REFERENCES github_orgs(id),
    window_start TIMESTAMPTZ NOT NULL,
    window_end TIMESTAMPTZ NOT NULL,
    active_users INT,
    engaged_users INT,
    suggestions_count BIGINT,
    acceptances_count BIGINT,
    chats_count BIGINT,
    raw_payload JSONB NOT NULL,
    source TEXT NOT NULL,
    synced_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX idx_copilot_metrics_snapshots_org_synced
    ON copilot_metrics_snapshots(org_id, synced_at DESC);

CREATE TABLE audit_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id TEXT,
    action TEXT NOT NULL,
    target_type TEXT NOT NULL,
    target_id TEXT NOT NULL,
    before JSONB,
    after JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_audit_events_target ON audit_events(target_type, target_id);
CREATE INDEX idx_audit_events_created ON audit_events(created_at);

CREATE TABLE recovery_tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES accounts(id),
    status TEXT NOT NULL,
    reason TEXT NOT NULL,
    assigned_to TEXT,
    notes TEXT,
    claim_id UUID,
    claimed_by TEXT,
    claimed_until TIMESTAMPTZ,
    attempt_count INT NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ,
    source_status TEXT,
    current_step TEXT,
    failure_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ
);

CREATE INDEX idx_recovery_tasks_account ON recovery_tasks(account_id);
CREATE INDEX idx_recovery_tasks_status ON recovery_tasks(status);
CREATE UNIQUE INDEX idx_recovery_tasks_account_nonterminal
    ON recovery_tasks (account_id)
    WHERE status IN ('pending', 'running');
CREATE INDEX idx_recovery_tasks_due
    ON recovery_tasks (next_attempt_at, created_at, id)
    WHERE status IN ('pending', 'running');

CREATE TABLE system_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT 'false',
    description TEXT,
    updated_by TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO system_settings (key, value, description) VALUES
    ('schema_version', '16', 'Installed database schema version'),
    ('copilot_metrics_sync_enabled', 'false', 'Enable GitHub Copilot Metrics sync worker'),
    ('audit_search_enabled', 'false', 'Enable audit log search API endpoint'),
    ('advanced_metrics_enabled', 'false', 'Enable detailed sticky/rebind/overflow metrics'),
    ('copilot_compat_anthropic_beta_enabled', 'true', 'Allow verified Anthropic beta feature tokens for Copilot Messages requests'),
    ('copilot_compat_thinking_tool_choice_enabled', 'true', 'Normalize incompatible Anthropic thinking and forced tool choice combinations'),
    ('copilot_compat_cache_control_enabled', 'true', 'Remove unsupported Anthropic cache control subfields while preserving cache breakpoints'),
    ('copilot_compat_vision_header_enabled', 'true', 'Send the Copilot vision request header when a request contains images'),
    ('model_catalog_json', '[{"exposed":"gpt-4o","upstream":"gpt-4o","enabled":true},{"exposed":"gpt-4o-mini","upstream":"gpt-4o-mini","enabled":true},{"exposed":"gpt-5.5","upstream":"gpt-5.5","upstream_api":"responses","enabled":true},{"exposed":"claude-sonnet-4-20250514","upstream":"claude-sonnet-4-20250514","enabled":true},{"exposed":"claude-3.5-sonnet","upstream":"claude-3.5-sonnet","enabled":true},{"exposed":"o3-mini","upstream":"o3-mini","enabled":true}]', 'Model catalog exposed to downstream clients');

CREATE TABLE secure_settings (
    key TEXT PRIMARY KEY,
    encrypted_value BYTEA NOT NULL,
    key_version TEXT NOT NULL,
    description TEXT,
    updated_by TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE usage_rollup_state (
    name TEXT PRIMARY KEY,
    last_processed_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE usage_rollup_hourly (
    bucket_start TIMESTAMPTZ NOT NULL,
    client_profile_id TEXT NOT NULL DEFAULT '',
    client_name TEXT NOT NULL DEFAULT 'unknown',
    account_id TEXT NOT NULL DEFAULT '',
    pool_id TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    request_format TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL,
    requests BIGINT NOT NULL DEFAULT 0,
    input_tokens BIGINT NOT NULL DEFAULT 0,
    cached_input_tokens BIGINT NOT NULL DEFAULT 0,
    cache_write_tokens BIGINT NOT NULL DEFAULT 0,
    output_tokens BIGINT NOT NULL DEFAULT 0,
    reasoning_tokens BIGINT NOT NULL DEFAULT 0,
    nano_aiu BIGINT NOT NULL DEFAULT 0,
    estimated_ai_credits NUMERIC(20,9) NOT NULL DEFAULT 0,
    estimated_cost NUMERIC(20,8) NOT NULL DEFAULT 0,
    latency_ms_sum BIGINT NOT NULL DEFAULT 0,
    latency_ms_count BIGINT NOT NULL DEFAULT 0,
    latency_ms_max INT NOT NULL DEFAULT 0,
    sticky_hits BIGINT NOT NULL DEFAULT 0,
    errors BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (bucket_start, client_profile_id, account_id, pool_id, model, request_format, status)
) PARTITION BY RANGE (bucket_start);

CREATE INDEX idx_usage_rollup_hourly_bucket ON usage_rollup_hourly(bucket_start);
CREATE INDEX idx_usage_rollup_hourly_client_bucket ON usage_rollup_hourly(client_profile_id, bucket_start);
CREATE INDEX idx_usage_rollup_hourly_model_bucket ON usage_rollup_hourly(model, bucket_start);
CREATE TABLE usage_rollup_hourly_default PARTITION OF usage_rollup_hourly DEFAULT;

CREATE TABLE usage_rollup_daily (
    bucket_date DATE NOT NULL,
    client_profile_id TEXT NOT NULL DEFAULT '',
    client_name TEXT NOT NULL DEFAULT 'unknown',
    account_id TEXT NOT NULL DEFAULT '',
    pool_id TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    request_format TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL,
    requests BIGINT NOT NULL DEFAULT 0,
    input_tokens BIGINT NOT NULL DEFAULT 0,
    cached_input_tokens BIGINT NOT NULL DEFAULT 0,
    cache_write_tokens BIGINT NOT NULL DEFAULT 0,
    output_tokens BIGINT NOT NULL DEFAULT 0,
    reasoning_tokens BIGINT NOT NULL DEFAULT 0,
    nano_aiu BIGINT NOT NULL DEFAULT 0,
    estimated_ai_credits NUMERIC(20,9) NOT NULL DEFAULT 0,
    estimated_cost NUMERIC(20,8) NOT NULL DEFAULT 0,
    latency_ms_sum BIGINT NOT NULL DEFAULT 0,
    latency_ms_count BIGINT NOT NULL DEFAULT 0,
    latency_ms_max INT NOT NULL DEFAULT 0,
    sticky_hits BIGINT NOT NULL DEFAULT 0,
    errors BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (bucket_date, client_profile_id, account_id, pool_id, model, request_format, status)
) PARTITION BY RANGE (bucket_date);

CREATE INDEX idx_usage_rollup_daily_date ON usage_rollup_daily(bucket_date);
CREATE INDEX idx_usage_rollup_daily_client_date ON usage_rollup_daily(client_profile_id, bucket_date);
CREATE INDEX idx_usage_rollup_daily_model_date ON usage_rollup_daily(model, bucket_date);
CREATE TABLE usage_rollup_daily_default PARTITION OF usage_rollup_daily DEFAULT;

INSERT INTO usage_rollup_state (name, last_processed_at, updated_at)
SELECT 'usage_rollup', COALESCE(MIN(created_at), now()), now()
FROM usage_ledger_all
ON CONFLICT (name) DO NOTHING;

CREATE TABLE account_user_bindings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_profile_id UUID NOT NULL REFERENCES client_profiles(id) ON DELETE CASCADE,
    pool_id UUID NOT NULL REFERENCES backend_pools(id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    user_id_hash TEXT NOT NULL,
    user_id_display TEXT NOT NULL,
    user_id_source TEXT,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'released', 'expired')),
    last_used_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    released_at TIMESTAMPTZ,
    release_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_account_user_bindings_active_owner
    ON account_user_bindings(client_profile_id, pool_id, user_id_hash)
    WHERE status = 'active';

CREATE UNIQUE INDEX idx_account_user_bindings_active_account
    ON account_user_bindings(account_id)
    WHERE status = 'active';

CREATE INDEX idx_account_user_bindings_pool_status
    ON account_user_bindings(pool_id, status, expires_at);

CREATE INDEX idx_account_user_bindings_expires
    ON account_user_bindings(status, expires_at);

CREATE TABLE account_session_bindings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_profile_id UUID NOT NULL REFERENCES client_profiles(id) ON DELETE CASCADE,
    pool_id UUID NOT NULL REFERENCES backend_pools(id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    session_id_hash TEXT NOT NULL,
    session_id_display TEXT NOT NULL,
    session_id_source TEXT,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'released', 'expired')),
    last_used_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    released_at TIMESTAMPTZ,
    release_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_account_session_bindings_active_owner
    ON account_session_bindings(client_profile_id, pool_id, session_id_hash)
    WHERE status = 'active';

CREATE UNIQUE INDEX idx_account_session_bindings_active_account
    ON account_session_bindings(account_id)
    WHERE status = 'active';

CREATE INDEX idx_account_session_bindings_pool_status
    ON account_session_bindings(pool_id, status, expires_at);

CREATE INDEX idx_account_session_bindings_expires
    ON account_session_bindings(status, expires_at);
