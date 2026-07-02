-- Add pool-level user binding allocation mode and persistent user/account bindings.

ALTER TABLE backend_pools
    ADD COLUMN IF NOT EXISTS allocation_mode TEXT NOT NULL DEFAULT 'shared';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'backend_pools_allocation_mode_check'
    ) THEN
        ALTER TABLE backend_pools
            ADD CONSTRAINT backend_pools_allocation_mode_check
            CHECK (allocation_mode IN ('shared', 'user_binding'));
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS account_user_bindings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_profile_id UUID NOT NULL REFERENCES client_profiles(id) ON DELETE CASCADE,
    pool_id UUID NOT NULL REFERENCES backend_pools(id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    owner_key_hash TEXT NOT NULL,
    owner_display TEXT NOT NULL,
    source_header TEXT,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'released', 'expired')),
    last_used_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    released_at TIMESTAMPTZ,
    release_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_account_user_bindings_active_owner
    ON account_user_bindings(client_profile_id, pool_id, owner_key_hash)
    WHERE status = 'active';

CREATE UNIQUE INDEX IF NOT EXISTS idx_account_user_bindings_active_account
    ON account_user_bindings(account_id)
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_account_user_bindings_pool_status
    ON account_user_bindings(pool_id, status, expires_at);

CREATE INDEX IF NOT EXISTS idx_account_user_bindings_expires
    ON account_user_bindings(status, expires_at);