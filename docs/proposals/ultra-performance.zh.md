# Ultra 性能模式提案

**尚未实现，尚未批准生产使用。** 本页保留目标、风险与重启评审条件，不是运行手册；当前没有可用的 Ultra 开关、部署 action 或已验证容量默认值。

## 目标与现有基线

探索可逆的 `standard|ultra` 模式，通过减少请求级 accounting、成功日志与非必要指标，评估单 Gateway 的吞吐上限。默认行为不能改变，收益必须通过同一不可变产物的对照压测证明。

现有系统已移除金额/Token 配额，但保留 RPM、并发、provider-attempt/dispatch 所有权与 usage outbox。尤其是 dispatch journal 承担请求生命周期与恢复正确性，不只是统计写入；不能直接照旧设想跳过它。当前合同见[路由](../routing.zh.md#限流与并发)与[运维](../operations.zh.md#用量与-cache-观测)。

## 不得隐式削弱的边界

- 保留客户端鉴权、固定 pool、模型 entitlement、协议/终态校验、账号并发与全局/账号 RPM。
- 保留 sticky、安全取消、lease 释放、错误日志、健康探针及 live readiness；Redis 不可用或结果不确定时在派发前 fail closed。
- PostgreSQL 仍是账号、配置、凭据、binding 和协调状态的权威；shared cache miss 可能读库，user/session binding 仍需业务写入，不能宣传“零 PostgreSQL”。
- 若关闭 usage、outbox 或请求驱动健康更新，必须逐项说明正确性替代方案与数据缺口；Dashboard 不得把未知用量显示为真实零。

## 重新评审前必须决定

1. 哪些写入只是可选观测，哪些承担派发 fencing、恢复或幂等；删除后如何保持所有权及终态合同。
2. 对 durability、审计、SLO/RPO 与健康反馈的风险接受。正式生产需单独批准并更新[集群生产门禁](../plans/cluster-deployment.zh.md)，不能以配置开关绕过。
3. 明确的 opt-in、重启要求、只读 effective mode/config 标识与集群一致性。不得 per-Pod 覆盖或让混合 mode/revision 同时接流。
4. 双向切换必须 drain 请求/SSE，保持 release digest、密钥与 Standard RPM 原值；失败恢复旧配置仍返回非零，恢复失败则保持入口关闭。多副本方案须先通过独立拓扑验收。
5. UI 显示模式、有效 RPM、accounting/health 状态及数据缺口；配置未知必须警告，不能默认展示正常状态。

## 实施与验证准入

获批后再冻结配置、Redis、Gateway、Admin/UI、部署切换与性能测试的实施切片。验证至少覆盖：

- Standard 行为回归、非法配置、两次反向切换、配置/镜像一致性与失败回滚。
- 三协议 JSON/SSE 成功、错误、取消、writer failure、incomplete 与派发所有权恢复。
- RPM 原子全局/账号裁决、重复 request ID、过期、Redis 不可用和不确定结果；v2 的 Cluster 同 slot 门禁不能省略。
- 固定硬件、版本、provider、pool 模式、请求大小/时长和 sticky 设置的阶梯压测，预先约定错误率、p95/p99、CPU/RSS/GC、Redis 延迟、PostgreSQL WAL/行数及日志量阈值。

任何建议 RPM 都必须来自通过档位并保留安全余量；提高全局 RPM 不增加账号额度、并发或上游容量。当前停止在提案阶段，历史 benchmark 数字与已完成兼容阶段均不能替代这些批准和证据。
