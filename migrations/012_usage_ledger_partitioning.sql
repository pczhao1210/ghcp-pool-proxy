DO $migration$
DECLARE
    ledger_kind "char";
BEGIN
    SELECT relkind INTO ledger_kind
    FROM pg_class
    WHERE oid = to_regclass('public.usage_ledger');

    IF ledger_kind IS NULL THEN
        RAISE EXCEPTION 'usage_ledger table is missing';
    END IF;

    IF ledger_kind <> 'p' THEN
        ALTER TABLE usage_ledger ADD COLUMN IF NOT EXISTS ingested_at TIMESTAMPTZ;
        ALTER TABLE usage_ledger RENAME TO usage_ledger_legacy;
        ALTER TABLE usage_ledger_legacy DROP CONSTRAINT IF EXISTS usage_ledger_pkey;
        DROP INDEX IF EXISTS idx_usage_ledger_account;
        DROP INDEX IF EXISTS idx_usage_ledger_client;
        DROP INDEX IF EXISTS idx_usage_ledger_trace;
        DROP INDEX IF EXISTS idx_usage_ledger_model_created;
        DROP INDEX IF EXISTS idx_usage_ledger_pool_created;
        CREATE INDEX IF NOT EXISTS usage_ledger_legacy_created_brin
            ON usage_ledger_legacy USING BRIN(created_at);

        CREATE TABLE usage_ledger (
            LIKE usage_ledger_legacy
            INCLUDING DEFAULTS
            INCLUDING CONSTRAINTS
            INCLUDING STORAGE
        ) PARTITION BY RANGE (created_at);
        CREATE INDEX idx_usage_ledger_created_brin
            ON usage_ledger USING BRIN(created_at);
        ALTER TABLE usage_ledger ALTER COLUMN ingested_at SET DEFAULT now();
        ALTER TABLE usage_ledger ALTER COLUMN ingested_at SET NOT NULL;
    ELSE
        ALTER TABLE usage_ledger ADD COLUMN IF NOT EXISTS ingested_at TIMESTAMPTZ;
        ALTER TABLE usage_ledger ALTER COLUMN ingested_at SET DEFAULT now();
    END IF;
END
$migration$;

DO $legacy_ingested_at$
BEGIN
    IF to_regclass('public.usage_ledger_legacy') IS NOT NULL THEN
        ALTER TABLE usage_ledger_legacy ADD COLUMN IF NOT EXISTS ingested_at TIMESTAMPTZ;
    END IF;
END
$legacy_ingested_at$;

CREATE INDEX IF NOT EXISTS idx_usage_ledger_created_brin
    ON usage_ledger USING BRIN(created_at);
CREATE INDEX IF NOT EXISTS idx_usage_ledger_ingested_brin
    ON usage_ledger USING BRIN(ingested_at);

CREATE TABLE IF NOT EXISTS usage_ledger_legacy_state (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    max_created_at TIMESTAMPTZ,
    truncated_at TIMESTAMPTZ
);

DO $legacy_state$
BEGIN
    IF to_regclass('public.usage_ledger_legacy') IS NOT NULL THEN
        INSERT INTO usage_ledger_legacy_state (singleton, max_created_at)
        SELECT TRUE, MAX(created_at) FROM usage_ledger_legacy
        ON CONFLICT (singleton) DO NOTHING;
    END IF;
END
$legacy_state$;

DO $partitions$
DECLARE
    partition_day DATE;
    partition_name TEXT;
BEGIN
    FOR partition_day IN
        SELECT generate_series(
            (current_timestamp AT TIME ZONE 'UTC')::date,
            (current_timestamp AT TIME ZONE 'UTC')::date + 7,
            interval '1 day'
        )::date
    LOOP
        partition_name := 'usage_ledger_p' || to_char(partition_day, 'YYYYMMDD');
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF usage_ledger FOR VALUES FROM (%L) TO (%L)',
            partition_name,
            partition_day::text || ' 00:00:00+00',
            (partition_day + 1)::text || ' 00:00:00+00'
        );
    END LOOP;
END
$partitions$;

CREATE TABLE IF NOT EXISTS usage_ledger_default PARTITION OF usage_ledger DEFAULT;

DO $view$
BEGIN
    IF to_regclass('public.usage_ledger_legacy') IS NULL THEN
        EXECUTE 'CREATE OR REPLACE VIEW usage_ledger_all AS SELECT * FROM usage_ledger';
    ELSE
        EXECUTE 'CREATE OR REPLACE VIEW usage_ledger_all AS SELECT * FROM usage_ledger_legacy UNION ALL SELECT * FROM usage_ledger';
    END IF;
END
$view$;