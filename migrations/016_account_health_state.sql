ALTER TABLE accounts
    ADD COLUMN IF NOT EXISTS next_token_probe_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS token_probe_claim_id UUID,
    ADD COLUMN IF NOT EXISTS token_probe_claimed_by TEXT,
    ADD COLUMN IF NOT EXISTS token_probe_claimed_until TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_token_probe_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_token_probe_success_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_token_probe_failure_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_token_probe_failure_reason TEXT,
    ADD COLUMN IF NOT EXISTS next_re_admission_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS re_admission_claim_id UUID,
    ADD COLUMN IF NOT EXISTS re_admission_claimed_by TEXT,
    ADD COLUMN IF NOT EXISTS re_admission_claimed_until TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_re_admission_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_re_admission_success_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_re_admission_failure_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_re_admission_failure_reason TEXT,
    ADD COLUMN IF NOT EXISTS re_admission_attempt_count INT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS health_version BIGINT NOT NULL DEFAULT 0;

UPDATE accounts
SET next_token_probe_at = now() + CASE
        WHEN status = 'degraded' THEN (get_byte(decode(md5(id::text), 'hex'), 0) % 30) * interval '1 second'
        ELSE (get_byte(decode(md5(id::text), 'hex'), 0) % 1800) * interval '1 second'
    END
WHERE status IN ('active', 'degraded');

UPDATE accounts
SET next_re_admission_at = now() + (get_byte(decode(md5(id::text), 'hex'), 1) % 60) * interval '1 second'
WHERE status = 'degraded' AND risk_score <= 60;

CREATE INDEX IF NOT EXISTS idx_accounts_due_token_probe
    ON accounts (next_token_probe_at, id)
    WHERE status IN ('active', 'degraded');

CREATE INDEX IF NOT EXISTS idx_accounts_due_re_admission
    ON accounts (next_re_admission_at, id)
    WHERE status = 'degraded';

ALTER TABLE recovery_tasks
    ADD COLUMN IF NOT EXISTS claim_id UUID,
    ADD COLUMN IF NOT EXISTS claimed_by TEXT,
    ADD COLUMN IF NOT EXISTS claimed_until TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS attempt_count INT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS next_attempt_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS source_status TEXT,
    ADD COLUMN IF NOT EXISTS current_step TEXT,
    ADD COLUMN IF NOT EXISTS failure_reason TEXT;

UPDATE recovery_tasks
SET status = 'pending',
    claimed_until = NULL,
    next_attempt_at = now(),
    current_step = 'waiting_to_retry',
    updated_at = now()
WHERE status = 'running' AND claim_id IS NULL;

WITH ranked AS (
    SELECT id,
           row_number() OVER (PARTITION BY account_id ORDER BY created_at, id) AS position
    FROM recovery_tasks
    WHERE status IN ('pending', 'running')
)
UPDATE recovery_tasks AS task
SET status = 'failed',
    current_step = 'failed',
    failure_reason = 'superseded_duplicate',
    notes = 'superseded duplicate recovery task during schema migration',
    completed_at = now(),
    updated_at = now()
FROM ranked
WHERE task.id = ranked.id AND ranked.position > 1;

CREATE UNIQUE INDEX IF NOT EXISTS idx_recovery_tasks_account_nonterminal
    ON recovery_tasks (account_id)
    WHERE status IN ('pending', 'running');

CREATE INDEX IF NOT EXISTS idx_recovery_tasks_due
    ON recovery_tasks (next_attempt_at, created_at, id)
    WHERE status IN ('pending', 'running');
