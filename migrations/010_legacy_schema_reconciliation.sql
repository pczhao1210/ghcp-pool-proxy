CREATE TABLE IF NOT EXISTS system_settings (
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
    ('model_catalog_json', '[{"exposed":"gpt-4o","upstream":"gpt-4o","enabled":true},{"exposed":"gpt-4o-mini","upstream":"gpt-4o-mini","enabled":true},{"exposed":"gpt-5.5","upstream":"gpt-5.5","upstream_api":"responses","enabled":true},{"exposed":"claude-sonnet-4-20250514","upstream":"claude-sonnet-4-20250514","enabled":true},{"exposed":"claude-3.5-sonnet","upstream":"claude-3.5-sonnet","enabled":true},{"exposed":"o3-mini","upstream":"o3-mini","enabled":true}]', 'Model catalog exposed to downstream clients')
ON CONFLICT (key) DO NOTHING;

ALTER TABLE route_policies
    ADD COLUMN IF NOT EXISTS request_format TEXT NOT NULL DEFAULT '*';

CREATE INDEX IF NOT EXISTS idx_route_policies_request_format
    ON route_policies(request_format);

CREATE TABLE IF NOT EXISTS secure_settings (
    key TEXT PRIMARY KEY,
    encrypted_value BYTEA NOT NULL,
    key_version TEXT NOT NULL,
    description TEXT,
    updated_by TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE route_policies
    ADD COLUMN IF NOT EXISTS client_profile_id UUID REFERENCES client_profiles(id);

DROP TABLE IF EXISTS routing_affinities;
DROP TABLE IF EXISTS budget_snapshots;

ALTER TABLE backend_pools
    DROP COLUMN IF EXISTS default_model;

ALTER TABLE usage_ledger
    DROP COLUMN IF EXISTS prefix_hash;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'route_policies'
          AND column_name = 'client_profile_id'
    ) AND NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'route_policies_client_profile_id_fkey'
    ) THEN
        ALTER TABLE route_policies
            ADD CONSTRAINT route_policies_client_profile_id_fkey
            FOREIGN KEY (client_profile_id) REFERENCES client_profiles(id) ON DELETE CASCADE;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_route_policies_client_profile
    ON route_policies(client_profile_id);

CREATE INDEX IF NOT EXISTS idx_route_policies_match
    ON route_policies(client_profile_id, request_format, model_pattern, priority)
    WHERE enabled = TRUE;

CREATE INDEX IF NOT EXISTS idx_usage_ledger_client
    ON usage_ledger(client_profile_id, created_at);

ALTER TABLE route_policies
    ADD COLUMN IF NOT EXISTS load_balance_strategy TEXT NOT NULL DEFAULT 'risk_weighted';

ALTER TABLE route_policies
    DROP CONSTRAINT IF EXISTS route_policies_load_balance_strategy_check;

ALTER TABLE route_policies
    ADD CONSTRAINT route_policies_load_balance_strategy_check
    CHECK (load_balance_strategy IN ('risk_weighted', 'round_robin', 'least_concurrency'));

ALTER TABLE usage_ledger
  ADD COLUMN IF NOT EXISTS reasoning_tokens INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS nano_aiu BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS estimated_ai_credits NUMERIC(20,9) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS token_details JSONB NOT NULL DEFAULT '[]'::jsonb;

CREATE INDEX IF NOT EXISTS idx_usage_ledger_model_created ON usage_ledger(model, created_at);
CREATE INDEX IF NOT EXISTS idx_usage_ledger_pool_created ON usage_ledger(pool_id, created_at);

