<!-- Runtime release README; links are relative to the staged release root. -->
# GHCP Pool Proxy Runtime Release

This is the runtime-only release of GHCP Pool Proxy. It deploys prebuilt Docker Hub images to Linux VM Docker Compose, local single-node Kind, or AKS with Azure PostgreSQL and Managed Redis. It does not include application source or local build tooling.

[中文](README.zh.md) | English

## Contents

- [Quick Start](#quick-start)
- [Release Contents](#release-contents)
- [Configuration](#configuration)
- [Operations](#operations)

## Quick Start

### Linux VM

Run on a supported x86_64 Linux VM:

```bash
chmod +x deploy/deploy.sh
deploy/deploy.sh start
```

On its first run, `start` creates `~/ghcp_proxy/config.yaml` and `~/ghcp_proxy/.env` automatically and never overwrites existing files. Run `deploy/deploy.sh generate-config` first when you want to create and review the YAML before starting; if an existing persistent directory is missing its YAML unexpectedly, `start` refuses to continue rather than silently restoring defaults.

Both deployment entry points use the bundled `release-manifest.env` by default and accept `--release-manifest FILE` or `RELEASE_MANIFEST` to select another immutable release set. Missing prerequisites prompt before installation; pass `--install-missing` to authorize installation in non-interactive automation. `deploy` is a shared action alias: it means `start` for the VM entry point and `apply` for the cluster entry point. Cluster `--yes` accepts resource/deployment confirmations only and does not authorize tool installation. VM `reset` deliberately retains its stronger `GHCP_RESET_CONFIRM=reset` deletion guard.

Gateway and Admin bind to the VM loopback interface by default. Forward them over SSH from your workstation:

```bash
ssh -N -L 8000:127.0.0.1:8000 -L 8001:127.0.0.1:8001 <user>@<server>
```

Then open the Dashboard at `http://127.0.0.1:8001/` and send model requests to `http://127.0.0.1:8000/`. For a private reverse proxy on another host, set `GATEWAY_BIND_ADDR` and `ADMIN_BIND_ADDR` to the reviewed private interface and enforce TLS plus firewall restrictions. Do not publish Admin as plaintext on an untrusted network.

`start` reports the stack ready only after Gateway health and readiness, the Admin dashboard, and Worker container health all pass.

### Local Single-Node Kubernetes

```bash
deploy/deploy-cluster.sh local apply
```

The script checks Docker, Kind, kubectl, and Kustomize. When a component is missing, it explains the installation and asks for confirmation, selects the Linux package manager, and uses `sudo` when system privileges are required. This mode creates or reuses the `ghcp-local` Kind cluster and runs disposable PostgreSQL and Redis inside it.

### AKS and Azure PaaS

```bash
deploy/deploy-cluster.sh azure apply
```

The interactive guide selects `create` or `reuse` independently for the resource group, VNet, three subnets, AKS, PostgreSQL Flexible Server, and Azure Managed Redis. Prompts with a value in brackets accept that default on Enter. Interactive reuse lists visible resource groups, same-region networks/services, and subnets from the selected VNet as numbered choices; Enter selects `[1]`, while `0` allows manual input. Non-interactive reuse still requires the resource-group name and complete ARM IDs through environment variables. New resources go through Bicep build and Azure what-if before a confirmed apply. A new AKS cluster uses a preauthorized user-assigned control-plane identity with Network Contributor scoped to its node subnet. Reused AKS and PostgreSQL resources must use the selected VNet/subnets; a reused Redis service remains unchanged while this deployment creates its private endpoint and DNS attachment. Sensitive inputs use hidden prompts and `0600` temporary files that are removed on exit.

## Release Contents

| Path | Purpose |
| --- | --- |
| `deploy/deploy.sh` | VM initialization, config generation, migration, lifecycle, and log commands |
| `deploy/docker-compose.vm.yml` | PostgreSQL, Redis, Gateway, Admin, and Worker services |
| `deploy/deploy-cluster.sh` | Interactive local Kind and Azure AKS deployment entry point |
| `deploy/azure/` | Bicep for Azure networking, AKS identity/RBAC, PostgreSQL, Managed Redis, and private connectivity |
| `deploy/k8s/` | Production, staging, disposable test overlays, and ordered rollout |
| `deploy/lib/` | Prerequisite installation and Azure orchestration helpers |
| `scripts/` | Release-manifest and Gateway smoke tools |
| `config.example.yaml` | VM startup defaults generated from the same code as `generate-config` |
| `migrations/` | Current schema baseline, version marker, and numbered migration SQL |
| `release-manifest.env` | Non-sensitive release set: shared app version, Git SHA, schema version, four latest tags, and their immutable digests |
| `docs/` | Architecture, operations, protocol, and routing documentation |

Release builds use these tags as human-readable aliases for the four roles:

- `pczhao1210/ghcp-pool-proxy:gateway-latest`
- `pczhao1210/ghcp-pool-proxy:admin-latest`
- `pczhao1210/ghcp-pool-proxy:worker-latest`
- `pczhao1210/ghcp-pool-proxy:migration-latest`

Before starting services, `deploy.sh` validates that the release manifest schema matches the bundled migration schema, derives each `repository@sha256:...` reference from the manifest, and pulls that immutable reference directly. Later tag movement cannot change a deployment or prevent an old bundle from rolling back by digest.

## Configuration

- `~/ghcp_proxy/config.yaml`: provider endpoints, timeouts, connection and queue sizing, maintenance fallbacks, and logging.
- `~/ghcp_proxy/.env`: generated secrets, host paths, loopback bind addresses, ports, and database/Redis addresses.
- PostgreSQL: Dashboard-managed budgets, feature flags, model catalog, URLs, keys, and retention overrides.

Keep `.env` private. Do not casually rotate `CREDENTIAL_MASTER_KEY` after credentials have been stored.

## Operations

```bash
deploy/deploy.sh logs
deploy/deploy.sh stop
deploy/deploy.sh start
```

Release update procedure: update the release files, review the included migrations, back up PostgreSQL, then run `deploy/deploy.sh start`. Existing `.env` and `config.yaml` files under `~/ghcp_proxy` are preserved.

Reset permanently deletes PostgreSQL and Redis runtime data. It aborts without deleting either directory if `docker compose down` cannot stop the stack:

```bash
GHCP_RESET_CONFIRM=reset deploy/deploy.sh reset
```

See [Operations](docs/operations.en.md), [Protocol](docs/protocol.en.md), and [Routing](docs/routing.en.md) for details.