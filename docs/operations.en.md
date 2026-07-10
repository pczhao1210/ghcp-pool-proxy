# Operations Guide

This guide supports daily operations for single-machine deployments and future clustered deployments, focusing on startup, migrations, monitoring, alerts, and troubleshooting.

## Runtime Topology

```mermaid
flowchart TD
  Operator["Operator"] -->|"http://localhost:8001/"| Dashboard["Dashboard"]
  Dashboard -->|"Bearer token"| Admin["admin :8001 /admin/*"]
  Client["Client / SDK"] -->|"http://localhost:8000/v1/*"| Gateway["gateway :8000"]
  Gateway --> PG[(PostgreSQL)]
  Gateway --> Redis[(Redis)]
  Admin --> PG
  Worker["worker"] --> PG
  Worker -->|"Copilot Metrics"| GitHub["GitHub API"]
  Gateway --> Metrics["GET /metrics"]
```

## VM Deployment

Use `deploy/deploy.sh` from the release package to deploy on a Linux VM. The script consumes fixed Docker Hub images and does not run source builds, tests, or smoke checks.

```bash
deploy/deploy.sh --start
```

Startup flow:

- Checks Linux, Docker, Docker Compose, `curl`, and related dependencies.
- Creates the default persistent root at host `~/ghcp_proxy` and bind-mounts PostgreSQL/Redis data directories into containers.
- Generates host file `~/ghcp_proxy/.env` on first run with the admin token, `PROVIDER=copilot`, database password, and `CREDENTIAL_MASTER_KEY`.
- Pulls `pczhao1210/ghcp-pool-proxy:gateway-latest`, `admin-latest`, `worker-latest`, plus PostgreSQL and Redis images.
- Starts PostgreSQL and Redis, then waits for health checks.
- Reads `migrations/schema_version` and `migrations/001_init.sql` from the release package or published admin image. Empty databases receive the single init schema; existing databases read `system_settings.schema_version` and are upgraded only when the script has an explicit smooth upgrade path.
- Starts gateway, admin, and worker.
- Starts a log collector that writes compose logs hourly to `~/ghcp_proxy/logs/ghcp-proxy-YYYYMMDD-HH.log` with 30-day retention by default.

Tail logs:

```bash
deploy/deploy.sh --logs
```

Stop services while preserving persistent data:

```bash
deploy/deploy.sh --stop
```

Reset VM PostgreSQL and Redis data while preserving `.env`:

```bash
GHCP_RESET_CONFIRM=reset deploy/deploy.sh --reset
deploy/deploy.sh --start
```

For local development, use `./start.sh --reset`; it resets Docker Compose volumes and rebuilds the database from the current `migrations/001_init.sql`.

For source-tree validation, `./start.sh --new` runs Go tests unless `--skip-tests` is set, rebuilds the app images, recreates gateway/admin/worker, and runs HTTP smoke checks. The smoke client profile uses a dedicated route policy: with `PROVIDER=fake` it targets the seeded local smoke pool; with `PROVIDER=copilot` it targets the first active shared pool when one exists. The smoke payload includes stable `user` and `session` identifiers so user-binding or session-binding routing errors are easier to diagnose if no shared pool is available.

VM Docker persistence:

- PostgreSQL data is stored under `~/ghcp_proxy/data/postgres` by default.
- Redis AOF data is stored under `~/ghcp_proxy/data/redis` by default.
- Logs are stored under `~/ghcp_proxy/logs`, split hourly, with `LOG_RETENTION_DAYS=30` by default.
- Deployment secrets and ports are stored in `~/ghcp_proxy/.env`. Do not rotate `CREDENTIAL_MASTER_KEY` casually after storing credentials.
- `~/ghcp_proxy/.env` records the current release package `SCHEMA_VERSION` for operations visibility; the installed database version is stored in `system_settings.schema_version`.
- These are host paths. PostgreSQL and Redis use them through Docker Compose bind mounts; persistent directories are not created inside the images.

## Main Configuration

