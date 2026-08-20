# Kubernetes 单副本基线

本目录已完成[集群化改造方案](../../docs/plans/cluster-deployment.zh.md)的第 2 阶段单副本等价基线、第 3 阶段 staging Gateway 高可用、第 4 阶段专用组织同步 Worker、第 5 阶段 Redis protocol v2 运行时契约，以及第 6 阶段 schema-19/release-set 身份契约。production overlay 保持一个 Gateway、一个 Admin、一个 general Worker 和一个组织同步 Worker；staging overlay 仅将 Gateway 提升为双副本，并启用滚动更新、PDB 和 hostname topology spread。

[English](README.en.md) | 中文

## 范围

已包含：

- Kustomize production、staging 与自包含 test overlay。
- production 中 Admin、general Worker 和组织同步 Worker 各一个 `Recreate` 副本；staging 仅将 Gateway 提升为两个副本和 `RollingUpdate`。
- durable 组织 metrics/seat 同步使用专用 `metrics-sync` Worker role，GitHub token Secret 只挂载到该 Deployment。
- ClusterIP Service、依赖感知 readiness、只检查进程的 liveness，以及有界终止时间。
- restricted 非 root Pod、只读根文件系统、关闭 ServiceAccount token 挂载、默认拒绝 NetworkPolicy 和 Secret 引用。
- 独立排序执行、使用 PostgreSQL advisory lock 的 migration Job。
- Gateway 与 Worker 的可选 Prometheus Operator ServiceMonitor。
- Redis protocol v2 配置、显式 Admin cutover、按 primary 的 Cluster inventory，以及一次性真实 Cluster 回归目标。

未包含：

- 持久 PostgreSQL/Redis、Ingress、TLS 证书、Azure Key Vault 或 Secrets Store CSI driver。`test` overlay 是明确限定的一次性 PostgreSQL/Redis 例外。
- production 多 Gateway、任何多副本 Admin/Worker role 或 HPA；staging 已包含 Gateway PDB 和 topology spread。
- 可移植的 FQDN egress 规则；标准 NetworkPolicy 无法表达该规则。

PostgreSQL 与 Redis 必须位于应用工作负载生命周期之外。Redis 支持 `REDIS_TLS=true` 的原生 TLS；非 Cluster mode 还必须设置 `REDIS_TLS_SERVER_NAME`。Cluster mode 会校验每个已声明节点的 hostname，并拒绝固定 TLS server name。

### 自包含 Test 模式

`test` overlay 是“数据服务位于集群外”边界的唯一例外。它会在 `ghcp-test` namespace 内启动一个 PostgreSQL 16 和一个 Redis 7 容器，使用与 Docker Compose 相同的单节点拓扑及 Service DNS 名称（`postgres:5432`、`redis:6379`）。两个数据卷均为 `emptyDir`，Pod 被替换或 namespace 被删除时所有测试数据都会被有意清除。该 overlay 只用于功能、migration、readiness 与协议验证，不提供持久化、备份、数据服务 HA 或 production 验收证据。

在任意已批准 Kubernetes 集群中使用 release set 运行，且不依赖外部 PostgreSQL 或 Redis：

```bash
RELEASE_MANIFEST=/secure/path/release-manifest.env \
  deploy/k8s/apply.sh test
```

如需完全一次性的本地 Kind 运行（在本地构建并加载四个应用镜像），执行：

```bash
make k8s-test
```

### 单节点功能测试

支持使用一个 Kubernetes node、一个 PostgreSQL 实例和一个 Redis 实例做功能、migration、readiness 和协议 smoke 测试。使用 `deploy/k8s/base` 或 production overlay 的单 Gateway 配置；不要使用 staging overlay，因为它的双 Gateway hostname spread 需要至少两个可调度 hostname。此档位不提供应用冗余、PDB 保证或节点故障后的容量承诺，也不能作为 HA 验收证据。

## 前置条件

- 支持 restricted Pod Security profile 的 Kubernetes。
- `kubectl` 与 Kustomize 5。
- production 或 staging 的应用 namespace 可访问的外部 PostgreSQL 与 Redis；`test` overlay 会在 namespace 内提供一次性数据服务。
- 从同一个 Git revision 构建的四个镜像：`gateway`、`admin`、`worker`、`migration`。

从干净的同一个 Git commit 构建并发布四个 Dockerfile target，形成一个 release set：

