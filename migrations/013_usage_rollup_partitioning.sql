DO $prepare$
DECLARE
    hourly_kind "char";
    daily_kind "char";
BEGIN
    SELECT relkind INTO hourly_kind
    FROM pg_class
    WHERE oid = to_regclass('public.usage_rollup_hourly');

    IF hourly_kind IS NULL THEN
        RAISE EXCEPTION 'usage_rollup_hourly table is missing';
    END IF;
    IF hourly_kind <> 'p' THEN
        IF to_regclass('public.usage_rollup_hourly_legacy') IS NOT NULL THEN
            RAISE EXCEPTION 'usage_rollup_hourly_legacy already exists';
        END IF;
        ALTER TABLE usage_rollup_hourly RENAME TO usage_rollup_hourly_legacy;
        ALTER TABLE usage_rollup_hourly_legacy DROP CONSTRAINT IF EXISTS usage_rollup_hourly_pkey;
        DROP INDEX IF EXISTS idx_usage_rollup_hourly_bucket;
        DROP INDEX IF EXISTS idx_usage_rollup_hourly_client_bucket;
        DROP INDEX IF EXISTS idx_usage_rollup_hourly_model_bucket;

        CREATE TABLE usage_rollup_hourly (
            LIKE usage_rollup_hourly_legacy
            INCLUDING DEFAULTS
            INCLUDING CONSTRAINTS
            INCLUDING STORAGE
        ) PARTITION BY RANGE (bucket_start);
        ALTER TABLE usage_rollup_hourly
            ADD PRIMARY KEY (bucket_start, client_profile_id, account_id, pool_id, model, request_format, status);
    END IF;

    SELECT relkind INTO daily_kind
    FROM pg_class
    WHERE oid = to_regclass('public.usage_rollup_daily');

    IF daily_kind IS NULL THEN
        RAISE EXCEPTION 'usage_rollup_daily table is missing';
    END IF;
    IF daily_kind <> 'p' THEN
        IF to_regclass('public.usage_rollup_daily_legacy') IS NOT NULL THEN
            RAISE EXCEPTION 'usage_rollup_daily_legacy already exists';
        END IF;
        ALTER TABLE usage_rollup_daily RENAME TO usage_rollup_daily_legacy;
        ALTER TABLE usage_rollup_daily_legacy DROP CONSTRAINT IF EXISTS usage_rollup_daily_pkey;
        DROP INDEX IF EXISTS idx_usage_rollup_daily_date;
        DROP INDEX IF EXISTS idx_usage_rollup_daily_client_date;
        DROP INDEX IF EXISTS idx_usage_rollup_daily_model_date;

        CREATE TABLE usage_rollup_daily (
            LIKE usage_rollup_daily_legacy
            INCLUDING DEFAULTS
            INCLUDING CONSTRAINTS
            INCLUDING STORAGE
        ) PARTITION BY RANGE (bucket_date);
        ALTER TABLE usage_rollup_daily
            ADD PRIMARY KEY (bucket_date, client_profile_id, account_id, pool_id, model, request_format, status);
    END IF;
END
$prepare$;

CREATE INDEX IF NOT EXISTS idx_usage_rollup_hourly_bucket
    ON usage_rollup_hourly(bucket_start);
CREATE INDEX IF NOT EXISTS idx_usage_rollup_hourly_client_bucket
    ON usage_rollup_hourly(client_profile_id, bucket_start);
CREATE INDEX IF NOT EXISTS idx_usage_rollup_hourly_model_bucket
    ON usage_rollup_hourly(model, bucket_start);

CREATE INDEX IF NOT EXISTS idx_usage_rollup_daily_date
    ON usage_rollup_daily(bucket_date);
CREATE INDEX IF NOT EXISTS idx_usage_rollup_daily_client_date
    ON usage_rollup_daily(client_profile_id, bucket_date);
CREATE INDEX IF NOT EXISTS idx_usage_rollup_daily_model_date
    ON usage_rollup_daily(model, bucket_date);

DO $hourly_data$
DECLARE
    partition_day DATE;
    partition_name TEXT;
BEGIN
    IF to_regclass('public.usage_rollup_hourly_legacy') IS NOT NULL THEN
        FOR partition_day IN
            SELECT DISTINCT (bucket_start AT TIME ZONE 'UTC')::date
            FROM usage_rollup_hourly_legacy
            ORDER BY 1
        LOOP
            partition_name := 'usage_rollup_hourly_p' || to_char(partition_day, 'YYYYMMDD');
            EXECUTE format(
                'CREATE TABLE IF NOT EXISTS %I PARTITION OF usage_rollup_hourly FOR VALUES FROM (%L) TO (%L)',
                partition_name,
                partition_day::text || ' 00:00:00+00',
                (partition_day + 1)::text || ' 00:00:00+00'
            );
        END LOOP;
    END IF;

    CREATE TABLE IF NOT EXISTS usage_rollup_hourly_default
        PARTITION OF usage_rollup_hourly DEFAULT;

    IF to_regclass('public.usage_rollup_hourly_legacy') IS NOT NULL THEN
        INSERT INTO usage_rollup_hourly SELECT * FROM usage_rollup_hourly_legacy;
        DROP TABLE usage_rollup_hourly_legacy;
    END IF;
END
$hourly_data$;

DO $daily_data$
DECLARE
    partition_month DATE;
    partition_name TEXT;
BEGIN
    IF to_regclass('public.usage_rollup_daily_legacy') IS NOT NULL THEN
        FOR partition_month IN
            SELECT DISTINCT date_trunc('month', bucket_date)::date
            FROM usage_rollup_daily_legacy
            ORDER BY 1
        LOOP
            partition_name := 'usage_rollup_daily_p' || to_char(partition_month, 'YYYYMM');
            EXECUTE format(
                'CREATE TABLE IF NOT EXISTS %I PARTITION OF usage_rollup_daily FOR VALUES FROM (%L) TO (%L)',
                partition_name,
                partition_month,
                partition_month + interval '1 month'
            );
        END LOOP;
    END IF;

    CREATE TABLE IF NOT EXISTS usage_rollup_daily_default
        PARTITION OF usage_rollup_daily DEFAULT;

    IF to_regclass('public.usage_rollup_daily_legacy') IS NOT NULL THEN
        INSERT INTO usage_rollup_daily SELECT * FROM usage_rollup_daily_legacy;
        DROP TABLE usage_rollup_daily_legacy;
    END IF;
END
$daily_data$;