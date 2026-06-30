-- Add protocol-aware matching to route policies.
ALTER TABLE route_policies
    ADD COLUMN IF NOT EXISTS request_format TEXT NOT NULL DEFAULT '*';

CREATE INDEX IF NOT EXISTS idx_route_policies_request_format
    ON route_policies(request_format);