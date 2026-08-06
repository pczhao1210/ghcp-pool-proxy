ALTER TABLE accounts
    ALTER COLUMN max_concurrency SET DEFAULT 6;

ALTER TABLE backend_pools
    ALTER COLUMN binding_max_concurrency SET DEFAULT 10;