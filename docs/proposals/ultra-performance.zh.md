# Ultra Performance Mode 计划

> 当前状态：仅计划评审，不修改代码、部署清单或仓库文档，不运行实现/部署门禁。
>
> 相关阶段：Phase 7 P3.4；实施仍依赖 P3.3 完成。

## 1. 目标

新增可逆的 `standard|ultra` Gateway 运行模式。Ultra 用于移除请求级 PostgreSQL accounting、成功日志和非必要成功指标，让单 Gateway 在账号侧额度允许时承载更多账号，并通过压测识别下一瓶颈。

Ultra 保留：

- 客户端鉴权、路由、模型 entitlement 与响应协议验证。
- Redis global/account RPM 和账号并发保护。
- sticky 路由、错误处理、取消和 Redis lease 释放。
- warn/error 日志、inflight/error 健康指标、后台账号探针和 live readiness。
- PostgreSQL 作为账号、pool、凭据、客户端、能力、配置、binding、Admin/Worker 与 Redis coordination 的权威存储。

Ultra 关闭：

- `provider_attempts` 创建、状态迁移、finalize 与 materialization outbox。
- `usage_ledger` 记录、rollup 输入、token/cost usage 统计。
- 成功 access log 与 `provider request dispatch` info log。
- 成功路径 usage/compatibility Prometheus 指标。
- 请求结果驱动的账号 success/failure health 写入。
- daily token 与 daily nano-AIU budget；Ultra 检测到任一非零 daily budget 时 fail closed。

Ultra 不等于无 PostgreSQL：shared 稳态仍可能因 auth、feature 或 credential cache miss 触发 PG 读取；user/session binding 仍有业务 PG 写入。

## 2. RPM 合同

现有 RPM 是 Redis ZSET 实现的 trailing-60-second 滑动窗口：每次裁决删除 `score <= now-60s` 的成员，检查 global/account `ZCARD`，两者都允许后才写入。61 秒 TTL 只用于回收 key。共享 Redis epoch/keyspace 的全部 Gateway 共用 global 窗口；拒绝请求不占额度，也不排队。

Ultra 使用专用 RPM-only 原子脚本：

- 同一脚本裁决 global 和 account RPM。
- request ID 作为幂等 member。
- 不创建保留到 UTC 日界的 budget reservation hash。
- 不写 daily counter，也不需要 finalize/release。
- Redis ambiguous outcome 继续在 provider dispatch 前 fail closed。
- protocol v2 保持 `{budget}` 同 slot 约束。

### 2.1 模式化 RPM

Standard：

- 继续使用现有 `budget_max_rpm_global` DB setting，环境变量只是 fallback。
- Standard 原值不得被 Ultra 覆盖或回写。

Ultra：

- effective global RPM 优先使用 `GATEWAY_ULTRA_MAX_RPM_GLOBAL` 或 YAML 对应值。
- 未显式配置时使用 release 内置 `DefaultUltraMaxRPMGlobal`。
- 当前候选默认值为 `240000 RPM`；release 前必须由 16C/32GiB 目标压测确认，否则按最高通过档及安全余量下调。
- per-account RPM、账号 `max_concurrency`、pool binding concurrency 均保持原值。

有效上限为：

$$
\min(\text{Ultra global RPM},\sum \text{account RPM},\text{Gateway/Redis capacity},\text{upstream quota})
$$

默认每账号 60 RPM 时：

- 100 个满载账号：最多约 6000 RPM。
- 1000 个满载账号：最多约 60000 RPM。
- 4000 个满载账号：最多约 240000 RPM。

提高 global RPM 只移除代理 admission cap，不增加单账号额度、账号并发、CPU、Redis、socket 或 Copilot 上游容量。

## 3. 配置与集群一致性

新增启动配置：

```yaml
gateway:
  performance_mode: standard
  ultra_max_rpm_global: 240000
```

环境覆盖：

```bash
GATEWAY_PERFORMANCE_MODE=ultra
GATEWAY_ULTRA_MAX_RPM_GLOBAL=240000
```

约束：

