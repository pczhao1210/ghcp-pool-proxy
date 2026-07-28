ALTER TABLE backend_pools
    ADD COLUMN IF NOT EXISTS load_balance_strategy TEXT NOT NULL DEFAULT 'risk_weighted';

ALTER TABLE backend_pools
    DROP CONSTRAINT IF EXISTS backend_pools_load_balance_strategy_check;

ALTER TABLE backend_pools
    ADD CONSTRAINT backend_pools_load_balance_strategy_check
    CHECK (load_balance_strategy IN ('risk_weighted', 'round_robin', 'least_concurrency'));

DO $migration$
BEGIN
    IF to_regclass('public.route_policies') IS NOT NULL THEN
        EXECUTE $sql$
            UPDATE backend_pools AS pool
            SET load_balance_strategy = COALESCE((
                SELECT policy.load_balance_strategy
                FROM route_policies AS policy
                WHERE policy.pool_id = pool.id
                  AND policy.enabled = TRUE
                ORDER BY policy.priority ASC, policy.name ASC, policy.id ASC
                LIMIT 1
            ), 'risk_weighted')
        $sql$;
    END IF;
END
$migration$;

ALTER TABLE client_profiles
    ADD COLUMN IF NOT EXISTS pool_id UUID;

INSERT INTO backend_pools (
    id, name, status, allocation_mode, load_balance_strategy,
    binding_max_concurrency, binding_ttl_seconds, created_at, updated_at
)
SELECT gen_random_uuid(), 'migrated-default-pool', 'active', 'shared', 'risk_weighted', 10, NULL, now(), now()
WHERE EXISTS (SELECT 1 FROM client_profiles WHERE pool_id IS NULL)
  AND NOT EXISTS (SELECT 1 FROM backend_pools WHERE status = 'active');

DO $migration$
BEGIN
        IF to_regclass('public.route_policies') IS NOT NULL THEN
                EXECUTE $sql$
                        UPDATE client_profiles AS profile
                        SET pool_id = (
                                SELECT policy.pool_id
                                FROM route_policies AS policy
                                JOIN backend_pools AS pool ON pool.id = policy.pool_id
                                WHERE policy.client_profile_id = profile.id
                                    AND policy.enabled = TRUE
                                    AND pool.status = 'active'
                                ORDER BY policy.priority ASC, policy.name ASC, policy.id ASC
                                LIMIT 1
                        )
                        WHERE profile.pool_id IS NULL
                            AND EXISTS (
                                    SELECT 1
                                    FROM route_policies AS policy
                                    JOIN backend_pools AS pool ON pool.id = policy.pool_id
                                    WHERE policy.client_profile_id = profile.id
                                        AND policy.enabled = TRUE
                                        AND pool.status = 'active'
                            )
                $sql$;
        END IF;
END
$migration$;

UPDATE client_profiles AS profile
SET pool_id = (
    SELECT pool.id
    FROM backend_pools AS pool
    WHERE pool.status = 'active'
    ORDER BY pool.allocation_mode ASC, pool.name ASC, pool.id ASC
    LIMIT 1
)
WHERE profile.pool_id IS NULL;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM client_profiles WHERE pool_id IS NULL) THEN
        RAISE EXCEPTION 'cannot assign every client profile to an active pool';
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'client_profiles'::regclass
          AND conname = 'client_profiles_pool_id_fkey'
    ) THEN
        ALTER TABLE client_profiles
            ADD CONSTRAINT client_profiles_pool_id_fkey
            FOREIGN KEY (pool_id) REFERENCES backend_pools(id) ON DELETE RESTRICT;
    END IF;
END $$;

ALTER TABLE client_profiles
    ALTER COLUMN pool_id SET NOT NULL;

WITH ranked_memberships AS (
    SELECT pa.pool_id,
           pa.account_id,
           row_number() OVER (
               PARTITION BY pa.account_id
               ORDER BY (
                   EXISTS (
                       SELECT 1
                       FROM account_user_bindings AS binding
                       WHERE binding.pool_id = pa.pool_id
                         AND binding.account_id = pa.account_id
                         AND binding.status = 'active'
                         AND binding.expires_at > now()
                   ) OR EXISTS (
                       SELECT 1
                       FROM account_session_bindings AS binding
                       WHERE binding.pool_id = pa.pool_id
                         AND binding.account_id = pa.account_id
                         AND binding.status = 'active'
                         AND binding.expires_at > now()
                   )
               ) DESC,
               pa.created_at ASC,
               pa.pool_id ASC
           ) AS membership_rank
    FROM pool_accounts AS pa
)
DELETE FROM pool_accounts AS membership
USING ranked_memberships AS ranked
WHERE membership.pool_id = ranked.pool_id
  AND membership.account_id = ranked.account_id
  AND ranked.membership_rank > 1;

CREATE UNIQUE INDEX IF NOT EXISTS idx_pool_accounts_account_unique
    ON pool_accounts(account_id);

ALTER TABLE backend_pools
    DROP COLUMN IF EXISTS priority;

DROP TABLE IF EXISTS route_policies;
