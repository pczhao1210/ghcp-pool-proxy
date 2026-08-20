ALTER TABLE usage_ledger
    ADD COLUMN IF NOT EXISTS request_id TEXT,
    ADD COLUMN IF NOT EXISTS attempt_id UUID,
    ADD COLUMN IF NOT EXISTS usage_source TEXT;

UPDATE usage_ledger AS usage
SET usage_source = CASE
    WHEN usage.input_tokens <> 0 OR usage.cached_input_tokens <> 0 OR usage.cache_write_tokens <> 0
        OR usage.output_tokens <> 0 OR usage.reasoning_tokens <> 0 OR usage.nano_aiu <> 0
        OR usage.estimated_ai_credits <> 0 OR usage.estimated_cost <> 0 OR usage.token_details <> '[]'::jsonb
    THEN CASE
        WHEN EXISTS (SELECT 1 FROM accounts WHERE accounts.id = usage.account_id AND accounts.provider = 'fake')
        THEN 'estimated'
        ELSE 'upstream'
    END
    ELSE 'missing'
END
WHERE usage.usage_source IS NULL;

ALTER TABLE usage_ledger
    ALTER COLUMN usage_source SET DEFAULT 'missing',
    ALTER COLUMN usage_source SET NOT NULL,
    DROP CONSTRAINT IF EXISTS usage_ledger_usage_source_check;
ALTER TABLE usage_ledger
    ADD CONSTRAINT usage_ledger_usage_source_check
    CHECK (usage_source IN ('missing', 'upstream', 'estimated'));

CREATE INDEX IF NOT EXISTS idx_usage_ledger_request_id
    ON usage_ledger(request_id)
    WHERE request_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_usage_ledger_attempt_id
    ON usage_ledger(attempt_id)
    WHERE attempt_id IS NOT NULL;

DO $legacy_usage_ledger_contract$
BEGIN
    IF to_regclass('public.usage_ledger_legacy') IS NOT NULL THEN
        IF EXISTS (SELECT 1 FROM usage_ledger_legacy) THEN
            RAISE EXCEPTION 'usage_ledger_legacy must be empty before schema 19 contract migration';
        END IF;
    END IF;
    DROP VIEW IF EXISTS usage_ledger_all;
    DROP TABLE IF EXISTS usage_ledger_legacy;
    DROP TABLE IF EXISTS usage_ledger_legacy_state;
END
$legacy_usage_ledger_contract$;

DO $sticky_profile_contract$
BEGIN
    IF EXISTS (SELECT 1 FROM client_profiles WHERE sticky_mode = 'prefix') THEN
        RAISE EXCEPTION 'client_profiles.sticky_mode=prefix must be normalized before schema 19 contract migration';
    END IF;
END
$sticky_profile_contract$;

ALTER TABLE client_profiles
    DROP COLUMN IF EXISTS default_request_format,
    DROP COLUMN IF EXISTS default_response_format,
    DROP COLUMN IF EXISTS tool_format;

ALTER TABLE client_profiles
    DROP CONSTRAINT IF EXISTS client_profiles_sticky_mode_check;
ALTER TABLE client_profiles
    ADD CONSTRAINT client_profiles_sticky_mode_check
    CHECK (sticky_mode IN ('soft', 'strict', 'none'));

ALTER TABLE client_profiles
    DROP CONSTRAINT IF EXISTS client_profiles_affinity_strategy_check;
ALTER TABLE client_profiles
    ADD CONSTRAINT client_profiles_affinity_strategy_check
    CHECK (affinity_strategy IN ('session_then_prefix', 'prefix_only'));

ALTER TABLE client_profiles
    ADD COLUMN IF NOT EXISTS model_entitlement_policy TEXT NOT NULL DEFAULT 'allow_unknown';
ALTER TABLE client_profiles
    DROP CONSTRAINT IF EXISTS client_profiles_model_entitlement_policy_check;
ALTER TABLE client_profiles
    ADD CONSTRAINT client_profiles_model_entitlement_policy_check
    CHECK (model_entitlement_policy IN ('allow_unknown', 'require_fresh'));