- `performance_mode` 只接受 `standard|ultra`，非法值拒绝启动。
- mode 与 Ultra RPM 是 restart-required startup config，不允许 UI 热切换。
- 同一集群的全部 Gateway 必须使用同一 ConfigMap revision、mode、Ultra RPM 和 image digest。
- 禁止 per-Pod override；混合 mode/revision 时不得恢复入口流量。
- `/version` 或等价只读状态暴露 effective mode、effective global RPM、config revision 和 accounting enabled 状态。
- 增加低基数 mode/config metric，监控发现混合 revision 时告警。

## 4. Dashboard

Admin `/admin/config` 墍加以下只读字段：

- `gateway_performance_mode`
- configured Ultra global RPM
- effective global RPM
- request accounting enabled
- config revision

Dashboard 登录后的所有 tab 在全局 header 下显示状态：

- Standard：不显示危险横幅，可显示低调的 Standard 状态。
- Ultra：显示全宽、高对比的 `ULTRA MODE` 横幅。
- 横幅至少展示 effective global RPM，并明确 usage/accounting 和 request-driven health 已关闭。
- mode 未知或配置读取失败时显示警告，不能默认为 Standard。
- Usage 页面不得把 Ultra accounting 空窗显示成“真实零使用量”；应标记数据不可用/不完整区间。

## 5. VM/Compose 双向切换

`deploy/deploy.sh` 增加两个互斥 action：

```bash
deploy/deploy.sh --mode-ultra
deploy/deploy.sh --mode-standard
```

它们与 `start|stop|reset|logs|generate-config` 同时提供时拒绝，且不会顺带拉取新镜像、执行 migration 或改变 release identity。

### 5.1 `--mode-ultra`

1. 校验已有 `.env`、config、运行栈和当前 release 支持 Ultra。
2. 保存原 `.env`、mode、digest 和 Standard effective RPM。
3. 停止接收新请求并等待 active request/SSE drain；flush Standard usage/success writer。
4. 使用权限 `0600` 的同目录临时文件原子写入 `GATEWAY_PERFORMANCE_MODE=ultra`。
5. 保留显式 `GATEWAY_ULTRA_MAX_RPM_GLOBAL`；缺失时由应用采用 release 默认推荐值。
6. 仅 recreate Gateway 与 Admin；Admin 需要展示 effective mode。
7. 验证 `/healthz`、`/readyz`、Admin config、effective mode/RPM 和 accounting disabled。
8. 成功后记录 mode、RPM、config digest、release identity、操作者和 accounting gap 起始时间。

### 5.2 `--mode-standard`

1. 执行相同的入口停止与 drain。
2. 原子写入 `GATEWAY_PERFORMANCE_MODE=standard`，不删除 Ultra RPM 配置。
3. recreate Gateway 与 Admin。
4. 验证 Standard mode、原 DB/env global RPM 已恢复、account RPM/concurrency 未变化。
5. 记录 Ultra accounting gap 结束时间；不尝试补写 Ultra 期间不存在的 attempt/ledger。

### 5.3 失败回滚

- 新模式 readiness/config 校验失败时恢复原 `.env` 并 recreate 原模式。
- 原模式恢复成功后命令仍以非零退出并报告切换失败。
- 回滚也失败时保持入口关闭、明确报错，禁止带未知 mode 继续接流。
- 日志不得输出 `.env`、credential、token 或 Secret 内容。

## 6. Kubernetes 推荐

VM `deploy.sh` 不直接修改 Kubernetes。K8s 使用环境 overlay/ConfigMap 注入：

```yaml
configMapGenerator:
  - name: ghcp-runtime-env
    behavior: merge
    literals:
      - GATEWAY_PERFORMANCE_MODE=ultra
      - GATEWAY_ULTRA_MAX_RPM_GLOBAL=240000
```

切换规则：

- 单副本：maintenance drain 后使用 `Recreate`。
- 多副本：使用独立 blue/green Gateway Deployment/Service；green ready 后停止入口、drain blue，再原子切流。
- Standard 与 Ultra Pod 不得同时接收业务流量；普通 RollingUpdate 不属于支持路径。
- rollout 完成前验证所有 ready Gateway 的 mode/config revision/effective RPM 一致。
- 若需要相同 CLI UX，在 `deploy/k8s/apply.sh` 独立增加 `--mode-ultra|--mode-standard`，仍须遵守 drain 和不混流门禁。