| Variable / Setting | Description |
| --- | --- |
| `GATEWAY_ADDR` | Gateway listen address |
| `GATEWAY_READ_TIMEOUT` | Maximum time to read a request, default `30s` |
| `GATEWAY_READ_HEADER_TIMEOUT` | Maximum time to read request headers, default `5s` |
| `GATEWAY_WRITE_TIMEOUT` | Overall response write timeout; default `0s` keeps long SSE streams open |
| `GATEWAY_IDLE_TIMEOUT` | Keep-alive idle timeout, default `120s` |
| `ADMIN_ADDR` | Admin listen address |
| `ADMIN_TOKEN` | Admin API authentication token |
| `POSTGRES_DSN` | PostgreSQL connection string |
| `REDIS_ADDR` | Redis address |
| `SCHEMA_VERSION` | Target schema version for the current release package; written to `.env` by `deploy.sh`, while the installed DB version is stored in `system_settings.schema_version` |
| `PROVIDER` | Upstream provider type, `copilot` by default for VM deployment |
| `CREDENTIAL_MASTER_KEY` | Credential encryption master key |
| `GITHUB_OAUTH_CLIENT_ID` | Optional override for the GitHub OAuth App client ID used by dashboard Device Flow. Defaults to the built-in GitHub OAuth Client ID. |
| `GITHUB_OAUTH_SCOPES` | Device Flow scopes, default `read:user` |
| `GITHUB_LOGIN_BASE_URL` | GitHub login base URL, default `https://github.com` |
| `GITHUB_API_BASE_URL` | GitHub API base URL, default `https://api.github.com` |
| `COPILOT_TOKEN_URL` | Copilot bearer token exchange endpoint |
| `GITHUB_TOKEN` | Fallback token for worker GitHub Copilot Metrics sync |
| `DASHBOARD_DIR` | Dashboard static asset directory served by admin |
| `model_catalog_json` | Controls exposed names, upstream model IDs, upstream API, and enabled status |
| `LOG_LEVEL` / `LOG_FORMAT` | Log level and format |

## Multi-Account Environment Isolation

The current implementation isolates GitHub Copilot accounts across account records, credentials, pools, and hot state.

```mermaid
flowchart TD
  Client["Client API Key"] --> Profile["Client Profile"]
  Profile --> Policy["Route Policy"]
  Policy --> Pool["Backend Pool"]
  Pool --> AccountA["GitHub Account A"]
  Pool --> AccountB["GitHub Account B"]
  AccountA --> CredA[(Encrypted Credential A)]
  AccountB --> CredB[(Encrypted Credential B)]
  AccountA --> CacheA["Token Cache account_id=A"]
  AccountB --> CacheB["Token Cache account_id=B"]
  Pool --> Sticky["Redis Sticky Map pool/model/format/affinity"]
```

- Each account is a separate `accounts` row, credentials are bound through `credentials.account_id`, and no global Copilot token is used.
- After Device Flow, the account's own GitHub OAuth token and Copilot bearer token are stored as encrypted payload under that account only.
- Before a request, the gateway reads `account_id` from router selection, then loads and caches the token by that `account_id`.
- Pool membership is managed by `pool_accounts`; route policies control which models, protocols, or tenants route to which account pool.
- Redis sticky keys include pool, model, request format, and affinity hash; sticky only affects account reuse within the same scope.
- Organization/enterprise seat accounts should fill `account_source`, `org_id`, and `seat_status`; the router filters unavailable seats.

Recommended isolation practices:

1. Split pools by tenant, purpose, or risk tier, such as `team-a-copilot`, `team-b-copilot`, and `sandbox-copilot`.
2. Run Device Flow separately for each GitHub account and do not reuse manual tokens.
3. Bind client profiles or route policies to fixed pools to avoid sharing account pools across teams.
4. Periodically sync Business/Enterprise seat status and move invalid accounts to `quarantined` or `revoked`.
5. Use a dedicated `CREDENTIAL_MASTER_KEY` in production; do not use the compose default development key.

## Dashboard and Admin Authentication

- Dashboard static pages are served by admin at root, default `http://localhost:8001/`.
- `/admin/*` APIs require `Authorization: Bearer <ADMIN_TOKEN>`.
- The dashboard attaches the admin token to API requests; static pages themselves should not carry sensitive data.
- In container images, dashboard dist is copied to `/srv/dashboard`; `DASHBOARD_DIR` can point to a custom build.

