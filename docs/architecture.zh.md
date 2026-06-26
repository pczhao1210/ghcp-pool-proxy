# 架构设计

GHCP Pool Proxy 的核心目标是把下游模型协议入口和上游 Copilot 账号资源解耦。客户端只看到 OpenAI / Anthropic 兼容接口，内部通过 canonical DTO、router、provider adapter 和 control plane 协同完成账号选择、健康管理、预算控制和可观测治理。

## 架构目标

- 对外暴露模型协议，不暴露通用 GitHub CLI 或 SDK 操作 API。
- Gateway 保持无状态，热状态进入 Redis，冷状态进入 PostgreSQL。
- 路由决策优先考虑健康、预算、风险、并发和 seat 状态，sticky 亲和只是软优先级。
- 账号生命周期、恢复、org/seat 同步和 Copilot Metrics 同步放在控制面和 worker，避免进入请求热路径。

## 总体结构

```mermaid
flowchart LR
  Client["Client / SDK / Claude Code"] --> Gateway["Gateway :8000"]

  subgraph DataPlane["数据面"]
    Gateway --> Canonical["Canonical Protocol Layer"]
    Canonical --> Router["Router Snapshot"]
    Router --> Provider["Copilot Provider Adapter"]
    Provider --> Copilot["GitHub Copilot Upstream"]
  end

  subgraph ControlPlane["控制面"]
    Dashboard["Dashboard /"] --> Admin["Admin API /admin/*"]
    Admin --> Postgres[(PostgreSQL)]
  end

  subgraph WorkerPlane["任务面"]
    Worker["Worker"] --> Recovery["Recovery Tasks"]
    Worker --> Probe["Health Probe"]
    Worker --> MetricsSync["Copilot Metrics Sync"]
  end

  Gateway --> Redis[(Redis)]
  Gateway --> Postgres
  Worker --> Postgres
  MetricsSync --> GitHubAPI["GitHub REST API"]
```

## 请求路径

```mermaid
sequenceDiagram
  participant C as Client
  participant G as Gateway
  participant R as Router
  participant P as Provider Adapter
  participant U as GitHub Copilot

  C->>G: POST /v1/chat/completions or /v1/responses or /v1/messages
  G->>G: 解析协议并生成 canonical request / parse protocol and build canonical request
  G->>R: 选择池、账号和 sticky target / select pool, account, and sticky target
  R-->>G: 返回 selection / return selection
  G->>P: 发起上游请求 / call upstream adapter
  P->>U: 访问 Copilot 上游 / call Copilot upstream
  U-->>P: 返回响应或错误 / return response or error
  P-->>G: canonical response
  G-->>C: 按下游协议格式返回 / return in downstream protocol format
```

## 配置刷新与恢复链路

```mermaid
flowchart TD
  Operator["Operator"] --> Dashboard["Dashboard"]
  Dashboard --> Admin["Admin API"]
  Admin -->|"账号 / 池"| PG[(PostgreSQL)]
  PG -->|"启动加载 + 每 30s 刷新"| Snapshot["Gateway Router Snapshot"]
  Snapshot --> Router["请求路由"]

  Admin -->|"恢复账号"| Task[(recovery_tasks)]
  Task -->|"每 60s 扫描"| Worker["Recovery Worker"]
  Worker --> Cred{"active credential 可用?"}
  Cred -->|"是"| Active["重置风险并恢复 active"]
  Cred -->|"否"| Quarantined["保持或进入 quarantined"]
```

## 模型目录链路

```mermaid
flowchart LR
  Admin["Dashboard / Admin API"] -->|"PATCH /admin/settings/model_catalog_json"| Settings[(system_settings)]
  Settings -->|"读取 model_catalog_json"| Catalog["Gateway Model Catalog"]
  Catalog --> Models["GET /v1/models 返回 exposed 模型"]
  Catalog --> Resolve["请求模型 exposed -> upstream"]
  Resolve --> Provider["Copilot Provider Adapter"]
  Resolve -->|"未启用或不存在"| Invalid["400 invalid_model"]
```

## Copilot Metrics 同步链路

```mermaid
flowchart LR
  Worker["Metrics Sync Worker"] --> Flag{"copilot_metrics_sync_enabled?"}
  Flag -->|"否"| Skip["跳过本轮"]
  Flag -->|"是"| Orgs["读取启用 metrics 的 org"]
  Orgs --> Token{"org token 或 GITHUB_TOKEN?"}
  Token -->|"无"| Warn["记录告警并跳过 org"]
  Token -->|"有"| GitHub["GitHub Copilot Metrics API"]
  GitHub --> Snapshot[(metrics snapshots)]
  Snapshot --> Reconcile["与 proxy usage 汇总对账"]
  Reconcile --> Dashboard["Dashboard 展示同步状态"]
```

## 分层职责

### Gateway

- 接收 OpenAI Chat Completions、OpenAI Responses API 和 Anthropic Messages 请求。
- 统一转换成 canonical request。
- 执行认证、全局预算检查、模型目录映射、路由、账号级预算检查、流式转发和错误回写。
- 启动时加载 router 快照，并定期从 PostgreSQL 刷新 pool、账号关系和 route policy。
- 记录 trace、latency、token、sticky、provider error 和 usage ledger。

### Canonical 协议层

- 吸收不同协议的请求格式差异。
- 统一工具调用、流式事件、模型别名和响应结构。
- 只保留内部需要的抽象，不把客户端格式泄漏到 provider 层。

### 路由器

- 依据协议、模型、route policy、池状态、账号状态和并发上限选定账号。
- 支持 sticky 亲和、重绑定和 overflow。
- 路由时剔除非 active pool、非 active 账号、不可用 org/enterprise seat 和超并发账号。
- 候选账号按风险、当前并发、pool membership weight 和账号 priority 排序。

### Copilot Provider 适配层

- 负责把 canonical request 转换成上游可接受的请求。
- 屏蔽上游错误码差异，标准化 401、403、429、5xx 和网络超时。
- 只处理上游接入，不承担客户端协议适配。

### 控制面与任务面

- Admin 负责账号、凭据导入、池、客户端 profile、settings、GitHub org 同步入口、审计查询和 Dashboard 静态资源服务。
- Worker 负责账号恢复任务、凭据过期提醒、健康探针和 Copilot Metrics 定时同步。
- Admin API 需要 bearer token；Dashboard 静态页面由 admin 根路径服务，页面内调用 `/admin/*` 时附带管理员 token。

## 存储分工

```mermaid
flowchart TD
  Hot["Hot state"] --> Redis[(Redis)]
  Cold["Source of truth"] --> Postgres[(PostgreSQL)]
  Hot --> Concurrency["当前并发"]
  Hot --> Affinity["Sticky affinity map"]
  Hot --> RateLimit["短周期限流计数"]
  Cold --> Accounts["账号与凭据元数据"]
  Cold --> Policies["池、策略、预算、审计"]
```

- PostgreSQL 保存账号、凭据元数据、池、策略、预算、审计和恢复任务。
- PostgreSQL 还保存 `system_settings`、模型目录配置、GitHub org 信息、metrics snapshots 和 proxy usage ledger。
- Redis 保存并发计数、短 TTL 亲和关系、限流计数和分布式锁。
- 凭据明文不入库，敏感内容必须经过加密和脱敏流程。

## 关键边界

- 数据面不直接执行通用 GitHub 操作。
- 路由决策使用代理侧实时状态，不依赖 Copilot Metrics 做热路径判断。
- sticky session 是软约束，健康、预算、风险和 seat 有效性始终优先。
- 单机部署和集群部署共享同一套状态边界设计，便于平滑扩展。
