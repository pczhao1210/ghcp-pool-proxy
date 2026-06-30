-- Add per-route policy account selection strategy.

ALTER TABLE route_policies
    ADD COLUMN IF NOT EXISTS load_balance_strategy TEXT NOT NULL DEFAULT 'risk_weighted';

ALTER TABLE route_policies
    DROP CONSTRAINT IF EXISTS route_policies_load_balance_strategy_check;

ALTER TABLE route_policies
    ADD CONSTRAINT route_policies_load_balance_strategy_check
    CHECK (load_balance_strategy IN ('risk_weighted', 'round_robin', 'least_concurrency'));