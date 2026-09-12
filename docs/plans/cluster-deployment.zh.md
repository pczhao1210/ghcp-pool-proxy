# 集群部署计划

本页维护**剩余平台工作、环境批准与生产验收门禁**。已实现行为以[架构](../architecture.zh.md)、[运维](../operations.zh.md)、[路由](../routing.zh.md)和[Kubernetes 操作指南](../../deploy/k8s/README.zh.md)为准；不再保存逐日开发记录或把旧阶段验收当作当前 release 证据。

## 当前基线与未交付边界

| 范围 | 当前产物 | 不代表已经完成 |
| --- | --- | --- |
| VM | 单机 Docker Compose、持久目录、manifest-backed migration 与固定 digest 发布 | 多机或多区域 HA |
| Kubernetes production | Gateway、Admin、general Worker、组织同步 Worker 各 1 副本 | 多副本生产容量与 HA 承诺 |
| Kubernetes staging | 仅 Gateway 为双副本，带 RollingUpdate、PDB 与 hostname spread | 生产批准、任意 Worker/Admin 横向扩展 |
| Kubernetes test | 单节点功能等价；集群内 PostgreSQL/Redis 使用 `emptyDir` | 数据持久性、备份或故障域冗余 |
| Redis | `single`、`sentinel`、`cluster` 客户端，TLS、protocol v2、同槽 Lua 与逐 primary inventory | 每种托管服务、SKU、网络与 failover 都已验收 |
| Azure 入口 | `deploy/deploy-cluster.sh` 与有限 Bicep 基线，创建/复用网络、AKS、PostgreSQL、Managed Redis，执行 what-if 与有序应用发布 | 完整平台、签名 inventory、通用 plan/doctor/destroy、Ingress/HPA、监控或备份恢复自动化 |

仓库存在清单、测试或入口，不证明任何目标 Azure/Kubernetes 资源已创建或获准生产使用。生产/staging 的 PostgreSQL 与 Redis 由运营方在应用生命周期之外提供；只有 disposable test 允许集群内临时数据服务。

## 批准与停止条件

已有实现不因本页整理而重新变为待开发。**新增平台能力和环境操作**仍须通过三层独立批准：

1. **方案批准**：冻结新增范围、设计边界、例外与首个实施切片，才允许对应代码/IaC 工作。
2. **环境冻结**：填写下面的精确资源、owner、数值目标与验证方法，才允许生成可 apply 的 resolved plan。
3. **操作批准**：apply、release、restore、destroy 分别绑定具体 artifact/hash；旧批准不能授权变更后的资源、镜像或删除清单。

批准记录包含可审计个人/主体、日期、environment/profile、范围、例外到期与复审日期。认证、网络暴露、数据一致性、HA、RPO/RTO 或删除边界变化须重新评审。未冻结输入阻断对应 workstream，不要求凭空生成 live 证据，也不能用文档编辑替代批准。

每轮只验证冻结范围；选定门禁通过后停止。新的故障形态或能力需求另建任务，不重启已完成阶段的无限审查。

## 环境冻结清单

每项保存值、`proposed|approved|rejected|superseded` 状态、个人 owner、来源/API 版本、验证方式、变更历史和 evidence URI。下表未填入真实环境值，不是可执行配置。

| 输入 | 必须冻结的内容 | Owner |
| --- | --- | --- |
| Scope | tenant/subscription、region、environment、命名/tag、Policy、quota 与成本归属 | 平台 |
| AKS | 精确版本/channel、CNI/NetworkPolicy、private API、各 CIDR、zone、node pool SKU/min/max/surge | 平台/网络 |
| 入口与出站 | Gateway/Admin 各自产品、公开/私有边界、WAF/TLS/DNS、SSE buffering/body/timeout/cancel/drain；NAT/Firewall、SNAT 与 FQDN allowlist 来源 | 网络/安全 |
| PostgreSQL | major、网络、TLS/认证、SKU/storage/IOPS、HA、backup/PITR、maintenance、最大连接、pooler 与独立 migration endpoint | 数据 |
| Redis | 服务与 client mode、拓扑、DB/TLS/认证、HA/quorum/slot/replica、SKU/容量/连接、persistence 与 epoch 恢复 | 数据/应用 |
| 备份与灾备 | PG PITR、Redis persistence/Export 的各自恢复边界；landing/archive ownership、最大备份年龄、保留/不可变策略与演练周期 | 数据/运行 |
| 身份与密钥 | identity/ServiceAccount、role/scope、Secret/CSI、轮换、Admin 边界、break-glass、镜像扫描/签名阈值 | 安全 |
| 可观测性 | workspace、DCR/DCRA、diagnostics、metrics schema/cardinality、查询、HPA adapter、告警接收方、日志保留与 daily cap | 运行 |
| SLO/容量 | 可用性、延迟/错误、配置收敛、drain、usage durability、zone RPO/RTO、region 风险接受、最大副本与月成本 | 业务/运行 |
| 发布 | image/provenance digest、schema 与 Redis protocol 兼容、批准人、回滚集合、ownership inventory | Release/平台 |

