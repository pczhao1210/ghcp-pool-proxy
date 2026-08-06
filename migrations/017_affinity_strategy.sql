ALTER TABLE client_profiles
    ADD COLUMN IF NOT EXISTS affinity_strategy TEXT NOT NULL DEFAULT 'session_then_prefix';

UPDATE client_profiles
SET sticky_mode = 'soft',
    affinity_strategy = 'prefix_only',
    updated_at = now()
WHERE sticky_mode = 'prefix';