CREATE TABLE IF NOT EXISTS provider_attempts (
    id UUID PRIMARY KEY,
    request_id TEXT NOT NULL,
    trace_id TEXT NOT NULL,
    payload_fingerprint TEXT NOT NULL CHECK (char_length(payload_fingerprint) = 64),
    account_id UUID NOT NULL REFERENCES accounts(id),
    pool_id UUID REFERENCES backend_pools(id),
    client_profile_id UUID REFERENCES client_profiles(id),
    model TEXT NOT NULL,
    request_format TEXT NOT NULL,
    redis_epoch BIGINT NOT NULL DEFAULT 1,
    reservation_digest TEXT,
    reservation_input_tokens INT NOT NULL DEFAULT 0,
    reservation_output_tokens INT NOT NULL DEFAULT 0,
    reservation_nano_aiu BIGINT NOT NULL DEFAULT 0,
    reservation_expires_at TIMESTAMPTZ,
    state_version BIGINT NOT NULL DEFAULT 0,
    budget_finalization_status TEXT NOT NULL DEFAULT 'pending' CHECK (budget_finalization_status IN ('pending', 'finalized', 'retained')),
    result_fingerprint TEXT,
    dispatch_sequence BIGINT NOT NULL DEFAULT 0 CHECK (dispatch_sequence >= 0),
    status TEXT NOT NULL CHECK (status IN ('preparing', 'reserved', 'dispatching', 'completed', 'rejected', 'cancelling', 'abandoned', 'outcome_unknown')),
    response_status TEXT,
    error_type TEXT,
    usage_source TEXT NOT NULL DEFAULT 'missing' CHECK (usage_source IN ('missing', 'upstream', 'estimated')),
    input_tokens INT NOT NULL DEFAULT 0,
    cached_input_tokens INT NOT NULL DEFAULT 0,
    cache_write_tokens INT NOT NULL DEFAULT 0,
    output_tokens INT NOT NULL DEFAULT 0,
    reasoning_tokens INT NOT NULL DEFAULT 0,
    nano_aiu BIGINT NOT NULL DEFAULT 0,
    estimated_ai_credits NUMERIC(20,9) NOT NULL DEFAULT 0,
    estimated_cost NUMERIC(20,8) NOT NULL DEFAULT 0,
    token_details JSONB NOT NULL DEFAULT '[]'::jsonb,
    latency_ms INT,
    dispatched_at TIMESTAMPTZ,
    finalized_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE provider_attempts
    ADD COLUMN IF NOT EXISTS usage_source TEXT NOT NULL DEFAULT 'missing';
ALTER TABLE provider_attempts
    DROP CONSTRAINT IF EXISTS provider_attempts_usage_source_check;
ALTER TABLE provider_attempts
    ADD CONSTRAINT provider_attempts_usage_source_check
    CHECK (usage_source IN ('missing', 'upstream', 'estimated'));

CREATE INDEX IF NOT EXISTS idx_provider_attempts_status_created
    ON provider_attempts(status, created_at);
CREATE INDEX IF NOT EXISTS idx_provider_attempts_account_created
    ON provider_attempts(account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_provider_attempts_request
    ON provider_attempts(request_id, dispatch_sequence);
CREATE INDEX IF NOT EXISTS idx_provider_attempts_reservation_recovery
    ON provider_attempts(status, reservation_expires_at)
    WHERE status IN ('preparing', 'reserved', 'dispatching', 'cancelling');

CREATE TABLE IF NOT EXISTS account_model_capabilities (
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    upstream_model_id TEXT NOT NULL CHECK (upstream_model_id = btrim(upstream_model_id) AND upstream_model_id <> ''),
    upstream_api TEXT NOT NULL CHECK (upstream_api IN ('chat_completions', 'responses', 'anthropic_messages')),
    discovery_status TEXT NOT NULL CHECK (discovery_status IN ('unknown', 'available', 'unavailable', 'failed')),
    probe_status TEXT NOT NULL CHECK (probe_status IN ('not_run', 'passed', 'failed')),
    source TEXT NOT NULL CHECK (source IN ('copilot_models', 'provider_probe', 'copilot_models+provider_probe')),
    observed_at TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    evidence_version BIGINT NOT NULL CHECK (evidence_version > 0),
    probe_run_id UUID,
    last_error_class TEXT CHECK (last_error_class IS NULL OR last_error_class IN (
        'auth_expired',
        'permission_denied',
        'capability_mismatch',
        'rate_limited',
        'quota_exhausted',
        'invalid_request',
        'upstream_4xx',
        'upstream_5xx',
        'network_timeout',
        'network_error',
        'invalid_response',
        'unknown'
    )),
    last_status_code INT CHECK (last_status_code IS NULL OR last_status_code BETWEEN 100 AND 599),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, upstream_model_id, upstream_api),
    CHECK (expires_at > observed_at),
    CHECK ((probe_status = 'not_run') = (probe_run_id IS NULL)),
    CHECK (probe_status <> 'passed' OR discovery_status = 'available'),
    CHECK (probe_status <> 'passed' OR last_error_class IS NULL),
    CHECK (probe_status <> 'passed' OR last_status_code IS NULL OR last_status_code BETWEEN 200 AND 299),
    CHECK ((discovery_status <> 'failed' AND probe_status <> 'failed') OR last_error_class IS NOT NULL),
    CHECK (last_error_class IS NULL OR discovery_status = 'failed' OR probe_status = 'failed')
);

CREATE INDEX IF NOT EXISTS idx_account_model_capabilities_route
    ON account_model_capabilities (upstream_model_id, upstream_api, discovery_status, probe_status, expires_at);

CREATE TABLE IF NOT EXISTS account_model_capability_refresh_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL UNIQUE REFERENCES accounts(id) ON DELETE CASCADE,
    status TEXT NOT NULL CHECK (status IN ('pending', 'completed', 'rejected', 'failed')),
    requested_by TEXT NOT NULL CHECK (btrim(requested_by) <> ''),
    requested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at TIMESTAMPTZ,
    evidence_version BIGINT CHECK (evidence_version > 0),
    last_error_class TEXT CHECK (last_error_class IS NULL OR last_error_class IN ('account_not_targeted', 'sync_failed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (
        (status = 'pending' AND resolved_at IS NULL AND evidence_version IS NULL AND last_error_class IS NULL)
        OR (status = 'completed' AND resolved_at IS NOT NULL AND evidence_version IS NOT NULL AND last_error_class IS NULL)
        OR (status = 'rejected' AND resolved_at IS NOT NULL AND evidence_version IS NULL AND last_error_class IS NOT NULL AND last_error_class = 'account_not_targeted')
        OR (status = 'failed' AND resolved_at IS NOT NULL AND evidence_version IS NULL AND last_error_class IS NOT NULL AND last_error_class = 'sync_failed')
    )
);

CREATE INDEX IF NOT EXISTS idx_account_model_capability_refresh_pending
    ON account_model_capability_refresh_requests (requested_at, id)
    WHERE status = 'pending';

INSERT INTO system_settings (key, value, description, updated_by)
VALUES
    ('account_model_capability_evidence_version', '0', 'Last allocated account-model capability evidence version', 'migration-019'),
    ('account_model_capability_complete_version', '0', 'Last fully completed account-model capability evidence version', 'migration-019')
ON CONFLICT (key) DO NOTHING;

ALTER TABLE credentials
    ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 1;

ALTER TABLE github_orgs
    ADD COLUMN IF NOT EXISTS seat_generation BIGINT NOT NULL DEFAULT 0;

ALTER TABLE copilot_seats
    ADD COLUMN IF NOT EXISTS sync_generation BIGINT NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS org_sync_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES github_orgs(id),
    sync_type TEXT NOT NULL CHECK (sync_type IN ('metrics', 'seats')),
    source TEXT NOT NULL CHECK (source IN ('manual', 'scheduled')),
    idempotency_key TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'completed')),
    requested_by TEXT NOT NULL,
    requested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    claim_id UUID,
    claimed_by TEXT,
    claimed_until TIMESTAMPTZ,
    fence_token BIGINT NOT NULL DEFAULT 0,
    attempt_count INT NOT NULL DEFAULT 0,
    last_error TEXT,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_org_sync_requests_due
    ON org_sync_requests (next_attempt_at, created_at, id)
    WHERE status = 'pending';

