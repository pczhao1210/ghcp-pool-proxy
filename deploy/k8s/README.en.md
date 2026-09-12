# Kubernetes deployment baseline

This package defines the current Kubernetes baseline; remaining production acceptance is governed by the [cluster deployment plan](../../docs/plans/cluster-deployment.zh.md). Production keeps one Gateway, one Admin, one general Worker, and one organization-sync Worker; staging changes only Gateway to two replicas with rolling updates, a PDB, and hostname topology spread.

English | [中文](README.zh.md)

## Scope

Included:

- Kustomize production, staging, and self-contained test overlays.
- One `Recreate` replica each for Admin, general Worker, and organization-sync Worker; staging changes only Gateway to two replicas with `RollingUpdate`.
- A dedicated `metrics-sync` Worker role for durable organization metrics and seat synchronization, with its GitHub token Secret mounted only into that Deployment.
- ClusterIP Services, dependency-aware readiness probes, process-only liveness probes, and bounded termination.
- Restricted non-root Pods, read-only root filesystems, disabled service-account token mounts, default-deny NetworkPolicy, and Secret references.
- A separately ordered migration Job with a PostgreSQL advisory lock.
- Optional Prometheus Operator ServiceMonitors for Gateway and Worker.
- Redis protocol v2 configuration, explicit Admin cutover, per-primary Cluster inventory, and a disposable real-Cluster regression target.

Not included:

- Persistent PostgreSQL/Redis, Ingress, TLS certificates, Azure Key Vault, or the Secrets Store CSI driver. The `test` overlay is the explicitly disposable PostgreSQL/Redis exception.
- Multiple production Gateways, any multi-replica Admin/Worker role, or HPA; staging includes the Gateway PDB and topology spread.
- A portable FQDN egress policy. Standard NetworkPolicy cannot express one.

PostgreSQL and Redis must be supplied outside the application workload lifecycle. Redis supports native TLS with `REDIS_TLS=true`; non-Cluster modes also require `REDIS_TLS_SERVER_NAME`. Cluster mode verifies each advertised node hostname and rejects a fixed TLS server name.

### Self-Contained Test Mode

The `test` overlay is the one exception to the external-data-service boundary. It starts one PostgreSQL 16 and one Redis 7 container inside the `ghcp-test` namespace, with the same single-node topology and Service DNS names as Docker Compose (`postgres:5432` and `redis:6379`). Both data volumes are `emptyDir`: a Pod replacement or namespace deletion intentionally discards all test data. The overlay is for functional, migration, readiness, and protocol validation only; it does not provide persistence, backup, data-service HA, or production acceptance evidence.

Use a release set against any approved Kubernetes cluster with no external PostgreSQL or Redis dependency:

```bash
RELEASE_MANIFEST=/secure/path/release-manifest.env \
  deploy/k8s/apply.sh test
```

For a fully disposable local Kind run, which builds and loads the four application images locally, run this from the source checkout:

```bash
make k8s-test
```

### Single-Node Functional Tests

One Kubernetes node with one PostgreSQL instance and one Redis instance is supported for functional, migration, readiness, and protocol smoke tests. Use `deploy/k8s/base` or the single-Gateway production overlay; do not use the staging overlay because its two-Gateway hostname spread needs at least two schedulable hostnames. This profile provides no application redundancy, PDB guarantee, or node-failure capacity commitment and is not HA evidence.

## Prerequisites

- Kubernetes with the restricted Pod Security profile available.
- `kubectl` and Kustomize 5.
- For production or staging, external PostgreSQL and Redis reachable from the application namespace. The `test` overlay supplies disposable in-namespace services instead.
- Four images built from the same Git revision:
  - `gateway`
  - `admin`
  - `worker`
  - `migration`

From a clean source checkout, build and push the four Dockerfile targets as one release set (runtime bundles do not include `start.sh` or the Dockerfile):

