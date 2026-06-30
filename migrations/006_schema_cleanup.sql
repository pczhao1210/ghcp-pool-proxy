-- Remove schema leftovers that are not used by the current MVP runtime.

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