CREATE UNIQUE INDEX IF NOT EXISTS idx_org_sync_requests_active
    ON org_sync_requests (org_id, sync_type)
    WHERE status IN ('pending', 'running');

CREATE INDEX IF NOT EXISTS idx_org_sync_requests_running_lease
    ON org_sync_requests (claimed_until, created_at, id)
    WHERE status = 'running';

CREATE TABLE IF NOT EXISTS org_sync_maintenance_leases (
    name TEXT PRIMARY KEY,
    claimed_by TEXT NOT NULL,
    claimed_until TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

WITH ranked_snapshots AS (
    SELECT id,
           row_number() OVER (
               PARTITION BY org_id, window_start, window_end, source
               ORDER BY synced_at DESC, id DESC
           ) AS recency
    FROM copilot_metrics_snapshots
)
DELETE FROM copilot_metrics_snapshots AS snapshot
USING ranked_snapshots
WHERE snapshot.id = ranked_snapshots.id
  AND ranked_snapshots.recency > 1;

CREATE UNIQUE INDEX IF NOT EXISTS idx_copilot_metrics_snapshots_org_window_source
    ON copilot_metrics_snapshots(org_id, window_start, window_end, source);

ALTER TABLE provider_attempts
    ADD COLUMN IF NOT EXISTS response_format TEXT,
    ADD COLUMN IF NOT EXISTS affinity_key_hash TEXT,
    ADD COLUMN IF NOT EXISTS sticky_hit BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS ledger_status TEXT;

UPDATE provider_attempts
SET response_format = request_format
WHERE response_format IS NULL;

UPDATE provider_attempts
SET ledger_status = CASE
    WHEN status = 'completed' AND response_status = 'incomplete' THEN 'incomplete'
    WHEN status = 'completed' THEN 'success'
    ELSE 'error'
END
WHERE ledger_status IS NULL;

ALTER TABLE provider_attempts
    ALTER COLUMN response_format SET NOT NULL,
    ALTER COLUMN ledger_status SET NOT NULL,
    DROP CONSTRAINT IF EXISTS provider_attempts_ledger_status_check;
ALTER TABLE provider_attempts
    ADD CONSTRAINT provider_attempts_ledger_status_check
    CHECK (ledger_status IN ('success', 'incomplete', 'error', 'canceled'));

CREATE TABLE IF NOT EXISTS usage_materialization_outbox (
    attempt_id UUID PRIMARY KEY REFERENCES provider_attempts(id) ON DELETE CASCADE,
    ledger_id UUID NOT NULL UNIQUE,
    request_id TEXT NOT NULL,
    trace_id TEXT NOT NULL,
    account_id UUID NOT NULL,
    pool_id UUID,
    client_profile_id UUID,
    model TEXT NOT NULL,
    request_format TEXT NOT NULL,
    response_format TEXT NOT NULL,
    affinity_key_hash TEXT,
    sticky_hit BOOLEAN NOT NULL DEFAULT FALSE,
    ledger_status TEXT NOT NULL CHECK (ledger_status IN ('success', 'incomplete', 'error', 'canceled')),
    usage_source TEXT NOT NULL CHECK (usage_source IN ('missing', 'upstream', 'estimated')),
    input_tokens INT NOT NULL DEFAULT 0,
    cached_input_tokens INT NOT NULL DEFAULT 0,
    cache_write_tokens INT NOT NULL DEFAULT 0,
    output_tokens INT NOT NULL DEFAULT 0,
    reasoning_tokens INT NOT NULL DEFAULT 0,
    nano_aiu BIGINT NOT NULL DEFAULT 0,
    estimated_ai_credits NUMERIC(20,9) NOT NULL DEFAULT 0,
    estimated_cost NUMERIC(20,8) NOT NULL DEFAULT 0,
    token_details JSONB NOT NULL DEFAULT '[]'::jsonb,
    latency_ms INT,
    error_type TEXT,
    ledger_created_at TIMESTAMPTZ NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'materialized', 'error', 'conflict')),
    claim_id UUID,
    claimed_until TIMESTAMPTZ,
    fence_token BIGINT NOT NULL DEFAULT 0 CHECK (fence_token >= 0),
    attempt_count INT NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_error_class TEXT CHECK (last_error_class IS NULL OR last_error_class IN ('database_error', 'ledger_conflict')),
    materialized_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (
        (status = 'running' AND claim_id IS NOT NULL AND claimed_until IS NOT NULL)
        OR (status <> 'running' AND claim_id IS NULL AND claimed_until IS NULL)
    ),
    CHECK (
        (status = 'materialized' AND materialized_at IS NOT NULL)
        OR (status <> 'materialized' AND materialized_at IS NULL)
    ),
    CHECK (status <> 'conflict' OR last_error_class = 'ledger_conflict')
);