```bash
IMAGE_REPOSITORY="$REGISTRY/ghcp-pool-proxy" ./start.sh --push
IMAGE_REPOSITORY="$REGISTRY/ghcp-pool-proxy" ./start.sh --package
```

`--push` builds and publishes `gateway-latest`, `admin-latest`, `worker-latest`, and `migration-latest` from the same Git SHA, then writes `release-manifest.env` with the schema and four registry digests. `--package` includes that manifest, this Kustomize tree, the Azure Bicep baseline, and `deploy/deploy-cluster.sh` in the runtime bundle.

Use the packaged interactive entry point for the supported local Kind or Azure baseline:

```bash
deploy/deploy-cluster.sh local
deploy/deploy-cluster.sh azure
```

The Azure guide supports explicit create/reuse choices for the resource group, VNet/subnets, AKS, PostgreSQL Flexible Server, and Azure Managed Redis. Bracketed defaults are accepted on Enter; interactive reuse presents numbered visible-resource choices, with `[1]` as the default and `0` for manual input. Non-interactive reuse requires explicit environment variables. It runs Bicep build and Azure what-if before a confirmed apply. New AKS uses a user-assigned control-plane identity preauthorized on the node subnet; reused AKS/PostgreSQL must match the selected subnets, and reused Redis receives a deployment-managed private endpoint/DNS attachment. Ingress, platform monitoring, backup/restore, and destroy automation remain environment-owned work.

```bash
RELEASE_MANIFEST=/secure/path/release-manifest.env \
  deploy/k8s/apply.sh staging
```

The Kustomize sources retain human-readable `*-latest` tags. `apply.sh` validates the release manifest schema against the repository migration target and rewrites all four rendered application/migration images to the manifest digests before applying them. This applies to production, staging, and test; the test data-service images remain the fixed `postgres:16-alpine` and `redis:7-alpine`. The production `registry.invalid` placeholders are release-manifest inputs, not files to edit by hand.

## Central Secret Sources

Clusters do not support a different manually maintained sensitive environment value per Pod, node, or operator session. Every Gateway/Admin/Worker starts from the same namespace-scoped, versioned secret source and rolls out together after updates. The baseline uses Kubernetes Secrets; Key Vault CSI file projection is an optional environment choice. Create the namespace first:

```bash
ENVIRONMENT=staging
NAMESPACE=ghcp-staging
kubectl apply -f "deploy/k8s/overlays/$ENVIRONMENT/namespace.yaml"
```

The baseline requires the following Kubernetes Secret keys. External Secrets, a Key Vault synchronizer, or another controlled secret manager may write them, but an individual Pod's local environment must not override them:

| Secret / key | Consumer | Purpose |
| --- | --- |
| `ghcp-runtime-secrets` / `ADMIN_TOKEN` | Gateway/Admin/Worker | Admin API and Gateway metrics token |
| `ghcp-runtime-secrets` / `POSTGRES_DSN` | Gateway/Admin/Worker | Runtime account DSN without DDL privileges |
| `ghcp-runtime-secrets` / `REDIS_PASSWORD` | Gateway/Admin/Worker | Redis data-plane password |
| `ghcp-runtime-secrets` / `CREDENTIAL_MASTER_KEY` | Gateway/Admin/Worker | 32-byte raw or 64-character hexadecimal credential master key |
| `ghcp-org-sync-worker-secrets` / `github-token` | `ghcp-org-sync-worker` only | GitHub metrics/seat-sync token |
| `ghcp-migration-postgres-dsn` / `postgres-dsn` | `ghcp-migrate` only | DDL-authorized migration DSN |

When Key Vault CSI is chosen, the application supports the corresponding `_FILE` variables. Copy [secret-provider-classes.yaml.example](keyvault/secret-provider-classes.yaml.example) to a controlled environment-configuration location, replace the Key Vault name, tenant ID, and Workload Identity client IDs, then have the environment overlay replace Secret volume/env references with CSI file mounts. Do not configure an inline value and `_FILE` source for the same setting together.

