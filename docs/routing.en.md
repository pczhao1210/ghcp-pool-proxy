# Routing Rules

This document describes routing from model to pool, pool to account, and sticky affinity with overflow. The MVP principle is: health and availability first, sticky affinity as a soft preference.

For protocol-aware policies and Claude Code / Codex client setup, see [protocol-aware-routing.en.md](protocol-aware-routing.en.md). For the combined routing, sticky affinity, concurrency, and risk score model, see [routing-sticky-risk.en.md](routing-sticky-risk.en.md).

## Routing Inputs

- Requested model and protocol type, such as `openai_chat`, `openai_responses`, or `anthropic_messages`.
- Default model, sticky configuration, and tool-call compatibility options from client profiles.
- Route policy fields such as `request_format`, `model_pattern`, `load_balance_strategy`, pool priority, and sticky mode.
- Pool active state, account active state, concurrency, risk, priority, pool membership weight, and seat status.
- Budget checks are performed by the gateway at global and account scope; the router does not read budget ledgers directly.

## Configuration Hot Refresh

The gateway router uses in-memory snapshots for the hot path. Snapshots are loaded from PostgreSQL at startup and refreshed every 30 seconds for pools, pool account memberships, and route policies.

```mermaid
flowchart LR
  Admin["Admin API / Dashboard"] -->|"pool / route policy"| PG[(PostgreSQL)]
  PG -->|"startup load"| Snapshot["Router Snapshot"]
  PG -->|"reload every 30s"| Snapshot
  Snapshot --> Select["Select / SelectWithPreference"]
  Select --> Request["request routing"]
```

The model catalog is not part of the router snapshot. The gateway reads `model_catalog_json` when handling `/v1/models` and request model resolution, mapping exposed names to upstream models and optionally selecting the upstream Copilot endpoint with `upstream_api` (`chat_completions` or `responses`). Upstream endpoint selection is not globally Responses by default; it is mixed: `upstream_api` wins; Copilot-refreshed `vendor=OpenAI` models and known `gpt-5.5` use upstream Responses; other models follow the downstream request protocol, where `/v1/responses` uses Responses and Chat-compatible requests use Chat Completions.

## Routing Flow

```mermaid
flowchart TD
  A["receive request"] --> B["normalize protocol"]
  B --> C["resolve exposed model to upstream"]
  C --> D["global budget and RPM check"]
  D --> E["affinity key"]
  E --> F["match route policy"]
  F --> G{"sticky enabled?"}
  G -->|"no"| H["select available account"]
  G -->|"yes"| I["query Redis affinity map"]
  I --> J{"target still usable?"}
  J -->|"yes"| K["reuse target"]
  J -->|"no"| L["perform rebind"]
  L --> M{"overflow?"}
  M -->|"yes"| N["record overflow and select replacement"]
  M -->|"no"| O["record rebind and update affinity"]
  K --> P["account budget and RPM check"]
  H --> P
  N --> P
  O --> P
  P --> Q["execute upstream request"]
```

## Rule Priority

1. Explicit route policies take priority over the default pool.
2. Policies matching both `request_format` and `model_pattern` take priority; `*` means any protocol or model.
3. Active accounts under their concurrency limit take priority over other account states.
4. Pool state, account state, seat state, concurrency, and risk take priority over sticky affinity.
5. Reuse the sticky target when it remains eligible; otherwise rebind.
6. When the sticky target is overloaded, overflow to another healthy account is allowed.
7. Account-level budget is checked after account selection; failures return rate-limit or budget errors.

## Load Balance Strategies

When sticky affinity does not provide an eligible target, the selected route policy chooses an account within its matched pool using `load_balance_strategy`.

| Strategy | Description |
| --- | --- |
| `risk_weighted` | Default behavior; prefer lower risk, lower current concurrency, higher pool weight, then lower account priority |
| `round_robin` | Rotate across eligible accounts for the same route policy, ordered by account priority then account id |
| `least_concurrency` | Prefer the eligible account with the lowest current concurrency, then higher pool weight, lower risk, and lower account priority |

## Sticky Modes

| Mode | Description |
| --- | --- |
| `none` | Sticky affinity disabled |
| `soft` | Default mode; prefer sticky target but allow automatic rebind |
| `strict` | Keep the same account when possible; rebind only when unavailable |
| `prefix` | Affinity by prefix hash, useful for batches with similar system prompts and tool schemas |

## Overflow Triggers

```mermaid
flowchart TD
  A["select sticky target"] --> B{"concurrency above threshold?"}
  B -->|"yes"| C["trigger overflow"]
  B -->|"no"| D{"account healthy and seat valid?"}
  D -->|"no"| C
  D -->|"yes"| E["keep sticky target"]
```

- Account current concurrency reaches or exceeds `max_concurrency`.
- Sticky target load ratio exceeds `max_sticky_load_ratio`.
- The account is no longer active, its seat is invalid, or its risk is too high.

## Account Selection

1. First filter inactive pools, inactive accounts, over-concurrency accounts, and unavailable org/enterprise seats.
2. Select the best account from candidates by risk score, current concurrency, pool membership weight, and account priority.
3. If the preferred sticky account remains in the candidate set, it is selected first; otherwise rebind begins.
4. The current implementation absorbs pool/account/policy changes through 30-second snapshot refreshes. Later phases can add event-driven refresh or rendezvous hashing to reduce migration.

```mermaid
flowchart TD
  A["Pool entries"] --> B{"pool active?"}
  B -->|"no"| X["reject"]
  B -->|"yes"| C{"account active?"}
  C -->|"no"| X
  C -->|"yes"| D{"seat usable?"}
  D -->|"no"| X
  D -->|"yes"| E{"current concurrency < max?"}
  E -->|"no"| X
  E -->|"yes"| F["candidate account"]
  F --> G["concurrency / weight"]
  G --> H["selected account"]
```

## Affinity Key

- The affinity key is composed from tenant or client profile identifier, protocol, canonical model, session key, or prefix hash.
- Only hashes are stored; prompt plaintext is not stored.
- Different accounts, models, and protocol formats do not share affinity by default.
- Recommended Claude Code / Codex session headers are described in [protocol-aware-routing.en.md](protocol-aware-routing.en.md).

## Routing Failure Handling

```mermaid
sequenceDiagram
  participant G as Gateway
  participant R as Router
  participant A as Account State

  G->>R: request routing
  R-->>G: selected account
  G->>G: upstream returns 401 / 403 / 429 / 5xx
  G->>A: update health, risk, and state
  G->>R: delete affinity or trigger rebind when needed
```

- 401, 403, and seat invalidation should first trigger degradation or quarantine.
- Repeated 429 responses trigger short cooldown and lower effective weight.
- 5xx responses and timeouts primarily feed health and risk scoring.

## Metrics

The repository reserves the following sticky-related metric semantics.

- `ghcp_sticky_hits_total`
- `ghcp_sticky_rebinds_total`
- `ghcp_sticky_overflows_total`

Detailed label definitions are in [routing-sticky-metrics.en.md](routing-sticky-metrics.en.md).