SKU、API、region、价格和产品限制需在环境冻结时核对；不可用即停止重新选型/批准，不静默替换“同级”资源。旧价格表与单次本地性能数字不构成容量保证。

## 容量、故障域与扩缩容

以下是**待环境批准的目标**，不是当前 production overlay 的副本设置：

| Profile | Gateway 目标 | 适用边界 |
| --- | --- | --- |
| dev/test | 1 | 功能、migration、协议验证；无 HA |
| economy | 至少 2，跨节点 | 可接受明确维护中断；非 HA 数据服务需有到期例外 |
| production | 至少 3，跨 node/zone | 需数值 SLO、数据层 HA、值班与故障演练 |

N+1 只表示丢失一个容量单元后仍有余量，不等于入口、节点、可用区或数据库都具备 HA。PDB 只约束自愿中断，不能补足节点容量；staging 的两 hostname 策略也不能直接外推到生产多 zone。

- Gateway 扩容不能增加账号 RPM、账号并发或上游额度。同时测量请求率、active SSE、请求时长、CPU/RSS、首 token 延迟与队列。
- PostgreSQL 按所有 Gateway、Admin、**每个 Worker role** 的最大连接数求和，再加 migration、运维、同时启动与重连余量；至少保留 20% 连接容量。HPA max 必须服从该上限。
- Redis 同时满足内存、ops、延迟、连接和带宽限制；容量模型可用 `nominal >= peak_used / 0.8 * 1.3` 作为起点，仍需针对所选服务校验保留内存。Cluster 的全局 RPM `{budget}` slot 不会因分片自动分散，必须单独压测。
- 出站同时评估 SNAT/socket 与长连接，不只看 Mbps。数据服务规格不能仅按账号数量推导。
- CPU 不能单独表达 SSE 占用；应用指标 HPA 需要已验证的 Adapter/KEDA 或平台等价组件。缺失 scrape/adapter 不能解释为零负载，保留已批准的最小副本和安全策略。
- Admin 保持单副本，直到 Device Flow/会话等状态通过多副本验证。Worker 按 role/backlog/最老任务年龄扩容，不套通用 CPU HPA。

## 网络、Secret 与供应链

已支持的操作步骤和 Secret key 表只在[Kubernetes 指南](../../deploy/k8s/README.zh.md)维护。环境验收必须确认：

- 持久环境的 PostgreSQL/Redis 私网、Private DNS 与 TLS hostname verification；DNS 故障不能退到公网、裸 IP 或错误 SNI。
- Gateway 与 Admin 的入口独立；Admin 保持私有认证边界。外部 OIDC、独立 metrics scrape 身份等属于平台目标，不得声称应用已经提供 OIDC。
- Ingress/WAF 不缓冲 SSE，不重放 `/v1/*` POST；body、idle、request、drain 与 termination timeout 形成一致矩阵，并实测取消传播。
- 限制数据库 CIDR/selector 和 HTTPS egress；标准 NetworkPolicy 无法表达 FQDN allowlist，需选定 CNI/egress gateway/firewall，不把通用 TCP 443 规则当成生产域名白名单。
- 一个 namespace 使用统一、版本化的 Secret 来源；禁止 per-Pod/per-node 本地覆盖。轮换后完整 rollout，启动配置的 inline 与 `_FILE` 来源不能同时设置。
- Runtime DML 身份与 migration DDL 身份分离；GitHub sync token 只挂载到专用 Worker。密钥不进入 ConfigMap、镜像、日志、命令行或可提交 artifact。
- 当前 Kubernetes Secret 基线与可选 CSI 分开；Workload Identity/Entra token 刷新等认证扩展需独立实现和轮换/撤销/回滚测试，不能因配置了 identity 就宣称支持。
- Release 的四个角色来自同一 Git revision，通过 manifest digest 发布，不以可变 tag 或本地缓存代替身份校验。