Sensitive values do not enter ConfigMaps, images, Kustomize parameters, deployment output, or logs. A baseline Secret update does not modify an already started container's environment, so a complete rollout is required to establish one startup version. For credential master-key rotation, make the old and new keys readable by every Pod before switching the write version. Empty, missing, malformed, or simultaneously inline and file-backed file values fail fast.

Redis endpoint and topology are not secrets and are supplied through an environment-specific ConfigMap. For `single` mode, merge only non-sensitive literals in the controlled overlay:

```yaml
configMapGenerator:
  - name: ghcp-runtime-env
    behavior: merge
    literals:
      - PROVIDER=copilot
      - REDIS_CLIENT_MODE=single
      - REDIS_PROTOCOL_VERSION=2
      - REDIS_ADDR=redis.example.internal:10000
      - REDIS_DB=0
      - REDIS_TLS=true
      - CREDENTIAL_KEY_VERSION=2026-08
```

For `sentinel` or `cluster`, supply non-sensitive `REDIS_ADDRS` and omit `REDIS_ADDR`; keep `REDIS_DB=0` for Cluster. Single-node functional tests may use the same namespace-scoped test Secrets; destroy the namespace and data services after the test.

## Redis Protocol Cutover

Protocol v2 is a breaking Redis key and Lua contract. Do not roll v1 and v2 writers together, and never use a v1 writer with `REDIS_CLIENT_MODE=cluster`.

1. Run `make test-redis-cluster` to verify the client contract, then validate v2 against the existing nonsharded Redis deployment with the environment's approved load checks.
2. Stop ingress, drain Gateway streams, stop general and organization-sync Workers, and wait for the approved maximum lease/request TTL.
3. Roll only Admin with `REDIS_PROTOCOL_VERSION=2`, then port-forward its Service and submit the authenticated maintenance action:

```bash
kubectl -n "$NAMESPACE" port-forward service/ghcp-admin 8001:8001
curl --fail-with-body --oauth2-bearer "$ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"protocol":2,"writers_drained":true}' \
  http://127.0.0.1:8001/admin/redis/cutover
```

The action records a source-keyspace count and SHA-256 audit value, increments the durable epoch, writes the digest-validated v2 manifest, and rebuilds active binding caches and current-day budget counters from PostgreSQL before ready is restored. It deliberately does not copy sticky maps, leases, or pending reservations.

For `single|sentinel -> cluster`, create and validate a green Cluster first, update only Admin to the v2 Cluster settings, then call `POST /admin/redis/reconcile`. This creates another epoch and rebuilds from PostgreSQL; no request-path dual write or direct Redis data copy is allowed. Roll Gateway and Workers only after Admin readiness succeeds. A rollback to an old endpoint is another reconcile/cutover, not an endpoint flip.

## Network preparation

The portable baseline permits application egress only on TCP 443, 5432, and 6379, and migration egress only on 5432. Patch these rules for non-default data-service ports.

Before production, restrict PostgreSQL and Redis to reviewed CIDRs or selectors and restrict HTTPS with the selected CNI, egress gateway, or firewall. The portable TCP 443 rule is intentionally broader than a production FQDN allowlist.

Admin ingress is accepted only from namespaces carrying the management label. Worker metrics are accepted only from monitoring namespaces:

```bash
kubectl label namespace "$PRIVATE_INGRESS_NAMESPACE" \
  ghcp-pool-proxy.io/admin-access=true --overwrite
kubectl label namespace "$MONITORING_NAMESPACE" \
  ghcp-pool-proxy.io/monitoring=true --overwrite
```

Gateway and Admin Ingress resources are environment-specific and are not included. A Gateway ingress must support SSE without response buffering, allow the configured request-body size and stream timeout, and never replay `/v1/*` POST requests. Admin exposure must remain private.

## Deploy

Render and review both application and migration resources:

