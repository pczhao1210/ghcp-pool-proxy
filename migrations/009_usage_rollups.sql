-- 009_usage_rollups.sql
-- Time-bucketed usage rollups for high-volume metrics queries.

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