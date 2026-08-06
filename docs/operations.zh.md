# 运维说明

本文档覆盖已交付的单机部署、多进程共享状态、启动、迁移、监控、告警和常见故障处理。

## 目录

- [运行拓扑](#运行拓扑)
- [VM 部署](#vm-部署)
- [主要配置](#主要配置)
- [多账号环境隔离](#多账号环境隔离)
- [Dashboard 与 Admin 鉴权](#dashboard-与-admin-鉴权)
- [发布与迁移](#发布与迁移)
- [日常检查](#日常检查)
- [Gateway 错误映射](#gateway-错误映射)
- [用量、费用与 Cache 观测](#用量费用与-cache-观测)
- [运维流程](#运维流程)
- [告警优先级](#告警优先级)
- [常见故障](#常见故障)
- [回滚原则](#回滚原则)

## 运行拓扑

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

## VM 部署

推荐使用发布包中的 `deploy/deploy.sh` 在 Linux VM 上部署。脚本使用固定 Docker Hub 镜像，不包含源码构建、测试或 smoke test 流程。

```bash
deploy/deploy.sh --start
```

启动流程：

- 检查 Linux、Docker、Docker Compose、`curl` 等依赖。
- 在宿主机创建默认持久化目录 `~/ghcp_proxy`，并把 PostgreSQL/Redis 数据目录作为 bind mount 挂入容器。
- 首次启动自动生成 `~/ghcp_proxy/config.yaml` 和 `~/ghcp_proxy/.env`；也可提前通过 `generate-config` 创建 YAML。两者都不会覆盖已有文件。
- 已有持久化目录中 YAML 缺失时会停止启动，避免静默恢复默认配置。
- 拉取 `pczhao1210/ghcp-pool-proxy:gateway-latest`、`admin-latest`、`worker-latest` 以及 PostgreSQL/Redis 镜像。
- 启动 PostgreSQL 和 Redis，等待健康检查通过。
- 读取发布包或已发布 admin 镜像内的 `migrations/schema_version` 和 `migrations/001_init.sql`。空库直接应用单一 init schema；已有库读取 DB 内 `system_settings.schema_version`，只在脚本内置了平滑升级路径时自动升级。
- 启动 gateway、admin 和 worker。
- 启动日志采集器，把 compose 日志按小时写入 `~/ghcp_proxy/logs/ghcp-proxy-YYYYMMDD-HH.log`，默认保留 30 天。

查看日志：

```bash
deploy/deploy.sh --logs
```

停止服务但保留持久化数据：

```bash
deploy/deploy.sh --stop
```

重置 VM 数据库和 Redis 数据但保留 `.env` 与 `config.yaml`：

```bash
GHCP_RESET_CONFIRM=reset deploy/deploy.sh --reset
deploy/deploy.sh --start
```

本地开发环境使用 `./start.sh --reset`，它会执行 Docker Compose volume reset 后按当前 `migrations/001_init.sql` 重建数据库。

源码树验证可使用 `./start.sh --new`。它默认运行 Go 测试，除非显式传入 `--skip-tests`，随后重建应用镜像、重建 gateway/admin/worker 容器并执行 HTTP smoke check。smoke client profile 有具体 `pool_id`：`PROVIDER=fake` 时指向本地 seed 的 smoke pool；`PROVIDER=copilot` 时优先指向第一个 active shared pool。smoke payload 会带稳定的 `user` 和 `session` 标识，便于定位 binding pool 错误。

VM Docker 持久化：

- PostgreSQL 数据默认保存在 `~/ghcp_proxy/data/postgres`。
- Redis AOF 数据默认保存在 `~/ghcp_proxy/data/redis`。
- 日志默认保存在 `~/ghcp_proxy/logs`，按小时分段，`LOG_RETENTION_DAYS` 默认值为 `30`。
- 日志会占用两处磁盘：VM Compose 的 Docker `json-file` 每容器最多约 `50 MB × 3`（五个服务合计约 750 MB），小时日志采集器还会把同一批服务输出复制到 `~/ghcp_proxy/logs`，按 30 天清理但没有字节上限。源码开发 Compose 依赖 Docker daemon 默认值，本身没有配置轮转上限。
- 部署密钥和端口配置保存在 `~/ghcp_proxy/.env`。已有凭据数据后不要随意替换 `CREDENTIAL_MASTER_KEY`。
- `~/ghcp_proxy/.env` 会写入当前发布包的 `SCHEMA_VERSION`，便于运维确认目标 schema 版本；数据库实际已安装版本记录在 `system_settings.schema_version`。
- 以上路径都是宿主机路径；PostgreSQL 和 Redis 通过 Docker Compose bind mount 使用这些目录，不是在镜像内部创建持久化目录。

### 100 账号单机规格

当前账号表、Admin API 和 Dashboard 没有账号总数硬上限，100 个账号不需要扩大数据库字段或解除批量限制。账号记录本身占用很小；容量应按同时活跃的模型请求和 SSE 流估算，而不是按已录入账号数估算。默认账号并发为 `6`，100 个账号理论上可以产生 600 条活跃请求，但这不是建议的单机工作点。

RPM 默认值按 100 个账号配置为单账号 `60`、全局 `6000`。全局值是防止内部限流过早拦截的容量上限，不代表单机能够持续处理 100 RPS。当前不提供 TPM 分钟限流；Daily token 和 AI Credits 预算仍默认关闭，可按需单独启用。

以下规格假设 PostgreSQL、Redis、gateway、admin 和 worker 都运行在同一台 VM，流量形态为交互式编程而非持续批处理。它们是压测前的起始建议，不是未经实测的吞吐保证。

| 场景 | vCPU / RAM | 持久化数据盘 | 适用范围 |
| --- | --- | --- | --- |
| 轻载 | `2 vCPU / 4 GiB` | `20 GB SSD / 2000 IOPS` | 开发、试运行或通常不超过约 20 条活跃请求；资源余量和数据保留空间较小 |
| 100 账号推荐基线 | `4 vCPU / 8 GiB` | `128–256 GiB / 3000 IOPS` | 约 20–80 条活跃请求、常见交互式编程流量、单机共置数据库 |
| 100 RPS 验证规格 | `16 vCPU / 32 GiB` | `256–512 GiB / 3000 IOPS` | 仅在目标负载延迟压测通过时使用；ledger 批量写、增量 rollup、分区保留和日志采样均保持启用 |
| I/O 受限规格 | `16–32 vCPU / 32–64 GiB` | `>=5000 IOPS` | 仅在实测持续触发磁盘队列或延迟告警时使用；磁盘容量不能替代写路径检查 |

Azure 上推荐把 PostgreSQL、Redis AOF 和应用日志放到独立数据盘，不与 OS 盘争用。Premium SSD v2 的基线为 `3000 IOPS / 125 MB/s`，容量与性能可分别配置，因此应先在该基线内验证 100 RPS 规格，而不是假定需要 `8000–12000 IOPS`。若使用容量绑定性能的 Premium SSD v1，P20 为 `512 GiB / 2300 IOPS / 150 MB/s`，P30 为 `1 TiB / 5000 IOPS / 200 MB/s`；根据磁盘延迟和队列深度实测选择档位。还需确认所选 VM 的总数据盘 IOPS/吞吐上限不低于磁盘配置。

目标是在稳定压测中让磁盘 IOPS 持续低于配额的 60–70%，并同时满足 PostgreSQL commit latency p95 `<5 ms`、磁盘队列无持续增长。若 3000 IOPS 下无法满足这些指标，应先确认 ledger 是否已批量写入、rollup 是否仍重复扫描和成功日志是否已采样，再考虑提高磁盘档位。生产环境还应预留快照、WAL 和备份空间，不能把整块数据盘都分配给 PostgreSQL。

主要瓶颈及扩展顺序：

1. **磁盘容量和写延迟**：Gateway 通过有界队列和 PostgreSQL `COPY` 批量写 `usage_ledger`，PostgreSQL 仍会产生数据页和 WAL；Redis 使用 AOF `everysec`，Docker JSON 日志和按小时收集的日志也会占盘。Worker 默认保留 7 天 UTC 日分区 raw 数据、90 天 UTC 日分区 hourly rollup，以及当前月加之前 13 个完整自然月的 monthly-partitioned daily rollup；清理只 `DROP` 完整分区。20 GB 仍缺少 WAL、快照和故障恢复余量，应扩到至少 128–256 GiB，并为磁盘使用率设置 70% 告警。持续 100 RPS 的优化目标是压测后稳定运行在 3000 IOPS 基线内，不是未经实测的吞吐承诺。
2. **RAM**：4 GiB 需要同时容纳宿主机、五个容器、PostgreSQL cache、Redis 数据、连接 buffer 和请求体。长会话、并发流和 Dashboard 聚合会增加峰值。常驻内存持续超过 75%、开始使用 swap 或出现 OOM 时升到 16 GiB；不要依赖 swap 承载正常流量。
3. **CPU**：账号数量本身几乎不消耗 CPU；JSON 协议转换、SSE 事件转发、日志、数据库查询和后台 rollup 随请求/事件速率增长。2 核容易让 gateway 与 PostgreSQL/worker 相互争抢。CPU 持续超过 70% 或 run queue 持续高于 vCPU 数时，从 4 核升到 8 核，或把数据服务迁出 VM。
4. **Redis/PostgreSQL 往返与连接**：一次模型请求会经过多次 Redis 路由、并发、sticky/binding 操作；usage 先进入 Gateway 的有界内存队列，积压达到 100 条时立即组批、单批最多 500 条，否则最多等待 250 ms 后 `COPY`。gateway、admin、worker 默认各自最多打开 25 个 PostgreSQL 连接，单机理论合计 75 个；连接获取等待或数据库延迟升高时，优先检查慢查询、队列丢弃、连接池和存储延迟，不能只继续提高 RPM。
5. **长连接和网络**：SSE 大部分时间不消耗整核 CPU，但会长期占用 socket、内存和账号并发。Copilot HTTP transport 单主机默认最多 256 个连接，所以 600 个账号并发槽不能全部由一个 gateway 进程同时兑现。接近 200 条活跃流时应压测文件描述符、网络带宽和连接上限；继续增长时优先拆分 gateway 与 PostgreSQL/Redis，随后水平扩展 gateway。

建议按以下顺序扩展：先把当前 VM 升到 4C8G 并扩盘，观察至少一个工作周；若瓶颈集中在数据库写延迟，先迁移 PostgreSQL 到独立 SSD 或托管实例；若 CPU、活跃 SSE 或单主机连接数成为瓶颈，再增加 gateway 实例。增加 gateway 实例不会增加账号侧容量，且所有实例必须共享 PostgreSQL 和 Redis。

## 主要配置

配置分为两类权威来源。本地源码部署使用 `start.sh` 创建且被 Git 忽略的仓库 `config.yaml`；VM 部署使用 `deploy.sh generate-config` 创建的 `~/ghcp_proxy/config.yaml`。Provider/OAuth 端点、超时、连接池与队列容量和日志是 YAML 启动配置，Dashboard 只读展示 effective value，修改后必须重启。部署密钥、宿主机路径、端口、监听地址以及 PostgreSQL/Redis 地址保存在 `~/ghcp_proxy/.env`。自定义部署遵循“环境变量 > YAML > 内置默认值”；VM Compose 从 `.env` 注入部署值，并从 YAML 读取应用启动配置。

预算、Feature Flags、模型目录、Gateway Public URL、Client/GitHub fallback key 和 usage retention 存在 PostgreSQL，可在 Dashboard 热更新。Retention 的优先级为 DB 覆盖值高于 YAML/环境变量启动 fallback，再高于内置默认值。Worker 会在每次 maintenance pass 前刷新 retention，当前周期为 5 分钟，无需重启。缩短非零窗口可能永久删除更老的完整分区；设为 `0` 表示关闭该层清理。

推荐开启的 Copilot 兼容开关是 `copilot_compat_anthropic_beta_enabled`、`copilot_compat_thinking_tool_choice_enabled`、`copilot_compat_cache_control_enabled` 和 `copilot_compat_vision_header_enabled`。Migration 015 会把四项都写为 `true`；Gateway 对缺失/读取失败也按开启处理，并把结果缓存最多 60 秒。这些开关只控制已审查的请求兼容规则，不选择上游 wire protocol。Anthropic 模型默认走原生 Messages；要回滚某个模型，可设置 `upstream_api=chat_completions`。

| Variable / Setting | 说明 |
| --- | --- |
| `GATEWAY_ADDR` | gateway 监听地址 |
| `gateway.read_timeout` | 读取完整请求的最长时间，默认 `30s` |
| `gateway.read_header_timeout` | 读取请求头的最长时间，默认 `5s` |
| `gateway.write_timeout` | 整体响应写入超时；默认 `0s`，允许长时间 SSE 流 |
| `gateway.idle_timeout` | keep-alive 空闲超时，默认 `120s` |
| `WORKER_METRICS_ADDR` | Worker 健康检查和 retention 指标监听地址，默认 `:8002`；VM Compose 仅映射到宿主机 `127.0.0.1` |
| `ADMIN_ADDR` | admin 监听地址 |
| `ADMIN_TOKEN` | admin API 鉴权 token |
| `POSTGRES_DSN` | PostgreSQL 连接串 |
| `REDIS_ADDR` | Redis 地址 |
| `SCHEMA_VERSION` | 当前发布包目标 schema 版本；由 `deploy.sh` 写入 `.env`，DB 已安装版本以 `system_settings.schema_version` 为准 |
| `maintenance.raw_retention_days` | raw ledger 日分区保留 fallback，默认 `7`；设为 `0` 关闭自动清理 |
| `maintenance.hourly_retention_days` | hourly rollup UTC 日分区保留 fallback，默认 `90`；设为 `0` 关闭自动清理 |
| `maintenance.daily_retention_months` | daily rollup 完整自然月保留 fallback，默认 `13`，另保留当前月；设为 `0` 关闭自动清理 |
| `maintenance.partition_ahead_days` | Worker 提前创建 ledger 日分区的天数，默认 `7` |
| `usage_writer.queue_size` | Gateway usage 内存队列容量，默认 `10000` |
| `usage_writer.batch_size` | 单次 COPY 最大记录数，默认 `500` |
| `usage_writer.flush_threshold` | 突发积压达到该数量时立即组批，默认 `100`，不会超过 batch size |
| `usage_writer.flush_interval` | 未达到 threshold 时的最长等待，默认 `250ms`；`100ms` 仅作为低延迟压测 profile |
| `usage_writer.enqueue_timeout` | 队列满时单次入队最长等待，默认 `50ms` |
| `usage_writer.write_timeout` | 单次 COPY 写入超时，默认 `5s` |
| `logging.success_sample_rate` | 成功 access log 采样率，默认 `0.01`；错误请求始终记录 |
| `provider.type` | 上游 provider 类型，VM 部署默认 `copilot` |
| `provider.base_url` / `provider.timeout` | 可选 Copilot 端点覆盖与上游超时 |
| `postgres_pool.max_open_connections` | 每个应用进程最大 PostgreSQL 连接数，默认 `25` |
| `CREDENTIAL_MASTER_KEY` | 凭据加密主密钥 |
| `github.oauth_client_id` | Dashboard Device Flow 登录 Copilot 账号的 GitHub OAuth App client ID，可选覆盖项；默认使用内置 GitHub OAuth Client ID。 |
| `github.oauth_scopes` | Device Flow scopes，默认 `read:user` |
| `github.login_base_url` | GitHub 登录域名，默认 `https://github.com` |
| `github.api_base_url` | GitHub API 域名，默认 `https://api.github.com` |
| `github.copilot_token_url` | Copilot bearer token 换取端点 |
| `GITHUB_TOKEN` | worker 同步 GitHub Copilot Metrics 的 fallback token |
| `DASHBOARD_DIR` | admin 服务 Dashboard 静态资源目录 |
| `model_catalog_json` | 控制暴露名、上游模型 ID、上游 API 和启停状态 |
| `logging.level` / `logging.format` | 日志级别和格式 |

## 多账号环境隔离

当前实现把 GitHub Copilot 账号隔离在账号、凭据、池和热状态四个层面。

```mermaid
flowchart TD
  Client["Client API Key"] --> Profile["Client Profile"]
  Profile -->|"必填 pool_id"| Pool["Backend Pool"]
  Pool --> AccountA["GitHub Account A"]
  Pool --> AccountB["GitHub Account B"]
  AccountA --> CredA[(Encrypted Credential A)]
  AccountB --> CredB[(Encrypted Credential B)]
  AccountA --> CacheA["Token Cache account_id=A"]
  AccountB --> CacheB["Token Cache account_id=B"]
  Pool --> Sticky["Redis Sticky Map pool/model/format/affinity"]
```

- 每个账号是一条独立 `accounts` 记录，凭据通过 `credentials.account_id` 绑定，不使用全局 Copilot token。
- Device Flow 完成后保存的是该账号自己的 GitHub OAuth token 和 Copilot bearer token，加密 payload 只挂在该账号下。
- Gateway 在请求前从 router selection 取 `account_id`，再按该 `account_id` 读取和缓存 token。
- pool membership 使用 `pool_accounts` 管理；每个账号最多属于一个 pool，每个 client profile 必须指向一个 pool。
- Redis sticky key 包含 pool、model、request format 和 affinity hash，sticky 只影响同一 scope 下的账号复用。
- 组织/企业 seat 账号应填写 `account_source`、`org_id`、`seat_status`，router 会过滤不可用 seat。
- 路由数据不包含账号级模型权限。同一 pool 必须使用具备相同可用模型集合的账号。

如果同一 pool 内模型权限不同，Router 可能选中无法使用目标模型的账号。Provider 请求随后失败，不会换另一个账号重试。Copilot `403` 会分类为 `permission_denied`，并可能增加该账号的 risk。

建议隔离做法

1. 按租户、用途、风险等级和模型权限拆 pool，例如 `team-a-copilot`、`team-b-copilot`、`sandbox-copilot`。
2. 每个 GitHub 账号单独 Device Flow 登录，不复用任何手工 token。
3. 给每个 client profile 分配具体 pool，避免意外共享其它团队的账号。
4. 对 Business/Enterprise seat 定期同步 seat 状态，失效账号进入 `quarantined` 或 `revoked`。
5. 生产环境使用独立 `CREDENTIAL_MASTER_KEY`，不要使用 compose 默认开发 key。

## Dashboard 与 Admin 鉴权

- Dashboard 静态页面由 admin 服务根路径提供，默认访问 `http://localhost:8001/`。
- `/admin/*` API 统一要求 `Authorization: Bearer <ADMIN_TOKEN>`。
- Dashboard 会把管理员 token 附加到 API 请求；静态页面本身不应承载敏感数据。
- 容器镜像中 Dashboard dist 会复制到 `/srv/dashboard`，也可通过 `DASHBOARD_DIR` 指向自定义构建产物。

## 发布与迁移

```mermaid
flowchart TD
  A["准备配置"] --> B["执行数据库迁移"]
  B --> C["部署 gateway"]
  B --> D["部署 admin"]
  B --> E["部署 worker"]
  C --> F["检查 /healthz 和 /readyz"]
  D --> G["检查 Dashboard 和 admin API"]
  E --> H["检查探针与同步任务"]
```

- 迁移顺序应先数据库后服务。
- 变更 pool membership、client profile 和预算阈值应优先通过 admin 完成。
- 多实例部署时，Redis 和 PostgreSQL 必须先于服务可用。Redis 初始 ping 或后续命令失败时，readiness 返回 `503`；预算和分布式并发检查 fail-closed，sticky 亲和与绑定缓存则回退到普通路由或 PostgreSQL。保留的 Redis client 会在依赖恢复后自动恢复正常操作。
- 当前 schema contract 中，`backend_pools.allocation_mode` 允许 `shared`、`user_binding`、`session_binding`；user binding 使用 `user_id_*` 列，session binding 使用独立的 `account_session_bindings` 表。

## 日常检查

| Check | 说明 |
| --- | --- |
| `GET /healthz` | 存活检查 |
| `GET /readyz` | 就绪检查 |
| `GET /metrics` | 携带 `Authorization: Bearer <ADMIN_TOKEN>` 的 Gateway 指标检查 |
| Dashboard | 查看账号状态、池状态、错误事件、用量、费用、cache 命中率和同步状态 |

## Gateway 错误映射

客户端按标准 AI 网关语义接收 `external_status`、`external_code` 和中性 `external_message`。Gateway 日志事件 `gateway error mapped` 保留内部排障字段：`internal_status`、`internal_code`、`internal_message`、`external_status`、`external_code`、`external_message`，并在可用时附带 `model`、`account_id`、`pool_id`、`redis_rebind_reason` 等上下文。

| Internal status / code | 内部场景 | External status / code | External message | 运维说明 |
| --- | --- | --- | --- | --- |
| `413 invalid_request_error` | JSON 请求体超过 `32 MiB` | `413 invalid_request_error` | 请求体上限提示 | 缩小内嵌图片、tool payload 或会话历史后重试 |
| `503 no_available_accounts` / `503 user_binding_exhausted` / `503 session_binding_exhausted` | 路由候选为空、账号并发耗尽、绑定池无可分配容量 | `429 rate_limited` | `rate limit exceeded; please retry later` | 看 `internal_message`、`account_id`、`pool_id` 区分容量、绑定或并发原因 |
| `503 route_unavailable` / `503 client_pool_not_configured` | Client 指定 pool 缺失、非 active 或不可用 | `503 service_unavailable` | `model route unavailable` 或 Client-Pool 配置提示 | 检查 client profile `pool_id`、pool 状态和模型目录 |
| `400 missing_user_id` / `400 invalid_user_id` | user-binding pool 缺少或传入非法 `user_id` | `400 invalid_request_error` | `user identifier is required` / `user identifier is invalid` | 优先传 OpenAI `user` 或 Anthropic `metadata.user_id` / `metadata.user` |
| `400 missing_session_id` / `400 invalid_session_id` | session-binding pool 缺少或传入非法 `session_id` | `400 invalid_request_error` | `session identifier is required` / `session identifier is invalid` | 优先传 `metadata.session_id` / `metadata.session`，或 header `X-GHCP-Session-ID` |
| `503 user_binding_unavailable` / `503 session_binding_unavailable` | 绑定依赖 PostgreSQL 或缓存访问失败 | `503 service_unavailable` | `service temporarily unavailable` | 检查 PostgreSQL、Redis 和绑定表状态 |
| `503 budget_unavailable` | 限流或预算状态不可读 | `503 service_unavailable` | `gateway limit state unavailable` | 检查 budget checker、Redis/PostgreSQL 和配置同步 |
| `429 global_rate_limited` / `429 account_rate_limited` | 全局或内部资源级 RPM 命中 | `429 rate_limited` | `rate limit exceeded; please retry later` | 对外不暴露资源层级；日志保留 global/account 粒度 |
| `429 global_budget_exhausted` / `429 account_budget_exhausted` | 全局或内部资源级 token / AI Credits 日预算耗尽 | `429 budget_exhausted` | `quota exceeded` | 对外按标准配额耗尽处理；日志保留预算层级 |
| `502 upstream_error` | 上游模型提供方错误 | `502 upstream_error` | `model provider error` | 内部日志和 usage ledger 保留原始错误分类 |
| `500 stream_error` | SSE writer 或流式响应初始化失败 | `500 stream_error` | `stream response unavailable` | 检查响应写出、代理和客户端连接状态 |
| 未显式映射的 internal code | 其它走映射函数的错误 | 与 internal 相同 | 与 internal 相同 | 默认透传；新增错误类型时应评估是否需要中性化 |

上游 Copilot 4xx 响应会先分类，再决定是否影响账号健康。认证、权限、限流、配额、网络和 5xx 失败仍可能增加 risk；`invalid_request` 和通用 `upstream_4xx` 会记录到指标和 usage，但不会增加账号 risk，因为它们通常来自请求形态、模型兼容性或客户端参数，而不是账号健康问题。模型权限拒绝可能表现为 `403 permission_denied`；Gateway 会把它记录到被选账号且不会换号。流式请求中，上游 SSE 读取错误，或在完成标记前提前 EOF，都会按失败请求处理，不能伪装成成功的 `[DONE]` 结束事件。客户端取消会中断阻塞的流事件发送、关闭上游响应，并释放本地和 Redis 并发占用。对于上游 Responses API 流，如果 EOF 前已经收到 `response.output_text.done` 或 `response.output_item.done` 这类终止输出事件，则按完成处理，以兼容省略 `response.completed` 的模型变体。

如果客户端收到 `budget_exhausted`，先看 gateway 日志里的 `internal_code`、`account_id` 和 `pool_id`，再检查 Redis 计数，例如 `budget:daily:account:<account_id>:<yyyymmdd>` 和 `budget:daily:global:<yyyymmdd>`。Daily token 和 AI Credits 上限只有在 Dashboard Config 值或对应 `BUDGET_MAX_DAILY_*` 环境变量大于 `0` 时才会启用。

## 用量、费用与 Cache 观测

Gateway 在请求完成后把 proxy-side usage 放入有界队列，按最多 500 条或 250 ms 使用 PostgreSQL `COPY` 写入按日分区的 `usage_ledger`。真实 Copilot provider 会解析上游响应中的 `usage` 和 `copilot_usage`，记录 input、cached input、cache write、output、reasoning tokens、`nano_aiu`、估算 AI Credits 和估算 USD。

Dashboard Metrics 页按窗口展示以下关键指标：

| 指标 | 运维用途 |
| --- | --- |
| AI Credits / Estimated USD | 估算当前窗口的 Copilot usage-based billing 消耗 |
| Cache Hit Rate | 观察 sticky/cache affinity 是否带来 cache read 命中 |
| Cached Input / Cache Write | 区分 cache read 收益和 cache 写入成本 |
| Reasoning Tokens | 识别 reasoning 模型或高推理请求的成本来源 |
| Token Details | 通过 ledger 中的 `token_details` 保留上游 token type、count 和 batch cost |

Prometheus 文本指标中也包含 cached/cache read tokens、cache write tokens、reasoning tokens、nano AIU、AI Credits micro、estimated USD micros 和 cache hit ratio permille。若 cache hit rate 持续偏低，应检查 client profile sticky policy、affinity strategy、session header 以及 rebind/overflow 指标。

验证 3000 IOPS 目标时，还应同时观察 Gateway 的 usage 写队列：

| 指标 | 判定 |
| --- | --- |
| `ghcp_usage_queue_depth` / `ghcp_usage_queue_capacity` | 深度不应持续增长或长期接近容量 `10000` |
| `ghcp_usage_queue_rejected_total{reason="full"}` | 稳态压测应保持 `0`；增长表示数据库吞吐已经落后于请求速率 |
| `ghcp_usage_records_dropped_total` | 所有 reason 均应为 `0`；包含入队失败和关闭 drain 超时造成的明确丢弃 |
| `ghcp_usage_batches_total{status="error"}` | 应保持 `0`；增长表示 COPY 超时或数据库写失败 |
| `ghcp_usage_batch_duration_count` / `ghcp_usage_batch_duration_microseconds_total` / `ghcp_usage_batch_duration_microseconds_max` | 用于观察 COPY 次数、平均值和最坏值；持续抬升时关联 PostgreSQL commit latency 与磁盘队列 |
| `ghcp_usage_queue_oldest_age_milliseconds` / `ghcp_usage_queue_residence_microseconds_max` | 不应跨多个 flush 周期持续增长 |
| `ghcp_usage_batch_retries_total` / `ghcp_usage_batch_consecutive_failures` | 稳态应无增长且连续失败为 `0` |
| `ghcp_usage_batch_last_success_timestamp` | 应持续更新，避免“队列看似较浅但写入已停止” |
| `ghcp_usage_last_batch_size` | 100 RPS 稳态通常约为每 250 ms 数十条；突发时最多 `500` |
| `ghcp_usage_records_written_total` | 应与完成并需要记账的请求数持续对齐 |
| `ghcp_usage_partitions_dropped_total{granularity="raw|hourly|daily"}` | 到期时按完整分区增长，不应出现大范围 DELETE |
| `ghcp_usage_retention_errors_total` / `ghcp_usage_retention_last_success_timestamp` | retention error 应为 `0`，最近成功时间应每约 5 分钟推进 |

Retention 指标从 Worker 的 `http://127.0.0.1:8002/metrics` 抓取；Usage Writer 和 Copilot Transport 指标仍从 Gateway `/metrics` 抓取，并需携带 `Authorization: Bearer <ADMIN_TOKEN>`。Copilot Transport 指标用于判断是否真的需要提高当前每主机 `256` 个连接上限：

| 指标 | 判定 |
| --- | --- |
| `ghcp_copilot_http_responses_total{protocol="h2"}` | 正常生产流量应以 HTTP/2 为主；同时观察 `http/1.1` 降级比例 |
| `ghcp_copilot_connection_wait_milliseconds_bucket` | 由 histogram 计算 GetConn p95；持续等待才说明连接池可能饱和 |
| `ghcp_copilot_connections_acquired_total{reused,was_idle}` | 用于计算连接复用率和 idle reuse 比例 |
| `ghcp_copilot_open_tcp_connections` | 接近 `256` 且 connection wait 同时升高时才考虑扩容连接上限 |
| `ghcp_copilot_active_requests{kind}` / `ghcp_copilot_active_streams` | 区分普通请求和长期 SSE 流占用 |
| `ghcp_copilot_dial_duration_*` / `ghcp_copilot_tls_handshake_duration_*` | 区分连接池等待、TCP 建连和 TLS 握手问题 |
| `ghcp_copilot_tls_negotiated_total{protocol}` | 验证 TLS ALPN 是否协商为 `h2` |

只有当上述队列指标健康、磁盘 IOPS 持续低于配额 60–70%、PostgreSQL commit latency p95 `<5 ms` 且磁盘队列不增长时，才能认为当前流量可稳定运行在 3000 IOPS。`ingested_at` 作为增量 rollup 水位，确保数据库短暂中断后晚到的队列记录仍会进入 hourly/daily 汇总。

查询粒度：

| Granularity | 说明 |
| --- | --- |
| `raw` | 查询兼容视图 `usage_ledger_all`，精确到每次请求，适合默认 7 天保留窗口内的短时间范围 |
| `hourly` | 查询 UTC 日分区的 `usage_rollup_hourly`，默认保留 90 天，适合中期趋势和多天查询 |
| `daily` | 查询 UTC 月分区的 `usage_rollup_daily`，默认保留当前月和之前 13 个完整自然月，适合长期趋势和账务对账 |
| `auto` | 1h 内使用 raw，90 天内使用 hourly，超过 90 天使用 daily；默认 24h Dashboard 不扫描整日 raw ledger |

Admin API 支持绝对日期范围：`/admin/usage/summary?from=2026-06-01&to=2026-06-23&granularity=auto`。日期格式的 `to` 会按闭开区间处理为下一天 00:00 UTC，因此 `to=2026-06-23` 会包含 6 月 23 日整天。Usage Rollup Worker 每 5 分钟处理到 `now()-2m`，避免刚写入的请求产生边界抖动；raw 清理使用 `min(now-retention, rollup watermark)` 作为安全边界，hourly/daily 则只删除完整 UTC 日/月分区。`usage_ledger_all` 兼容视图暴露当前 schema 中的全部 raw ledger 存储；辅助非分区存储只有在完整保留窗口过期后才会清空。

Retention 可在 Dashboard Config 中直接修改，无需重启。若新的非零值缩短当前窗口，界面会要求二次确认，因为下一轮 maintenance 执行后的分区删除不可恢复。

## 运维流程

### 1. 账号上线、分组与下线

```mermaid
stateDiagram-v2
  [*] --> pending
  pending --> active: 导入有效凭据 / import valid credential
  active --> degraded: 风险升高或短期失败 / elevated risk or short failures
  active --> revoked: 管理员下线 / admin offboarding
  degraded --> active: 上游回池探针成功 / successful upstream re-admission probe
  degraded --> recovery: 创建恢复任务 / create recovery task
  degraded --> quarantined: 风险继续升高 / risk continues rising
  degraded --> revoked: 管理员下线 / admin offboarding
  quarantined --> recovery: recover API
  quarantined --> revoked: 管理员下线 / admin offboarding
  recovery --> active: token 与上游探针均成功 / token and upstream probes succeed
  recovery --> degraded: degraded 来源发生暂时探针失败 / transient failure from degraded
  recovery --> quarantined: 凭据失败或隔离来源恢复失败 / credential or quarantined recovery failure
  revoked --> [*]
```

状态含义

| State | 说明 |
| --- | --- |
| `pending` | 创建账号后待验证 |
| `active` | 凭据有效，可用于路由 |
| `degraded` | 短期失败或风险上升，降权或限流 |
| `recovery` | 恢复任务处理中 |
| `quarantined` | 暂停路由，等待恢复或重新导入凭据 |
| `revoked` | 彻底下线，不再自动恢复 |

仅成功获取 token 不能证明账号可以运行模型。token probe 成功只会降低 risk，并可能让 degraded 账号具备回池资格；只有真实上游模型探针成功才会将账号改回 `active`。探针使用独立 Worker 路径，不消耗客户端 usage、budget、RPM、sticky affinity 或 binding。PostgreSQL claim 与 health version fencing 会拒绝旧结果，Redis 在多个 Worker 实例间执行全局并发和启动速率限制。限流等待只更新下次到期时间，不会每秒增加 attempt 或写 audit。

账号上线:

1. 在 Dashboard 或 Admin API 创建账号。
2. 使用 Device Flow 或手工凭据导入 GitHub Copilot 登录凭据。
3. Worker 进行首次 probe；成功后保持 `active`，失败则可能进入 `degraded` 或 `quarantined`。
4. 将账号加入一个 pool，完成可路由准备；移动操作会原子替换该 membership。

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
  A-->>D: 返回授权码和 GitHub URL / return code and URL
  D->>G: 管理员在 GitHub 页面授权 / operator authorizes on GitHub
  D->>A: POST /admin/accounts/{id}/device-flow/complete
  A->>G: Poll OAuth token
  G-->>A: GitHub access token
  A->>C: Exchange Copilot bearer token
  C-->>A: Copilot token / expires_at
  A->>P: 加密保存到 credentials.account_id / encrypt under credentials.account_id
```

API 示例

```bash
curl -s http://localhost:8001/admin/accounts/{account_id}/device-flow/start \
  -H "Authorization: Bearer dev-admin-token" \
  -X POST

curl -s http://localhost:8001/admin/accounts/{account_id}/device-flow/complete \
  -H "Authorization: Bearer dev-admin-token" \
  -H "Content-Type: application/json" \
  -d '{"device_code":"DEVICE_CODE_FROM_START"}'
```

如果 complete 返回 `202` 且 `error=authorization_pending`，表示用户还没有在 GitHub 页面完成授权；稍后再次调用 complete。若返回 `409 expired_token`，重新 start。

账号分组:

1. 创建 pool，并选择 allocation mode 与 load-balancing strategy。
2. 在 Pool 页添加或移动账号，确认最大并发、权重和 binding 状态；移动前先 Release active binding。
3. 给每个 Client 分配一个具体 pool。Sticky 只在该 pool 内生效，不能覆盖健康、预算和 seat 有效性。

账号下线:

1. 先将账号状态切到 `quarantined` 或 `revoked`，暂停新请求路由。
2. 清理 pool 关系和 sticky affinity，避免继续被选中。
3. 彻底删除时使用 `DELETE /admin/accounts/{id}` 级联删除凭据、pool 关系与 affinity 记录。
4. 临时下线可先进入 `quarantined`，待恢复后再切回 `active`。

恢复任务链路

```mermaid
flowchart TD
  A["管理员点击 Recover 或调用 Admin API"] --> B["创建 recovery_tasks 记录"]
  B --> C["账号状态进入 recovery"]
  C --> D["Worker 使用 lease claim 一条到期任务"]
  D --> E{"token 获取成功?"}
  E -->|"是"| F{"最小化上游模型探针成功?"}
  F -->|"是"| G["事务内重置 risk 并恢复 active"]
  E -->|"账号故障"| H["任务失败并恢复 degraded 或 quarantined"]
  F -->|"账号故障"| H
  E -->|"系统错误或限流"| I["释放 claim 并安排重试"]
  F -->|"系统错误或限流"| I
```

### 2. 模型 ID 映射、别名与隐藏模型

| 字段 | 说明 |
| --- | --- |
| `exposed` | 客户端看到的模型名 |
| `upstream` | 实际发往 GitHub Copilot 的上游模型 ID |
| `upstream_api` | 可选，上游 endpoint：`chat_completions`、`responses` 或 `anthropic_messages` |
| `name` | 可选，从 Copilot `/models` 刷新的显示名称 |
| `vendor` | 可选，从 Copilot `/models` 刷新的模型供应商；`OpenAI` 自动推导为 Responses，`Anthropic` 自动推导为 Messages |
| `enabled` | 是否暴露给 `/v1/models`，以及是否允许请求 |

GitHub Copilot 上游 endpoint 采用混合选择，不是全局默认 Responses。选择顺序是：模型目录中的 `upstream_api` 优先；然后归一化 Copilot `/models` 刷新的 `vendor`，其中 `OpenAI` / `Azure OpenAI` 走上游 Responses，Anthropic 走上游 Messages，Google、Microsoft、xAI 走上游 Chat Completions；如果 vendor 为空，再从 `upstream`、`name`、`exposed` 推断，`gpt*`/o-series 归 OpenAI，`gemini*` 归 Google，`claude*`/`opus*`/`haiku*`/`sonnet*` 归 Anthropic，`MAI*` 归 Microsoft，`grok*`/`xai*` 归 xAI；其他模型按下游请求协议选择。

该模型目录是全局配置，不校验每个账号的模型权限，因此 pool 必须按共同可用模型集合分组。

```mermaid
flowchart LR
  A["Dashboard Models / Settings"] --> B["PATCH /admin/settings/model_catalog_json"]
  B --> C[(system_settings)]
  C --> D["GET /v1/models"]
  C --> E["请求模型解析"]
  E --> F{"exposed 是否启用?"}
  F -->|"是"| G["映射到 upstream model + upstream_api"]
  F -->|"否"| H["400 invalid_model"]
```

示例配置

```json
[
  {"exposed":"gpt-4o","upstream":"gpt-4o","enabled":true},
  {"exposed":"claude-sonnet","upstream":"claude-sonnet-4-20250514","enabled":true},
  {"exposed":"o3","upstream":"o3-mini","enabled":false}
]
```

### 3. GitHub 登录令牌过期与刷新

GitHub Copilot 登录凭据存在过期和失效风险。PAT 可能有自定义过期时间，未使用超过 1 年的 token 也可能被 GitHub 自动清理；过期或撤销后通常在下次使用时返回 `401`。

- 检查 `credentials.expires_at` 是否即将到期。
- 对即将失效的 token 提前提醒管理员刷新或重新导入。
- 失效后先做账号降级，再用新 token 重新导入并恢复 `active`。

## 告警优先级

```mermaid
flowchart TD
  A["告警触发"] --> B{"影响请求可用性?"}
  B -->|"是"| C["优先处理 gateway、Redis、Postgres、active 账号"]
  B -->|"否"| D["处理同步延迟、指标偏离、配置问题"]
  C --> E{"涉及凭据或 seat 失效?"}
  E -->|"是"| F["账号恢复或摘除"]
  E -->|"否"| G["检查路由、并发和预算"]
```

| Priority | 说明 |
| --- | --- |
| High | active 账号不足、gateway 5xx、Redis P99 激增、Postgres 连接池耗尽、seat 失效 |
| Medium | sticky hit 率持续偏低、rebind/overflow 异常、Copilot Metrics 同步延迟 |
| Low | Dashboard 展示异常、非关键统计延迟 |

## 常见故障

### 账号不可路由

1. 检查账号是否仍为 `active`。
2. 检查并发是否达到上限。
3. 检查预算、risk score 和 seat 状态。
4. 检查 sticky target 是否需要重绑定。

### sticky 命中率偏低

1. 确认 client profile 是否启用了 sticky。
2. 检查 `sticky_session_header`、Claude Code/Codex session header 或派生 affinity key 是否稳定。
3. 检查 overflow 是否频繁触发。
4. 检查新增或摘除账号是否导致大量 affinity 迁移。

### Copilot Metrics 同步延迟

1. 检查 worker 是否存活。
2. 检查 `copilot_metrics_sync_enabled` 是否启用。
3. 检查 org access token 或 `GITHUB_TOKEN` 是否可用。
4. 检查 usage report 元数据请求和所有签名下载；无效或不完整的报告会被拒绝，不会覆盖最新快照。
5. 检查 Postgres 写入是否受阻。

Metrics 同步路径

```mermaid
flowchart TD
  A["Metrics Sync Worker 每小时触发"] --> B{"copilot_metrics_sync_enabled?"}
  B -->|"否"| C["跳过"]
  B -->|"是"| D["读取启用 metrics 的 org"]
  D --> E{"org access_token 或 GITHUB_TOKEN?"}
  E -->|"无"| F["记录 warning 并跳过 org"]
  E -->|"有"| G["请求最新 28 天报告"]
  G --> H["下载并校验全部报告文件"]
  H --> I[(原子保存快照和同步时间)]
  I --> J["将报告最新 UTC 日与同 org 的 proxy 请求对账"]
  J --> K{"漂移 > 10%?"}
  K -->|"是"| L["记录 audit event"]
  K -->|"否"| M["仅更新指标"]
```

## 回滚原则

```mermaid
flowchart TD
  A["发现故障"] --> B{"可通过配置回退?"}
  B -->|"是"| C["回退 client pool / budget 配置"]
  B -->|"否"| D["回滚服务版本"]
  C --> E["复核指标恢复"]
  D --> E
```

- 优先回退配置，再回退二进制。
- 回滚后要复核请求成功率、路由分布和账号状态。
- 任何恢复或摘除操作都应保留审计痕迹。
