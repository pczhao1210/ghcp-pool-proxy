INSERT INTO system_settings (key, value, description, updated_by)
VALUES
    ('copilot_compat_anthropic_beta_enabled', 'true', 'Allow verified Anthropic beta feature tokens for Copilot Messages requests', 'migration-015'),
    ('copilot_compat_thinking_tool_choice_enabled', 'true', 'Normalize incompatible Anthropic thinking and forced tool choice combinations', 'migration-015'),
    ('copilot_compat_cache_control_enabled', 'true', 'Remove unsupported Anthropic cache control subfields while preserving cache breakpoints', 'migration-015'),
    ('copilot_compat_vision_header_enabled', 'true', 'Send the Copilot vision request header when a request contains images', 'migration-015')
ON CONFLICT (key) DO NOTHING;