## Redis 拓扑与恢复门禁

客户端、TLS、v2 key/Lua 和逐 primary 检查已经实现；旧“只支持单 client、没有 TLS、必须先重写全部 Lua”的描述不再适用。仍须针对**所选服务与环境**验证下列合同：

| 模式 | 验收重点 |
| --- | --- |
| single | 单 endpoint、服务侧 HA、TLS/SNI、重连及保留数据的 failover |
| sentinel | quorum、故障域、主节点发现、独立认证、旧 primary 隔离与 Pub/Sub 重建 |
| cluster | DB 0、完整 slot coverage、每 primary 的 replica/可达性、advertised-node TLS/DNS、MOVED/ASK、resharding、逐 primary inventory |

Azure 有限基线采用 Managed Redis `NoCluster` 对应 `single`、TLS/FQDN 与 DB 0；不能将 `EnterpriseCluster` proxy 当成无分片单库来绕过 Lua 限制。`OSSCluster` 必须使用 cluster-aware client 与同槽 v2 门禁。API/端口/SKU/容量支持范围在环境冻结时核对，不能把历史服务上限硬编码成永久保证。

协议和拓扑分别变更：旧未版本化/旧 protocol 数据先在非分片环境按批准流程停写 cutover，验证 v2 后再进行 green Cluster dataset/epoch 切换。禁止不兼容 writer 混跑，Cluster 不得使用 v1；首次 v2/Cluster 接流后只能回滚到支持当前 protocol/epoch 的镜像。

### 不可省略的恢复不变量

1. PostgreSQL 保存 epoch、fencing、checkpoint/watermark 权威；Redis 保存对应 sentinel。丢失、回退或不匹配时全部 Gateway not ready，不能把缺失 RPM/并发计数视为可立即准入。
2. 只有单一 fenced recovery/checkpoint owner 能推进状态。恢复 binding generation/tombstone 与 durable attempt/outbox 后，RPM/并发仍须通过安全窗口，再恢复接流；不重建已删除的日消费配额。
3. Checkpoint 发布分三步：PG 登记带 owner/nonce/watermark 的 pending tuple；Redis 条件写入并 read-back；PG CAS 提升完全匹配的 pending 为 committed。新 owner 只能验证后幂等续办，不能另造 checkpoint 掩盖回退。
4. Redis tuple 必须匹配 PG committed 或同一 owner 的完整 pending；即使 checkpoint 相同，也检查其后的 binding/usage watermark，避免恢复了 checkpoint 却遗漏后续写入。
5. 普通保留数据的 failover 在 sentinel/checkpoint/脚本及 reconciliation 均通过后不误增 epoch；确认数据集换代、flush/restore/Import 则必须经过恢复门禁。
6. 每 environment 独占数据库/资源。Bootstrap 仅允许无历史 ready 记录且经证明为空的 keyspace；未知/mixed namespace、未知 key 或 inventory 不完整必须隔离，不能自动删除。
7. Cluster 不能靠单 endpoint SCAN 或跨 primary“原子事务”证明空库。冻结所有 writer/ACL，记录稳定 slot map 与 node identity，逐 primary 扫描并复查 topology/内容；无法证明独占写入则停止。Interrupted bootstrap 只能在相同身份与 owner 条件下恢复，不把普通故障伪装成首次启动。
8. Binding 的 generation/version、release tombstone 和 credential CAS 阻止旧 owner 复活已释放绑定、缩短新 TTL 或覆盖新凭据。Pub/Sub 是加速，轮询/reconciliation 是正确性兜底。

具体部署命令以现有工具帮助和[Kubernetes 指南](../../deploy/k8s/README.zh.md)为准；本页不是手工修改 sentinel、schema marker 或 Redis key 的运行手册。

## 持久性、备份与灾备

PostgreSQL、durable dispatch/attempt 与 usage outbox 是事实源；Redis RDB 不是消费/绑定权威，也不能替代 PITR。