```bash
IMAGE_REPOSITORY="$REGISTRY/ghcp-pool-proxy" ./start.sh --push
IMAGE_REPOSITORY="$REGISTRY/ghcp-pool-proxy" ./start.sh --package
```

`--push` 会从同一个 Git SHA 构建并发布 `gateway-latest`、`admin-latest`、`worker-latest`、`migration-latest`，随后写入记录 schema 和四个 registry digest 的 `release-manifest.env`。`--package` 会把该 manifest、本 Kustomize 目录、Azure Bicep 基线和 `deploy/deploy-cluster.sh` 一并放入运行包。

运行包提供本地 Kind 与 Azure 基线的交互入口：

```bash
deploy/deploy-cluster.sh local
deploy/deploy-cluster.sh azure
```

Azure 向导会为 resource group、VNet/subnet、AKS、PostgreSQL Flexible Server 和 Azure Managed Redis 显式选择创建或复用。方括号默认值可直接回车采用；交互式复用会列出可见资源并支持编号选择，默认 `[1]`，输入 `0` 可手工填写；非交互复用必须显式设置环境变量。向导会在确认 apply 前执行 Bicep build 与 Azure what-if。新建 AKS 使用预授权到 node subnet 的 user-assigned control-plane identity；复用 AKS/PostgreSQL 必须匹配所选 subnet，复用 Redis 会获得本部署管理的 private endpoint/DNS attachment。Ingress、平台监控、备份恢复和 destroy 自动化仍由目标环境负责。

```bash
RELEASE_MANIFEST=/secure/path/release-manifest.env \
  deploy/k8s/apply.sh staging
```

Kustomize 源码保留易读的 `*-latest` tag。`apply.sh` 会先验证 release manifest schema 与仓库 migration target 一致，再把四个渲染后的 application/migration image 替换为 manifest digest 后 apply。production、staging 和 test 都使用这一流程；test 的数据服务 image 固定为 `postgres:16-alpine` 和 `redis:7-alpine`。production 的 `registry.invalid` 占位是 release manifest 的输入，不再需要人工修改文件。

## 中心化 Secret 来源

集群不支持为每个 Pod、节点或运维会话手工维护不同的敏感环境变量。所有 Gateway/Admin/Worker 必须从同一个 namespace 级、版本化的 Secret 来源启动，并在更新后一起 rollout。基线使用 Kubernetes Secret；Key Vault CSI 文件投射是可选的环境方案。先创建 namespace：

```bash
ENVIRONMENT=staging
NAMESPACE=ghcp-staging
kubectl apply -f "deploy/k8s/overlays/$ENVIRONMENT/namespace.yaml"
```

基线需要以下 Kubernetes Secret key。它可以由 External Secrets、Key Vault 同步器或其他受控 secret manager 写入，但不能由单个 Pod 的本地 env 覆盖：

| Secret / key | 消费方 | 用途 |
| --- | --- |
| `ghcp-runtime-secrets` / `ADMIN_TOKEN` | Gateway/Admin/Worker | Admin API 与 Gateway metrics token |
| `ghcp-runtime-secrets` / `POSTGRES_DSN` | Gateway/Admin/Worker | 不含 DDL 权限的运行账号 DSN |
| `ghcp-runtime-secrets` / `REDIS_PASSWORD` | Gateway/Admin/Worker | Redis 数据面密码 |
| `ghcp-runtime-secrets` / `CREDENTIAL_MASTER_KEY` | Gateway/Admin/Worker | 32 字节原值或 64 位十六进制凭据主密钥 |
| `ghcp-org-sync-worker-secrets` / `github-token` | 仅 `ghcp-org-sync-worker` | GitHub metrics/seat sync token |
| `ghcp-migration-postgres-dsn` / `postgres-dsn` | 仅 `ghcp-migrate` | 有 DDL 权限的 migration DSN |

选择 Key Vault CSI 时，应用已支持对应 `_FILE` 变量。把 [secret-provider-classes.yaml.example](keyvault/secret-provider-classes.yaml.example) 复制到受控的环境配置位置，替换 Key Vault 名称、tenant ID 和 Workload Identity client ID，再由环境 overlay 将 Secret volume/env 替换为 CSI file mount。不要同时设置同一值的 inline 与 `_FILE` 来源。