## Release and Migration

```mermaid
flowchart TD
  A["prepare configuration"] --> B["run database migrations"]
  B --> C["deploy gateway"]
  B --> D["deploy admin"]
  B --> E["deploy worker"]
  C --> F["check /healthz and /readyz"]
  D --> G["check dashboard and admin API"]
  E --> H["check probes and sync jobs"]
```

- Run database migrations before deploying services.
- Prefer admin workflows for changing route policies, client profiles, and budget thresholds.
- In multi-instance deployments, Redis and PostgreSQL must be available before services start. If the initial Redis ping or a later command fails, readiness returns `503`; budget and distributed concurrency checks fail closed, while sticky affinity and binding caches fall back to ordinary routing or PostgreSQL. The retained Redis client resumes normal operation automatically after recovery.
- Smooth schema upgrades must keep binding-pool objects aligned with the consolidated schema: `backend_pools.allocation_mode` allows `shared`, `user_binding`, and `session_binding`; user bindings use `user_id_*` columns; session bindings use the separate `account_session_bindings` table.

## Daily Checks

| Check | Description |
| --- | --- |
| `GET /healthz` | Liveness check |
| `GET /readyz` | Readiness check |
| `GET /metrics` | Gateway metrics check |
| Dashboard | Inspect account status, pool status, error events, usage, cost, cache hit rate, and sync status |

## Gateway Error Mapping

Clients receive standard AI gateway semantics through `external_status`, `external_code`, and a neutral `external_message`. The gateway log event `gateway error mapped` preserves operational fields: `internal_status`, `internal_code`, `internal_message`, `external_status`, `external_code`, `external_message`, and, when available, context such as `model`, `account_id`, `pool_id`, and `redis_rebind_reason`.

| Internal status / code | Internal condition | External status / code | External message | Operations note |
| --- | --- | --- | --- | --- |
| `413 invalid_request_error` | JSON request body exceeds `32 MiB` | `413 invalid_request_error` | Request body limit message | Reduce embedded images, tool payloads, or conversation history before retrying |
| `503 no_available_accounts` / `503 user_binding_exhausted` / `503 session_binding_exhausted` | Empty routing candidates, exhausted internal concurrency, or no binding-pool capacity | `429 rate_limited` | `rate limit exceeded; please retry later` | Use `internal_message`, `account_id`, and `pool_id` to distinguish capacity, binding, and concurrency causes |
| `503 route_unavailable` | No usable route or model route configuration unavailable | `503 service_unavailable` | `model route unavailable` | Check route policies, pool status, and model catalog configuration |
| `400 missing_user_id` / `400 invalid_user_id` | User-binding pool lacks or receives an invalid `user_id` | `400 invalid_request_error` | `user identifier is required` / `user identifier is invalid` | Prefer OpenAI `user` or Anthropic `metadata.user_id` / `metadata.user` |
| `400 missing_session_id` / `400 invalid_session_id` | Session-binding pool lacks or receives an invalid `session_id` | `400 invalid_request_error` | `session identifier is required` / `session identifier is invalid` | Prefer `metadata.session_id` / `metadata.session`, or header `X-GHCP-Session-ID` |
| `503 user_binding_unavailable` / `503 session_binding_unavailable` | Binding dependency failure, such as PostgreSQL or cache access | `503 service_unavailable` | `service temporarily unavailable` | Check PostgreSQL, Redis, and binding table state |
| `503 budget_unavailable` | Rate-limit or budget state is unreadable | `503 service_unavailable` | `gateway limit state unavailable` | Check budget checker, Redis/PostgreSQL, and configuration sync |
| `429 global_rate_limited` / `429 account_rate_limited` | Global or internal resource-level RPM limit hit | `429 rate_limited` | `rate limit exceeded; please retry later` | Resource scope is hidden from clients; logs retain global/account granularity |
| `429 global_budget_exhausted` / `429 account_budget_exhausted` | Global or internal resource-level token / AI Credits daily budget exhausted | `429 budget_exhausted` | `quota exceeded` | Clients see standard quota exhaustion; logs retain budget scope |
| `502 upstream_error` | Upstream model provider failure | `502 upstream_error` | `model provider error` | Internal logs and usage ledger keep the original failure classification |
| `500 stream_error` | SSE writer or streaming response initialization failed | `500 stream_error` | `stream response unavailable` | Check response writing, proxying, and client connection state |
| Unmapped internal code | Other errors passed through the mapping function | Same as internal | Same as internal | Default passthrough; review new error types for neutralization needs |