- 区分服务 HA、同实例 persistence rehydrate 与可移植 Export/Import。HA 不等于零数据丢失，persistence 也不等于备份或跨实例恢复。
- 原方案的 production RDB `1h` 与 daily Export 仅是待批准起点；调度间隔不是严格 RPO。冻结实际支持的模式、性能成本、最大备份年龄、保留期和演练周期，不伪造服务未提供的 snapshot-age 指标。
- Export 必须保存完整文件集、来源/版本、operation identity、大小/checksum 与签名 manifest；只存在部分文件或 hash 不匹配不得恢复。
- Landing 与 archive 的 ownership、网络及保留策略独立。若 Managed Redis Import/Export 需要 public landing，必须作为狭窄、限时、最小权限例外批准，不扩展到数据端点或私有 archive/evidence store。
- Import 会破坏目标，只能进入隔离的 disposable/green 实例；禁止导入正在服务的 Redis。恢复后仍需 epoch/checkpoint/reconciliation、私网/TLS、usage/binding 和应用健康验收。
- 生产 zone RPO/RTO 必须是数值；region 灾难首版保持不支持并明确风险接受，或单独批准跨区方案。备份不能只证明“文件存在”，必须有恢复演练。
- Usage materialization 从持久 journal/outbox 重试；相同 identity/payload 只能落一条 ledger，冲突必须告警，不重放模型 POST。未完成派发保留 `outcome_unknown`；队列丢弃不能直接等同于 durable loss。
- 关闭 journal/outbox 或接受 bounded loss 不是当前默认能力，须先批准 durability/SLO 变化；[Ultra 提案](../proposals/ultra-performance.zh.md)不能绕过此门禁。

## 后续平台编排与资源所有权

下面是**未交付平台工具的验收要求**，不是当前部署脚本已经具备的子命令。无需保留一套尚未实现的 CLI/JSON 字段草案；实施前必须另行冻结 schema 与接口。

- 资源定义由 IaC 维护，脚本只负责编排，不重复一套创建逻辑。新的完整平台入口默认只读 plan，mutation 必须显式批准；这不改变现有交互入口的命令语义。
- `create|reuse|skip` 必须对每个资源及 child 独立解析。复用默认只读；parent 不自动授予 child 所有权，`skip` 仍被依赖时 plan 失败。
- 外部资源的首版 grant 只允许精确字段的限时 update，不允许 wildcard、replace/delete；复用 parent 下由本 deployment 创建的 child 按自己的 deletion policy 管理，永不连带删除 parent。
- Inventory 记录 tenant/subscription/deployment lineage、完整 ARM ID 或 Kubernetes canonical key、parent/dependency、owner、有限 action、template/parameter/manifest hash、deletion policy、grant 与验证时间。
- Kubernetes identity 包含 cluster ARM ID、`kube-system` UID 形成的 fingerprint，以及对象 UID/field manager；同名重建或外部接管必须拒绝修改/删除，不能只按 namespace/name 推断所有权。
- 每 environment 串行化操作。Apply 绑定 resolved plan、inventory、ARM what-if 与 Kubernetes server-side dry-run/diff；destroy 另生成精确删除清单及反向依赖检查。
- 权威 inventory/evidence 位于 workload 销毁边界之外的受保护、版本化存储。独立批准 bootstrap，固定 trust registry；采用非导出签名密钥与可验证 key version，轮换时验证新旧信任并重签活动记录。
- 原方案的 P-256/ES256 trust root 和 production requester 加两名 approver 仍是待批准要求；批准绑定 operation/environment/artifact hash、有效期和身份，不能复用旧批准。
- Inventory 丢失、签名/hash 不符、权限不足或资源对账失败时 destroy 必须拒绝；不能从标签、名称、前缀或本地缓存重建后直接删除。
- Namespace、复用资源、数据库、archive 和 evidence store 默认 Retain。删除 namespace 需证明没有外部对象并单独批准；destroy 前验证受保护备份/恢复证据，保留审计。

## 发布、迁移与故障验收

