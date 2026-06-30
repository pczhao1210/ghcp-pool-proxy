-- Allow route policies to be scoped to a specific client profile.
ALTER TABLE route_policies
    ADD COLUMN IF NOT EXISTS client_profile_id UUID REFERENCES client_profiles(id);

CREATE INDEX IF NOT EXISTS idx_route_policies_client_profile
    ON route_policies(client_profile_id);