Upstream Copilot 4xx responses are classified before account health is updated. Authentication, permission, rate-limit, quota, network, and 5xx failures can still affect risk. Invalid request and generic upstream 4xx classifications are recorded in metrics and usage, but they do not increase account risk because they usually come from request shape, model compatibility, or client parameters rather than account health. For streaming calls, an upstream SSE read error or premature EOF before a completion marker is treated as a failed request and must not be emitted as a successful `[DONE]` terminator. Client cancellation interrupts blocked stream event delivery, closes the upstream response, and releases local and Redis concurrency reservations. For upstream Responses API streams, EOF after terminal output events such as `response.output_text.done` or `response.output_item.done` is accepted as completion for model variants that omit `response.completed`.

If clients receive `budget_exhausted`, check the gateway log fields `internal_code`, `account_id`, and `pool_id`, then inspect Redis counters such as `budget:daily:account:<account_id>:<yyyymmdd>` and `budget:daily:global:<yyyymmdd>`. Daily token and AI Credits caps are only active when the Dashboard Config value or corresponding `BUDGET_MAX_DAILY_*` environment value is greater than `0`.

## Usage, Cost, and Cache Observability

After successful requests, the gateway writes a proxy-side `usage_ledger` row. With the real Copilot provider, it parses upstream `usage` and `copilot_usage` fields and records input tokens, cached input tokens, cache write tokens, output tokens, reasoning tokens, `nano_aiu`, estimated AI Credits, and estimated USD.

The dashboard Metrics tab shows these key indicators over the selected window:

| Metric | Operational use |
| --- | --- |
| AI Credits / Estimated USD | Approximate Copilot usage-based billing consumption for the window |
| Cache Hit Rate | Shows whether sticky/cache affinity is producing cache reads |
| Cached Input / Cache Write | Separates cache read savings from cache write cost |
| Reasoning Tokens | Identifies cost sources from reasoning models or high-reasoning requests |
| Token Details | Preserves upstream token type, count, and batch cost in ledger `token_details` |

Prometheus text metrics also include cached/cache read tokens, cache write tokens, reasoning tokens, nano AIU, AI Credits micro, estimated USD micros, and cache hit ratio permille. If cache hit rate stays low, check client profile sticky mode, route policies, session headers, and rebind/overflow metrics.

Query granularity:

| Granularity | Description |
| --- | --- |
| `raw` | Reads `usage_ledger` directly, request-accurate and best for short ranges |
| `hourly` | Reads `usage_rollup_hourly`, useful for multi-day trend queries |
| `daily` | Reads `usage_rollup_daily`, useful for long-term trends and cost reconciliation |
| `auto` | Uses raw within 24h, hourly within 90 days, and daily beyond 90 days |

Admin APIs support absolute date ranges: `/admin/usage/summary?from=2026-06-01&to=2026-06-23&granularity=auto`. Date-only `to` values use half-open range semantics and are advanced to the next UTC midnight, so `to=2026-06-23` includes the full June 23 day. The Usage Rollup Worker runs every five minutes and processes data up to `now()-2m` to avoid edge jitter from freshly written requests.

## Current Operations Workflows

### Account Onboarding, Grouping, and Offboarding

```mermaid
stateDiagram-v2
  [*] --> pending
  pending --> active: import valid credential
  active --> degraded: elevated risk or short failures
  active --> revoked: admin offboarding
  degraded --> active: probe recovery or manual confirmation
  degraded --> recovery: create recovery task
  degraded --> quarantined: risk continues rising
  degraded --> revoked: admin offboarding
  quarantined --> recovery: recover API
  quarantined --> revoked: admin offboarding
  recovery --> active: credential valid and risk reset
  recovery --> quarantined: credential missing/expired or recovery failed
  revoked --> [*]
```