当前 schema 与版本切换要求由[运维](../operations.zh.md#发布与迁移)维护。新 release 不沿用旧阶段的 schema 18/19 fixture 或结案报告作为唯一门禁。

- Migration 使用独立 DDL 身份、单 session advisory lock 和 manifest 允许的迁移路径；失败阻断 rollout。
- 未来支持滚动升级时必须验证 expand/migrate/contract 与 N-1/N 兼容；breaking schema/Redis 变更先停流，不混跑。当前不支持混合生命周期 writer，不能因为 Deployment 有 RollingUpdate 就忽略该限制。
- 配置回滚优先；镜像回滚必须同时支持已安装 schema 与 Redis protocol/epoch。需要数据恢复时使用配套备份/密钥，不能盲目运行 down migration。
- 优雅终止先 not ready、等待入口传播、drain 请求/SSE、flush/replay，再退出；termination grace 覆盖全过程。Pod crash 可能中断本次请求，不透明重放。
- Worker takeover 必须验证 claim lease、heartbeat、fencing、幂等副作用与迟到提交；组织同步 token 仅专用 role 可见。
- PostgreSQL/Redis 不可用、snapshot 过期或恢复未完成时 not ready；本地 snapshot 不是无限离线服务的许可。
- 私网/DNS/密钥/镜像拉取失败不得退回不安全配置；监控故障不应直接破坏请求路径，但暂停依赖该证据的生产发布/HPA 决策。

### 选定门禁

| 门禁 | 能证明什么 | 不能替代什么 |
| --- | --- | --- |
| `make k8s-validate` | 清单、脚本及静态部署合同 | 实际集群故障演练 |
| `make k8s-test` | disposable 单节点 migration、就绪与三协议 smoke | 持久化或 HA |
| `make test-redis-cluster` | 真实 disposable Cluster 上的 Store/v2 协议反例 | 托管服务目标环境验收 |
| `make validate` | 当前提交级聚合回归，需准备固定 CLI 输入 | 不可变发布 attestation 或环境批准 |
| `make release-validate` | 同一 artifact 的 manifest、schema、兼容报告/attestation 和发布一致性 | 生产网络、容量或灾备验收 |
| 批准环境的定向演练 | 跨 Pod、SSE drain、节点/数据故障、私网、轮换、恢复、监控与容量 | 其他环境或其他 release 的证据 |

每轮按变更影响选门禁，不因为一次文档或协议字段修改就强制重跑所有环境。被选中的 gate 必须记录 artifact/config identity、测试输入、结果、未运行项和批准人，禁止用历史成功覆盖当前失败。

### 生产前必须有的反例与数值

- 跨 Pod 路由/RPM/并发、sticky/binding/rebind/overflow 与单机一致；旧配置/旧 binding/旧 credential owner 不能覆盖新版本。
- Sentinel、Cluster slot failover 与 dataset rollback/nonce mismatch 的 not-ready、恢复和重新准入；同槽 Lua 明确声明全部 key，未知 namespace 不被静默清理。
- SSE rollout/drain、Pod 强杀、节点驱逐、Worker takeover、模糊 usage 提交及 payload 冲突；无永久 lease、重复副作用或伪造成功。
- 配置事件收敛 p95 `<=5s`、轮询 `<=30s`、snapshot 最大年龄 `90s` 是原方案建议值，需对照实现和环境冻结；超龄必须 not ready，不以目标数值冒充当前默认配置。
- Proxy overhead、首 token、错误率、强制中断率、PG commit/acquire、Redis slot latency、SNAT 与队列水位必须冻结基线及失败阈值。
- 最小副本、HPA max、缺失指标行为、连接余量、备份最大年龄、RPO/RTO、告警 owner/receiver/runbook 和响应时间须数值化；P1 15 分钟确认是待批准起点。
- 月成本、日志摄入/保留/cap、资源可用区容量与例外到期明确；超预算或无关键告警接收方时不得生产 apply。

## 剩余工作

- [ ] 由平台/网络/数据/安全/业务 owner 签署具体环境冻结记录与例外。
- [ ] 完成目标环境 Ingress/TLS/私网 egress、Secret 轮换、数据 HA/PITR/Redis 恢复及监控告警。
- [ ] 在批准 staging 验证跨 Pod、SSE、节点故障、Worker takeover、Redis failover/恢复和容量。
- [ ] 按需单独批准并实现生产多副本、HPA、平台 inventory/备份/destroy 编排；不把已有有限 Azure 入口等同于完整交付。
- [ ] 冻结新 release，取得有效兼容证据与目标生产批准。

## 相关文档

- [Kubernetes 操作指南](../../deploy/k8s/README.zh.md)
- [运维与故障恢复](../operations.zh.md)
- [路由合同](../routing.zh.md)
- [兼容证据](../../compatibility/README.zh.md)
- [人工验证](../runbooks/manual-validation.zh.md)
- Azure Managed Redis [架构](https://learn.microsoft.com/azure/redis/architecture)、[持久化](https://learn.microsoft.com/azure/redis/how-to-persistence)、[Import/Export](https://learn.microsoft.com/azure/redis/how-to-import-export-data)、[可靠性](https://learn.microsoft.com/azure/reliability/reliability-managed-redis)
