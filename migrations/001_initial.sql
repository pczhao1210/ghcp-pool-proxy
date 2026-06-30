-- 001_initial.sql
-- GHCP Pool Proxy initial schema

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- GitHub Organizations
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

-- GitHub Teams
CREATE TABLE github_teams (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES github_orgs(id),
    github_team_id TEXT,
    slug TEXT NOT NULL,
    name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Accounts
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
    max_concurrency INT NOT NULL DEFAULT 1,
    current_failure_count INT NOT NULL DEFAULT 0,
    last_success_at TIMESTAMPTZ,
    last_failure_at TIMESTAMPTZ,
    last_failure_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_accounts_status ON accounts(status);
CREATE INDEX idx_accounts_source ON accounts(account_source);

-- Copilot Seats
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

-- Credentials
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

-- Backend Pools
CREATE TABLE backend_pools (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    priority INT NOT NULL DEFAULT 100,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Pool-Account association
CREATE TABLE pool_accounts (
    pool_id UUID NOT NULL REFERENCES backend_pools(id),
    account_id UUID NOT NULL REFERENCES accounts(id),
    weight INT NOT NULL DEFAULT 100,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (pool_id, account_id)
);

-- Client Profiles
CREATE TABLE client_profiles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    api_key_hash TEXT NOT NULL UNIQUE,
    default_request_format TEXT NOT NULL,
    default_response_format TEXT NOT NULL,
    default_model TEXT,
    model_aliases JSONB NOT NULL DEFAULT '{}',
    tool_format TEXT,
    sticky_mode TEXT NOT NULL DEFAULT 'soft',
    sticky_ttl_seconds INT NOT NULL DEFAULT 1800,
    sticky_session_header TEXT,
    cache_affinity_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    max_sticky_load_ratio NUMERIC(5,2) NOT NULL DEFAULT 0.85,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Route Policies
CREATE TABLE route_policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    request_format TEXT NOT NULL DEFAULT '*',
    client_profile_id UUID REFERENCES client_profiles(id) ON DELETE CASCADE,
    model_pattern TEXT NOT NULL,
    pool_id UUID NOT NULL REFERENCES backend_pools(id),
    priority INT NOT NULL DEFAULT 100,
    load_balance_strategy TEXT NOT NULL DEFAULT 'risk_weighted' CHECK (load_balance_strategy IN ('risk_weighted', 'round_robin', 'least_concurrency')),
    sticky_mode TEXT,
    affinity_scope TEXT,
    sticky_ttl_seconds INT,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_route_policies_client_profile ON route_policies(client_profile_id);
CREATE INDEX idx_route_policies_match ON route_policies(client_profile_id, request_format, model_pattern, priority) WHERE enabled = TRUE;

-- Usage Ledger
CREATE TABLE usage_ledger (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
    estimated_cost NUMERIC(20,8) NOT NULL DEFAULT 0,
    latency_ms INT,
    error_type TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_usage_ledger_account ON usage_ledger(account_id, created_at);
CREATE INDEX idx_usage_ledger_client ON usage_ledger(client_profile_id, created_at);
CREATE INDEX idx_usage_ledger_trace ON usage_ledger(trace_id);

-- Copilot Metrics Snapshots
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

-- Audit Events
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

-- Recovery Tasks
CREATE TABLE recovery_tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES accounts(id),
    status TEXT NOT NULL,
    reason TEXT NOT NULL,
    assigned_to TEXT,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ
);

CREATE INDEX idx_recovery_tasks_account ON recovery_tasks(account_id);
CREATE INDEX idx_recovery_tasks_status ON recovery_tasks(status);