CREATE INDEX IF NOT EXISTS idx_usage_materialization_outbox_due
    ON usage_materialization_outbox (next_attempt_at, created_at, attempt_id)
    WHERE status IN ('pending', 'error');
CREATE INDEX IF NOT EXISTS idx_usage_materialization_outbox_running_lease
    ON usage_materialization_outbox (claimed_until, created_at, attempt_id)
    WHERE status = 'running';
CREATE INDEX IF NOT EXISTS idx_usage_materialization_outbox_status_created
    ON usage_materialization_outbox (status, created_at, attempt_id);

INSERT INTO usage_materialization_outbox (
    attempt_id, ledger_id, request_id, trace_id, account_id, pool_id, client_profile_id,
    model, request_format, response_format, affinity_key_hash, sticky_hit, ledger_status,
    usage_source, input_tokens, cached_input_tokens, cache_write_tokens, output_tokens,
    reasoning_tokens, nano_aiu, estimated_ai_credits, estimated_cost, token_details,
    latency_ms, error_type, ledger_created_at, status, next_attempt_at, last_error_class,
    materialized_at
)
SELECT
    attempt.id,
    CASE WHEN ledger.ledger_count = 1 THEN ledger.ledger_id ELSE gen_random_uuid() END,
    attempt.request_id,
    attempt.trace_id,
    attempt.account_id,
    attempt.pool_id,
    attempt.client_profile_id,
    attempt.model,
    attempt.request_format,
    attempt.response_format,
    attempt.affinity_key_hash,
    attempt.sticky_hit,
    attempt.ledger_status,
    attempt.usage_source,
    attempt.input_tokens,
    attempt.cached_input_tokens,
    attempt.cache_write_tokens,
    attempt.output_tokens,
    attempt.reasoning_tokens,
    attempt.nano_aiu,
    attempt.estimated_ai_credits,
    attempt.estimated_cost,
    attempt.token_details,
    attempt.latency_ms,
    attempt.error_type,
    COALESCE(attempt.finalized_at, attempt.updated_at, attempt.created_at),
    CASE
        WHEN ledger.ledger_count = 0 THEN 'pending'
        WHEN ledger.ledger_count = 1 THEN 'materialized'
        ELSE 'conflict'
    END,
    now(),
    CASE WHEN ledger.ledger_count > 1 THEN 'ledger_conflict' END,
    CASE WHEN ledger.ledger_count = 1 THEN now() END
FROM provider_attempts AS attempt
LEFT JOIN LATERAL (
    SELECT COUNT(*)::int AS ledger_count, MIN(id::text)::uuid AS ledger_id
    FROM usage_ledger
    WHERE attempt_id = attempt.id
) AS ledger ON TRUE
WHERE attempt.status IN ('completed', 'outcome_unknown')
ON CONFLICT (attempt_id) DO NOTHING;