敏感值不进入 ConfigMap、镜像、Kustomize 参数、部署输出或日志。基线 Secret 更新不会修改已启动容器的 env，因此必须用完整 rollout 建立一致的启动版本；对于凭据主密钥轮换，先让新旧 key 在所有 Pod 同时可读，再切换写入版本。文件为空、缺失、格式错误或与 inline 同时设置时，应用 fail fast。

Redis endpoint 和拓扑不是密钥，作为环境专属 ConfigMap 值提供。以 `single` mode 为例，在受控 overlay 中合并以下非敏感 literals；不要把密码或 DSN 加入其中：

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

对于 `sentinel` 或 `cluster`，使用非敏感的 `REDIS_ADDRS`，完全省略 `REDIS_ADDR`；Cluster 保持 `REDIS_DB=0`。单节点功能测试可以使用同一 namespace 级测试 Secret；测试完成后销毁 namespace 和数据服务。

## Redis Protocol Cutover

Protocol v2 是 breaking 的 Redis key 和 Lua contract。不得同时运行 v1/v2 writer，也绝不能让 v1 writer 使用 `REDIS_CLIENT_MODE=cluster`。

1. 先运行 `make test-redis-cluster` 验证 client contract，再在既有 nonsharded Redis 上通过环境批准的 load check 验证 v2。
2. 停止入口、drain Gateway stream、停止 general 和组织同步 Worker，并等待已批准的最长 lease/request TTL。
3. 仅以 `REDIS_PROTOCOL_VERSION=2` 发布 Admin，port-forward 后提交带认证的维护操作：

```bash
kubectl -n "$NAMESPACE" port-forward service/ghcp-admin 8001:8001
curl --fail-with-body --oauth2-bearer "$ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"protocol":2,"writers_drained":true}' \
  http://127.0.0.1:8001/admin/redis/cutover
```

该操作会记录 source keyspace 的 count 与 SHA-256 audit 值、递增 durable epoch、写入经 digest 验证的 v2 manifest，并在恢复 ready 前从 PostgreSQL 重建 active binding cache 和当日 budget counter。它刻意不复制 sticky map、lease 或 pending reservation。

对于 `single|sentinel -> cluster`，先创建并验证 green Cluster，只把 Admin 改为 v2 Cluster 设置，再调用 `POST /admin/redis/reconcile`。该操作会建立另一个 epoch 并从 PostgreSQL 重建；禁止请求热路径双写或直接复制 Redis 数据。只有 Admin readiness 成功后才能发布 Gateway 与 Worker。回退到旧 endpoint 也必须是新的 reconcile/cutover，不能直接切 endpoint。

## 网络准备

可移植基线只允许应用访问 TCP 443、5432、6379，migration 只允许访问 5432。数据服务使用非默认端口时需要修改规则。

生产部署前，必须把 PostgreSQL 与 Redis 限制到已评审的 CIDR 或 selector，并通过选定的 CNI、egress gateway 或防火墙限制 HTTPS。可移植的 TCP 443 规则比生产 FQDN 白名单更宽。

Admin 只接受带管理标签 namespace 的入口；Worker metrics 只接受监控 namespace：

```bash
kubectl label namespace "$PRIVATE_INGRESS_NAMESPACE" \
  ghcp-pool-proxy.io/admin-access=true --overwrite
kubectl label namespace "$MONITORING_NAMESPACE" \
  ghcp-pool-proxy.io/monitoring=true --overwrite
```

Gateway 与 Admin Ingress 取决于环境，因此未随包提供。Gateway Ingress 必须关闭 SSE response buffering、覆盖请求体和 stream timeout，并且不能重放 `/v1/*` POST。Admin 必须保持私网访问。

## 部署

先渲染并审阅应用与 migration：

```bash
kustomize build "deploy/k8s/overlays/$ENVIRONMENT"
kustomize build "deploy/k8s/overlays/$ENVIRONMENT/migration"
```

发布脚本会强制 migration 先于应用执行，等待 Job 完成，再依次发布 Gateway、Admin、general Worker 和组织同步 Worker：

```bash
deploy/k8s/apply.sh "$ENVIRONMENT"
```

必要时设置 `KUBE_CONTEXT`、`MIGRATION_TIMEOUT` 或 `ROLLOUT_TIMEOUT`。不能把 migration Job 和应用 Deployment 作为无顺序的一组资源同时应用。

默认每个进程最多使用 12 个 PostgreSQL 连接。production 第 2 阶段最多需要 36 个应用连接；staging 双 Gateway 最多需要 48 个应用连接。两者都需再加 migration 与运维余量，并至少保留 20% 连接容量。

