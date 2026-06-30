-- 008_usage_ai_credits.sql
-- Persist Copilot token usage details and AI credit estimates.

ALTER TABLE usage_ledger
  ADD COLUMN IF NOT EXISTS reasoning_tokens INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS nano_aiu BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS estimated_ai_credits NUMERIC(20,9) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS token_details JSONB NOT NULL DEFAULT '[]'::jsonb;

CREATE INDEX IF NOT EXISTS idx_usage_ledger_model_created ON usage_ledger(model, created_at);
CREATE INDEX IF NOT EXISTS idx_usage_ledger_pool_created ON usage_ledger(pool_id, created_at);