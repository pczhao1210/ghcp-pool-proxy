-- Existing bindings have already been admitted; new bindings explicitly start unadmitted.
ALTER TABLE account_user_bindings ADD COLUMN admitted_at timestamptz DEFAULT now();
ALTER TABLE account_session_bindings ADD COLUMN admitted_at timestamptz DEFAULT now();

-- A dispatch can be long-lived without being abandoned.
ALTER TABLE provider_attempts ADD COLUMN dispatch_lease_expires_at timestamptz;

-- Schema 19 upgrades added NOT NULL without the default present in fresh schemas.
ALTER TABLE provider_attempts ALTER COLUMN ledger_status SET DEFAULT 'error';