## 验证

在连接集群前，先运行本地清单门禁：

```bash
make k8s-validate
```

该检查会渲染 staging、production 与自包含 test overlay，并验证 production 保持单副本 `Recreate` 边界、staging 仅 Gateway 使用双副本滚动更新、PDB、hostname topology spread、test overlay 包含单 PostgreSQL 与单 Redis workload，以及 migration target、lock timeout 与仓库契约一致。它不替代已批准 staging 集群中的跨 Pod 请求、SSE drain 和节点驱逐验收。

双 hostname 的 staging 拓扑固定使用 `maxUnavailable: 1` 和 `maxSurge: 0`。增加 surge Pod 会形成 `2:1` 的 hostname 分布，违反严格的 `maxSkew: 1` spread 规则并卡住 rollout；PDB 仍会在替代 Pod 调度到被腾出的 hostname 前保留一个 ready Gateway。migration lock timeout 使用 Go duration 格式的 `5m`，`5min` 无效。

阶段 3 已在隔离的三节点 Kind 集群中配合外部 PostgreSQL 和 Redis 演练：目标 Gateway 终止时其活跃 SSE 收到 `[DONE]`，显式 Gateway rollout restart 完成，标准节点 drain 通过 PDB 驱逐一个 Gateway 后 Service 仍可完成 SSE，解除 cordon 后两个 Gateway 重新跨 hostname 分布。阶段 4 在同一拓扑的空数据库上完成验证：合并 migration 创建 schema `19`，四个 Deployment 全部 ready，GitHub token volume 只出现在 `ghcp-org-sync-worker`，Admin queue 请求会合并、可查询状态且拒绝请求级 token。每个已批准的目标 staging 环境仍必须重复适用检查；这份本地证据不代表云环境验收。

阶段 5 已通过 `make test-redis-cluster` 在一次性的三 primary + 三 replica Redis Cluster 验证 v2 Store contract；覆盖 Cluster slot coverage、按 primary inventory、budget reservation/finalization、account binding/concurrency、sticky cleanup、预算 slot primary 暂停后的 fail-closed/recovery，以及 `{budget}` 500/1000 RPS load。最终本机运行的 p95 分别为 `0.537 ms` 与 `0.689 ms`，门槛为 `50 ms`。`make k8s-test`（也保留为 `make test-phase5-single-node`）会创建一次性单节点 Kind，并部署含集群内 PostgreSQL、Redis 与中心测试 Secret 的 `test` overlay，验证 migration、四个 Deployment ready、`/readyz` 和 fake provider 三协议 smoke；脚本结束会删除集群。集群 Secret 必须使用同一 revision 或可选 Key Vault CSI source，不能按 Pod/节点分别维护本地环境变量。

```bash
kubectl -n "$NAMESPACE" get pods,services
kubectl -n "$NAMESPACE" get job ghcp-migrate
kubectl -n "$NAMESPACE" rollout status deployment/ghcp-gateway
kubectl -n "$NAMESPACE" rollout status deployment/ghcp-admin
kubectl -n "$NAMESPACE" rollout status deployment/ghcp-worker
kubectl -n "$NAMESPACE" rollout status deployment/ghcp-org-sync-worker
```

Port-forward 各 Service 并检查 readiness：

```bash
kubectl -n "$NAMESPACE" port-forward service/ghcp-gateway 8000:8000
curl -fsS http://127.0.0.1:8000/readyz
curl -fsS --oauth2-bearer "$ADMIN_TOKEN" http://127.0.0.1:8000/metrics
```

Admin 使用 `8001`，Worker 使用 `8002`。随后应使用已配置的 staging Client 运行 `scripts/gateway_smoke.sh`，验证三种协议等价行为。

安装 Prometheus Operator 后，`apply.sh` 会创建 Gateway 与 Worker ServiceMonitor。基线 Gateway scrape 从 `ghcp-runtime-secrets` 读取 bearer token；生产可改为独立 scrape token 或 Key Vault CSI/mTLS 方案，但不得由每个 collector Pod 手工维护不同 token。

## 回滚

- 只能回滚到兼容当前 schema 的镜像。
- Migration 默认 roll forward，不自动执行未知 down migration。
- 发布失败时保留 migration 日志和 rollout 状态。
- 恢复期间不重放已中断的模型 POST。