State meanings:

| State | Description |
| --- | --- |
| `pending` | Waiting for validation after account creation |
| `active` | Credential is valid and account can be routed |
| `degraded` | Short failures or elevated risk; deweighted or limited |
| `recovery` | Recovery task in progress |
| `quarantined` | Routing paused until recovery or credential reimport |
| `revoked` | Fully offboarded, no automatic recovery |

Onboarding

1. Create the account in the dashboard or Admin API.
2. Use Device Flow or manual credential import for GitHub Copilot login credentials.
3. Worker runs the first probe; success keeps `active`, while failure may move to `degraded` or `quarantined`.
4. Add the account to one or more pools so it can be routed.

Device Flow:

```mermaid
sequenceDiagram
  participant D as Dashboard
  participant A as Admin API
  participant G as GitHub Device Flow
  participant C as Copilot Token API
  participant P as PostgreSQL

  D->>A: POST /admin/accounts/{id}/device-flow/start
  A->>G: Request device code
  G-->>A: user_code / verification_uri
  A-->>D: return code and URL
  D->>G: operator authorizes on GitHub
  D->>A: POST /admin/accounts/{id}/device-flow/complete
  A->>G: Poll OAuth token
  G-->>A: GitHub access token
  A->>C: Exchange Copilot bearer token
  C-->>A: Copilot token / expires_at
  A->>P: encrypt under credentials.account_id
```

API examples:

```bash
curl -s http://localhost:8001/admin/accounts/{account_id}/device-flow/start \
  -H "Authorization: Bearer dev-admin-token" \
  -X POST

curl -s http://localhost:8001/admin/accounts/{account_id}/device-flow/complete \
  -H "Authorization: Bearer dev-admin-token" \
  -H "Content-Type: application/json" \
  -d '{"device_code":"DEVICE_CODE_FROM_START"}'
```

If complete returns `202` with `error=authorization_pending`, the user has not finished GitHub authorization yet; call complete again later. If it returns `409 expired_token`, start again.

Grouping

1. Create a pool and set default model, priority, and sticky policy.
2. Add accounts to the pool and verify max concurrency, weights, and routing priority.
3. Use route policies to control protocol, model, and pool matching; sticky should not override health, budget, or seat validity.

Offboarding

1. First move the account to `quarantined` or `revoked` to stop new routing.
2. Clear pool memberships and sticky affinity so it is not selected again.
3. For full deletion, use `DELETE /admin/accounts/{id}` to cascade credentials, pool memberships, and affinity records.
4. For temporary removal, use `quarantined` and restore to `active` after recovery.

Recovery task flow:

```mermaid
flowchart TD
  A["operator clicks Recover or calls Admin API"] --> B["create recovery_tasks row"]
  B --> C["account enters recovery"]
  C --> D["scans every 60s"]
  D --> E{"active credential exists and not expired?"}
  E -->|"yes"| F["failure count"]
  F --> G["account active"]
  E -->|"no"| H["task fails and remains quarantined"]
```

### Model ID Mapping, Aliases, and Hidden Models

| Field | Description |
| --- | --- |
| `exposed` | Model name visible to clients |
| `upstream` | Actual upstream model ID sent to GitHub Copilot |
| `upstream_api` | Optional upstream endpoint: `chat_completions` or `responses` |
| `name` | Optional display name refreshed from Copilot `/models` |
| `vendor` | Optional model vendor refreshed from Copilot `/models`; `OpenAI` infers Responses |
| `enabled` | Whether the model is returned by `/v1/models` and allowed in requests |

GitHub Copilot upstream endpoint selection is mixed, not globally Responses by default. Selection order is: model catalog `upstream_api` wins; then Copilot `/models` `vendor` is normalized, where `OpenAI` / `Azure OpenAI` use upstream Responses and Google, Anthropic, Microsoft, and xAI use upstream Chat Completions; if vendor is empty, the gateway infers from `upstream`, `name`, and `exposed`: `gpt*`/o-series infer OpenAI, `gemini*` infers Google, `claude*`/`opus*`/`haiku*`/`sonnet*` infer Anthropic, `MAI*` infers Microsoft, and `grok*`/`xai*` infer xAI; other models follow the downstream request protocol.

