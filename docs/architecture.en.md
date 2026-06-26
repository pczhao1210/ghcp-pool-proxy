# Architecture

GHCP Pool Proxy decouples downstream model protocol endpoints from upstream Copilot account resources. Clients see OpenAI / Anthropic-compatible APIs, while the system internally coordinates canonical DTOs, router, provider adapter, and control plane for account selection, health management, budget control, and observability.

## Architecture Goals

- Expose model protocols externally, not a general GitHub CLI or SDK operation API.
- Keep the gateway stateless; put hot state in Redis and source-of-truth state in PostgreSQL.
- Routing decisions prioritize health, budget, risk, concurrency, and seat status; sticky affinity is only a soft preference.
- Account lifecycle, recovery, org/seat sync, and Copilot Metrics sync live in the control plane and worker, outside the request hot path.

## Overall Structure

```mermaid
flowchart LR
  Client["Client / SDK / Claude Code"] --> Gateway["Gateway :8000"]

  subgraph DataPlane["Data Plane"]
    Gateway --> Canonical["Canonical Protocol Layer"]
    Canonical --> Router["Router Snapshot"]
    Router --> Provider["Copilot Provider Adapter"]
    Provider --> Copilot["GitHub Copilot Upstream"]
  end

  subgraph ControlPlane["Control Plane"]
    Dashboard["Dashboard /"] --> Admin["Admin API /admin/*"]
    Admin --> Postgres[(PostgreSQL)]
  end

  subgraph WorkerPlane["Worker Plane"]
    Worker["Worker"] --> Recovery["Recovery Tasks"]
    Worker --> Probe["Health Probe"]
    Worker --> MetricsSync["Copilot Metrics Sync"]
  end

  Gateway --> Redis[(Redis)]
  Gateway --> Postgres
  Worker --> Postgres
  MetricsSync --> GitHubAPI["GitHub REST API"]
```

## Request Path

```mermaid
sequenceDiagram
  participant C as Client
  participant G as Gateway
  participant R as Router
  participant P as Provider Adapter
  participant U as GitHub Copilot

  C->>G: POST /v1/chat/completions or /v1/responses or /v1/messages
  G->>G: parse protocol and build canonical request
  G->>R: select pool, account, and sticky target
  R-->>G: return selection
  G->>P: call upstream adapter
  P->>U: call Copilot upstream
  U-->>P: return response or error
  P-->>G: canonical response
  G-->>C: return in downstream protocol format
```

## Config Refresh and Recovery Flow

```mermaid
flowchart TD
  Operator["Operator"] --> Dashboard["Dashboard"]
  Dashboard --> Admin["Admin API"]
  Admin -->|"accounts / pools / route policy / settings"| PG[(PostgreSQL)]
  PG -->|"load on startup + refresh every 30s"| Snapshot["Gateway Router Snapshot"]
  Snapshot --> Router["request routing"]

  Admin -->|"recover account"| Task[(recovery_tasks)]
  Task -->|"scan every 60s"| Worker["Recovery Worker"]
  Worker --> Cred{"active credential valid? / active credential available?"}
  Cred -->|"yes"| Active["reset risk and restore active"]
  Cred -->|"no"| Quarantined["remain or enter quarantined"]
```

## Model Catalog Flow

```mermaid
flowchart LR
  Admin["Dashboard / Admin API"] -->|"PATCH /admin/settings/model_catalog_json"| Settings[(system_settings)]
  Settings -->|"read model_catalog_json"| Catalog["Gateway Model Catalog"]
  Catalog --> Models["return exposed models"]
  Catalog --> Resolve["resolve exposed -> upstream"]
  Resolve --> Provider["Copilot Provider Adapter"]
  Resolve -->|"disabled or missing"| Invalid["400 invalid_model"]
```

## Copilot Metrics Sync Flow

```mermaid
flowchart LR
  Worker["Metrics Sync Worker"] --> Flag{"copilot_metrics_sync_enabled?"}
  Flag -->|"no"| Skip["skip this run"]
  Flag -->|"yes"| Orgs["read metrics-enabled orgs"]
  Orgs --> Token{"org token or GITHUB_TOKEN?"}
  Token -->|"none"| Warn["warn and skip org"]
  Token -->|"present"| GitHub["GitHub Copilot Metrics API"]
  GitHub --> Snapshot[(metrics snapshots)]
  Snapshot --> Reconcile["reconcile with proxy usage"]
  Reconcile --> Dashboard["dashboard sync status"]
```

## Layer Responsibilities

### Gateway

- Receives OpenAI Chat Completions, OpenAI Responses API, and Anthropic Messages requests.
- Converts requests into a canonical request model.
- Handles authentication, global budget checks, model catalog mapping, routing, account-level budget checks, streaming proxying, and error mapping.
- Loads router snapshots at startup and periodically refreshes pools, account memberships, and route policies from PostgreSQL.
- Records traces, latency, token usage, sticky metrics, provider errors, and usage ledger entries.

### Canonical Protocol Layer

- Absorbs request-format differences across protocols.
- Normalizes tool calls, streaming events, model aliases, and response structures.
- Keeps only internal abstractions and prevents client-specific formats from leaking into the provider layer.

### Router

- Selects accounts based on protocol, model, route policy, pool state, account state, and concurrency limits.
- Supports sticky affinity, rebind, and overflow.
- Filters out inactive pools, inactive accounts, unavailable org/enterprise seats, and over-concurrency accounts.
- Sorts candidate accounts by risk, current concurrency, pool membership weight, and account priority.

### Copilot Provider Adapter

- Converts canonical requests into upstream-compatible requests.
- Hides upstream error-code differences and normalizes 401, 403, 429, 5xx, and network timeouts.
- Handles upstream access only and does not perform client protocol adaptation.

### Admin / Worker

- Admin handles accounts, credential import, pools, client profiles, settings, GitHub org sync entrypoints, audit queries, and dashboard static assets.
- Worker handles account recovery tasks, credential expiry warnings, health probes, and scheduled Copilot Metrics sync.
- Admin API requires a bearer token. Dashboard static pages are served by admin at root and call `/admin/*` with the admin token.

## Storage Boundaries

```mermaid
flowchart TD
  Hot["Hot state"] --> Redis[(Redis)]
  Cold["Source of truth"] --> Postgres[(PostgreSQL)]
  Hot --> Concurrency["current concurrency"]
  Hot --> Affinity["Sticky affinity map"]
  Hot --> RateLimit["short-window rate counters"]
  Cold --> Accounts["account and credential metadata"]
  Cold --> Policies["pools, policies, budgets, audit"]
```

- PostgreSQL stores accounts, credential metadata, pools, policies, budgets, audit events, and recovery tasks.
- PostgreSQL also stores `system_settings`, model catalog configuration, GitHub org data, metrics snapshots, and proxy usage ledger entries.
- Redis stores concurrency counters, short-TTL affinity mappings, rate-limit counters, and distributed locks.
- Plaintext credentials are never stored; sensitive content must be encrypted and masked.

## Key Boundaries

- The data plane does not directly execute general GitHub operations.
- Routing decisions use proxy-side real-time state and do not depend on Copilot Metrics in the hot path.
- Sticky session is a soft constraint; health, budget, risk, and seat validity always take priority.
- Single-machine and clustered deployments share the same state-boundary design so the system can scale smoothly.