```bash
kustomize build "deploy/k8s/overlays/$ENVIRONMENT"
kustomize build "deploy/k8s/overlays/$ENVIRONMENT/migration"
```

The rollout script enforces migration-before-application ordering, waits for the Job, and rolls Gateway, Admin, general Worker, and organization-sync Worker sequentially:

```bash
deploy/k8s/apply.sh "$ENVIRONMENT"
```

Set `KUBE_CONTEXT`, `MIGRATION_TIMEOUT`, or `ROLLOUT_TIMEOUT` when required. Never apply the migration Job and application Deployments as one unordered operation.

The default pool limit is 12 PostgreSQL connections per process. Including the dedicated organization-sync Worker, production can consume 48 application connections and staging with two Gateways can consume 60, plus migration and operational headroom; retain at least 20 percent capacity.

## Verify

Before connecting to a cluster, run the local manifest gate from the source checkout:

```bash
make k8s-validate
```

It renders the staging, production, and self-contained test overlays. It verifies that production remains a single-replica `Recreate` boundary, staging makes only Gateway a two-replica rolling update with a PDB and hostname topology spread, the test overlay contains one PostgreSQL and one Redis workload, and migration targets and lock timeout match the repository contract. It does not replace cross-Pod request, SSE drain, or node-eviction acceptance in an approved staging cluster.

The two-hostname staging topology deliberately uses `maxUnavailable: 1` and `maxSurge: 0`. A surge Pod would create a `2:1` hostname distribution and is rejected by the strict `maxSkew: 1` spread rule, which would stall the rollout. The PDB still preserves one ready Gateway while the replacement is scheduled on the vacated hostname. The migration lock timeout is `5m`, using Go duration syntax; `5min` is invalid.

In each approved target staging environment, verify active SSE drain, explicit Gateway rollout, PDB-respecting node eviction, and restoration of the two-hostname spread. Also verify migration to the release target, readiness of all four Deployments, the organization token's restricted mount, and fenced/idempotent sync tasks. Historical local results are not target-environment acceptance.

`make test-redis-cluster` exercises the v2 Store against a disposable three-primary/three-replica Cluster, including slot inventory, RPM, concurrency/binding, sticky cleanup and fail-closed recovery. The retained `{budget}` hash tag serves RPM, not removed daily consumption quotas. Rerun applicable capacity/failover checks against the selected service; old local p95 numbers are not production guarantees. `make k8s-test` covers the disposable single-node path described above and cleans up its cluster.

```bash
kubectl -n "$NAMESPACE" get pods,services
kubectl -n "$NAMESPACE" get job ghcp-migrate
kubectl -n "$NAMESPACE" rollout status deployment/ghcp-gateway
kubectl -n "$NAMESPACE" rollout status deployment/ghcp-admin
kubectl -n "$NAMESPACE" rollout status deployment/ghcp-worker
kubectl -n "$NAMESPACE" rollout status deployment/ghcp-org-sync-worker
```

Port-forward each Service and check readiness:

```bash
kubectl -n "$NAMESPACE" port-forward service/ghcp-gateway 8000:8000
curl -fsS http://127.0.0.1:8000/readyz
curl -fsS --oauth2-bearer "$ADMIN_TOKEN" http://127.0.0.1:8000/metrics
```

Repeat for Admin port `8001` and Worker port `8002`. Protocol equivalence should then be checked with `scripts/gateway_smoke.sh` and a configured staging client.

If Prometheus Operator is installed, `apply.sh` installs Gateway and Worker ServiceMonitors. The baseline Gateway scrape reads its bearer token from `ghcp-runtime-secrets`; production may use a dedicated scrape token or a Key Vault CSI/mTLS alternative, but collector Pods must not each maintain a different token.

## Rollback

- Roll back only to images compatible with the installed schema.
- Prefer roll-forward migrations; do not automatically run unknown down migrations.
- Keep the migration logs and rollout state when a release fails.
- Do not replay interrupted model POST requests during recovery.