```mermaid
flowchart LR
  A["Dashboard Models / Settings"] --> B["PATCH /admin/settings/model_catalog_json"]
  B --> C[(system_settings)]
  C --> D["GET /v1/models"]
  C --> E["request model resolution"]
  E --> F{"exposed enabled?"}
  F -->|"yes"| G["map to upstream model + upstream_api"]
  F -->|"no"| H["400 invalid_model"]
```

Example configuration:

```json
[
  {"exposed":"gpt-4o","upstream":"gpt-4o","enabled":true},
  {"exposed":"claude-sonnet","upstream":"claude-sonnet-4-20250514","enabled":true},
  {"exposed":"o3","upstream":"o3-mini","enabled":false}
]
```

### GitHub Login Token Expiry and Refresh

GitHub Copilot login credentials can expire or become invalid. PATs may have custom expiry dates, and tokens unused for over one year may be removed by GitHub. Expired or revoked tokens usually return `401` on next use.

- Check whether `credentials.expires_at` is approaching.
- Warn administrators before tokens expire so they can refresh or reimport credentials.
- After invalidation, degrade the account first, then reimport a new token and restore `active`.

## Alert Priority

```mermaid
flowchart TD
  A["alert triggered"] --> B{"impacts request availability?"}
  B -->|"yes"| C["prioritize gateway, Redis, Postgres, and active accounts"]
  B -->|"no"| D["handle sync, metric drift, config issues"]
  C --> E{"credential or seat invalid?"}
  E -->|"yes"| F["recover or remove account"]
  E -->|"no"| G["check routing, concurrency, and budget"]
```

| Priority | Description |
| --- | --- |
| High | Insufficient active accounts, gateway 5xx, Redis P99 spike, Postgres pool exhaustion, seat invalidation |
| Medium | Persistently low sticky hit rate, abnormal rebind/overflow, Copilot Metrics sync delay |
| Low | Dashboard display issues, non-critical statistic delays |

## Troubleshooting

### Account Cannot Be Routed

1. Check whether the account is still `active`.
2. Check whether concurrency has reached the limit.
3. Check budget, risk score, and seat status.
4. Check whether the sticky target needs rebind.

### Low Sticky Hit Rate

1. Confirm that sticky is enabled in client profile or route policy.
2. Check whether `sticky_session_header`, Claude Code/Codex session headers, or the derived affinity key are stable.
3. Check whether overflow triggers frequently.
4. Check whether account additions/removals caused large affinity migration.

### Copilot Metrics Sync Delay

1. Check whether worker is alive.
2. Check whether `copilot_metrics_sync_enabled` is enabled.
3. Check whether org access token or `GITHUB_TOKEN` is available.
4. Check the usage-report metadata request and every signed report download; an invalid or partial report is rejected without replacing the latest snapshot.
5. Check whether Postgres writes are blocked.

Metrics sync path:

```mermaid
flowchart TD
  A["hourly trigger"] --> B{"copilot_metrics_sync_enabled?"}
  B -->|"no"| C["skip"]
  B -->|"yes"| D["read metrics-enabled orgs"]
  D --> E{"org access_token or GITHUB_TOKEN?"}
  E -->|"none"| F["warn and skip org"]
  E -->|"present"| G["request latest 28-day report"]
  G --> H["download and validate every report file"]
  H --> I[(save snapshot and sync timestamp atomically)]
  I --> J["compare the latest report UTC day with same-org proxy requests"]
  J --> K{"drift > 10%?"}
  K -->|"yes"| L["record audit event"]
  K -->|"no"| M["update metrics only"]
```

## Rollback Principles

```mermaid
flowchart TD
  A["issue detected"] --> B{"can config be reverted?"}
  B -->|"yes"| C["client profile"]
  B -->|"no"| D["roll back service version"]
  C --> E["verify metrics recovery"]
  D --> E
```

- Prefer configuration rollback before binary rollback.
- After rollback, verify request success rate, routing distribution, and account status.
- Every recovery or removal operation should leave an audit trail.
