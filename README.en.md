<!-- Runtime release README; links are relative to the staged release root. -->
# GHCP Pool Proxy VM Release

This repository is the runtime-only VM release of GHCP Pool Proxy. It deploys prebuilt Docker Hub images and does not include application source or local build tooling.

[中文](README.zh.md) | English

## Contents

- [Quick Start](#quick-start)
- [Release Contents](#release-contents)
- [Configuration](#configuration)
- [Operations](#operations)

## Quick Start

Run on a supported x86_64 Linux VM:

```bash
chmod +x deploy/deploy.sh
if [ ! -f "$HOME/ghcp_proxy/config.yaml" ]; then
  deploy/deploy.sh generate-config
fi
# Review ~/ghcp_proxy/config.yaml before starting.
deploy/deploy.sh start
```

`generate-config` does not require Docker. It creates `~/ghcp_proxy/config.yaml`, never overwrites an existing file, and `start` refuses to run without one.

Open the Dashboard at `http://<server>:8001/` and send model requests to `http://<server>:8000/`.

## Release Contents

| Path | Purpose |
| --- | --- |
| `deploy/deploy.sh` | VM initialization, config generation, migration, lifecycle, and log commands |
| `deploy/docker-compose.vm.yml` | PostgreSQL, Redis, Gateway, Admin, and Worker services |
| `config.example.yaml` | VM startup defaults generated from the same code as `generate-config` |
| `migrations/` | Current schema baseline, version marker, and numbered migration SQL |
| `docs/` | Architecture, operations, protocol, and routing documentation |

The deployment pulls these images:

- `pczhao1210/ghcp-pool-proxy:gateway-latest`
- `pczhao1210/ghcp-pool-proxy:admin-latest`
- `pczhao1210/ghcp-pool-proxy:worker-latest`

## Configuration

- `~/ghcp_proxy/config.yaml`: provider endpoints, timeouts, connection and queue sizing, maintenance fallbacks, and logging.
- `~/ghcp_proxy/.env`: generated secrets, host paths, ports, and database/Redis addresses.
- PostgreSQL: Dashboard-managed budgets, feature flags, model catalog, URLs, keys, and retention overrides.

Keep `.env` private. Do not casually rotate `CREDENTIAL_MASTER_KEY` after credentials have been stored.

## Operations

```bash
deploy/deploy.sh logs
deploy/deploy.sh stop
deploy/deploy.sh start
```

Release update procedure: update the release files, review the included migrations, back up PostgreSQL, then run `deploy/deploy.sh start`. Existing `.env` and `config.yaml` files under `~/ghcp_proxy` are preserved.

Reset permanently deletes PostgreSQL and Redis runtime data:

```bash
GHCP_RESET_CONFIRM=reset deploy/deploy.sh reset
```

See [Operations](docs/operations.en.md), [Features](FEATURES.en.md), [Protocol](docs/protocol.en.md), and [Routing](docs/routing.en.md) for details.