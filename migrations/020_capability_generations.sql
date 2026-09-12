CREATE TABLE account_model_capability_staging (
    LIKE account_model_capabilities INCLUDING DEFAULTS INCLUDING CONSTRAINTS,
    credential_id UUID,
    credential_version BIGINT NOT NULL,
    PRIMARY KEY (account_id, upstream_model_id, upstream_api),
    FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE,
    CHECK (
        (credential_id IS NULL AND credential_version = 0)
        OR (credential_id IS NOT NULL AND credential_version > 0)
    )
);