现行[集群部署计划](../plans/cluster-deployment.zh.md)的 production gate 要求 durable attempt journal/outbox。Ultra 首轮只进入独立 staging/economy/performance overlay；若要正式 production，必须另行批准并修改 durability、SLO/RPO、审计/计费与发布 gate，不能只靠配置开关绕过。

## 7. 实施切片（后续，当前不执行）

1. P3.4.1：把本计划写入 Phase 7 governing plan，冻结默认 RPM、风险接受、切换合同和 benchmark identity。
2. P3.4.2：配置模型、standard/ultra effective policy 和只读状态。
3. P3.4.3：Redis RPM-only 原子 admission 与 protocol-v2 Cluster 验证。
4. P3.4.4：Gateway accounting/metrics/log/request-health policy gate。
5. P3.4.5：Admin runtime config 与 Dashboard 全局 Ultra banner。
6. P3.4.6：VM `deploy.sh` 双向切换、原子 env 更新和自动回滚。
7. P3.4.7：K8s overlay、drain/blue-green 验收和一致性检查。
8. P3.4.8：受控性能基准、容量结论、文档与 release evidence。

每个切片完成后更新 Phase 7 状态、Git SHA、验证命令、证据、未运行检查和下一最小步骤。

## 8. 验证计划（后续，当前不执行）

### 配置与模式

- 默认 Standard 行为不变。
- Ultra 显式 RPM、默认 240000、非法 mode/RPM、daily budget 冲突。
- Standard -> Ultra -> Standard 后 Standard RPM 原值恢复。
- per-account RPM 与全部 concurrency 配置始终不变。

### Redis

- allowed、global reject、account reject、重复 request ID、过期清理。
- disabled limits、Redis unavailable、ambiguous outcome。
- 无 reservation hash、无 daily key。
- protocol v1 single 与 protocol v2 Cluster；1k/2k/4k RPS 脚本阶梯。

### Gateway

- Chat/Responses/Messages 的 JSON/SSE success、error、cancel、writer failure、incomplete。
- Ultra 不调用 attempt、usage、budget-finalize 或 request-health owner。
- Standard 调用次数、JSON/SSE wire 和恢复语义不变。
- binding 流量仍有业务 PG touch，并在文档中明确排除于“零 accounting 写”。

### UI

- Ultra banner 在所有 tab 可见，刷新后保持。
- mode unknown/config failure 显示警告。
- effective RPM 与 source 正确。
- Ultra gap 不显示为真实零 usage。

### Deploy

- action 互斥、缺失 env/config、重复切换幂等。
- 默认/显式 Ultra RPM、Standard RPM 恢复。
- 文件权限和敏感值保持。
- 仅 recreate Gateway/Admin。
- 新模式失败自动回滚；回滚失败 fail closed。

### 性能

主基准：16C/32GiB、fake provider、shared/no-sticky、single local Redis、minimal non-stream Responses。

- 100、500、1000、2000、4000 RPS，再按 1000 RPS 递增到首次失败。
- 每档 warm-up 2 分钟、steady 10 分钟。
- 非预期错误 `<0.1%`、无 benchmark 配置导致的 429、p95 `<50ms`、p99 `<100ms`。
- 无 PG accounting rows、无成功请求日志、无 reservation hash/daily key。
- 记录 Gateway CPU/RSS/GC、Redis ops/CPU/p95/memory/key cardinality、PG rows/WAL/commit delta 和日志量。

`240000 RPM` 只有通过目标档及安全余量后才能成为 release 默认；否则下调并更新本计划。

## 9. 当前停止点

本轮只完成计划修改与评审，不修改任何仓库文件，不运行 Go、Dashboard、Compose、Kubernetes、Redis Cluster 或性能测试。

当前未满足 gate：

- P3.3 尚未完成。
- Ultra 生产 durability 风险尚未批准。
- `240000 RPM` 尚无目标环境压测证据。
- VM/K8s 双向切换尚未实现或验证。

下一最小步骤：评审并冻结本计划；只有用户明确要求进入实施后，才开始 P3.4.1。