CREATE TABLE IF NOT EXISTS usage_rollup_state (
    name TEXT PRIMARY KEY,
    last_processed_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS usage_rollup_hourly (
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
);

CREATE INDEX IF NOT EXISTS idx_usage_rollup_hourly_bucket ON usage_rollup_hourly(bucket_start);
CREATE INDEX IF NOT EXISTS idx_usage_rollup_hourly_client_bucket ON usage_rollup_hourly(client_profile_id, bucket_start);
CREATE INDEX IF NOT EXISTS idx_usage_rollup_hourly_model_bucket ON usage_rollup_hourly(model, bucket_start);

CREATE TABLE IF NOT EXISTS usage_rollup_daily (
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
);

CREATE INDEX IF NOT EXISTS idx_usage_rollup_daily_date ON usage_rollup_daily(bucket_date);
CREATE INDEX IF NOT EXISTS idx_usage_rollup_daily_client_date ON usage_rollup_daily(client_profile_id, bucket_date);
CREATE INDEX IF NOT EXISTS idx_usage_rollup_daily_model_date ON usage_rollup_daily(model, bucket_date);

INSERT INTO usage_rollup_state (name, last_processed_at, updated_at)
SELECT 'usage_rollup', COALESCE(MIN(created_at), now()), now()
FROM usage_ledger
ON CONFLICT (name) DO NOTHING;

ALTER TABLE backend_pools
  ADD COLUMN IF NOT EXISTS allocation_mode TEXT NOT NULL DEFAULT 'shared',
  ADD COLUMN IF NOT EXISTS binding_max_concurrency INT NOT NULL DEFAULT 10,
  ADD COLUMN IF NOT EXISTS binding_ttl_seconds INT;

ALTER TABLE backend_pools
  DROP CONSTRAINT IF EXISTS backend_pools_allocation_mode_check;

ALTER TABLE backend_pools
  ADD CONSTRAINT backend_pools_allocation_mode_check
  CHECK (allocation_mode IN ('shared', 'user_binding', 'session_binding'));

CREATE TABLE IF NOT EXISTS account_user_bindings (
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

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'account_user_bindings' AND column_name = 'owner_key_hash')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'account_user_bindings' AND column_name = 'user_id_hash') THEN
      ALTER TABLE account_user_bindings RENAME COLUMN owner_key_hash TO user_id_hash;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'account_user_bindings' AND column_name = 'owner_display')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'account_user_bindings' AND column_name = 'user_id_display') THEN
      ALTER TABLE account_user_bindings RENAME COLUMN owner_display TO user_id_display;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'account_user_bindings' AND column_name = 'source_header')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'account_user_bindings' AND column_name = 'user_id_source') THEN
      ALTER TABLE account_user_bindings RENAME COLUMN source_header TO user_id_source;
    END IF;
END $$;

ALTER TABLE account_user_bindings
    ADD COLUMN IF NOT EXISTS user_id_hash TEXT,
    ADD COLUMN IF NOT EXISTS user_id_display TEXT,
    ADD COLUMN IF NOT EXISTS user_id_source TEXT;

UPDATE account_user_bindings
SET user_id_hash = COALESCE(user_id_hash, id::text),
    user_id_display = COALESCE(user_id_display, user_id_hash, id::text)
WHERE user_id_hash IS NULL OR user_id_display IS NULL;

ALTER TABLE account_user_bindings
    ALTER COLUMN user_id_hash SET NOT NULL,
    ALTER COLUMN user_id_display SET NOT NULL;

DROP INDEX IF EXISTS idx_account_user_bindings_active_owner;

CREATE UNIQUE INDEX IF NOT EXISTS idx_account_user_bindings_active_owner
    ON account_user_bindings(client_profile_id, pool_id, user_id_hash)
    WHERE status = 'active';

CREATE UNIQUE INDEX IF NOT EXISTS idx_account_user_bindings_active_account
    ON account_user_bindings(account_id)
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_account_user_bindings_pool_status
    ON account_user_bindings(pool_id, status, expires_at);

CREATE INDEX IF NOT EXISTS idx_account_user_bindings_expires
    ON account_user_bindings(status, expires_at);

CREATE TABLE IF NOT EXISTS account_session_bindings (
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

CREATE UNIQUE INDEX IF NOT EXISTS idx_account_session_bindings_active_owner
    ON account_session_bindings(client_profile_id, pool_id, session_id_hash)
    WHERE status = 'active';

CREATE UNIQUE INDEX IF NOT EXISTS idx_account_session_bindings_active_account
    ON account_session_bindings(account_id)
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_account_session_bindings_pool_status
    ON account_session_bindings(pool_id, status, expires_at);

CREATE INDEX IF NOT EXISTS idx_account_session_bindings_expires
    ON account_session_bindings(status, expires_at);