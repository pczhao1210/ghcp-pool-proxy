# 兼容性路线图

基础兼容阶段已完成。本页只保留**新任务触发条件、未关闭的验证与尚未批准的能力方向**；已完成实现和逐次测试结果留在 Git 历史，不在此复写当前协议规格。

## 事实源与边界

- [协议](../protocol.zh.md)维护 parser、方向策略、response/stream 与 reasoning 行为。
- [路由](../routing.zh.md)维护 pool/entitlement；模型和客户端 probe 不进入请求热路径。
- [兼容矩阵](../../compatibility/matrix.json)决定固定客户端合同和最高候选等级；[兼容说明](../../compatibility/README.zh.md)维护报告、attestation 与命令。
- 模型支持清单、精确转换 profile、账号实际模型可用性和客户端资格是不同事实。原生 API 可调用、静态模型条目或一次探针成功都不能自动提升 release 等级。
- Schema 以[migrations](../../migrations/)为准；当前文档或旧报告不是部署证据。完整维护规则见[文档索引](../README.zh.md#维护规则)。

## 新任务触发与发布门禁

仅在新 Gateway build/schema/matrix/固定 CLI 版本、已批准能力、可复现回归、release gate 失败或环境证据冲突时建立独立任务。

每项先冻结 artifact、客户端版本、模型/API、profile/pool、最小反例、验收门禁和退出条件。新增 wire 形状须有合法脱敏样本与预期语义；官方 schema 扩展或可构造测试夹具不自动进入支持范围。

每个不可变 release 重新生成同一身份的 clean fixed-CLI report、四角色 manifest 与 attestation，执行 `make release-validate`；静态检查与固定 CLI 准备见[兼容说明](../../compatibility/README.zh.md)。真实 Copilot/目标 VM 重放是显式选择的人工补充，不能替代固定 CLI 门禁。Redis Cluster 和实际 Kubernetes 验收仅在影响对应部署合同时选取，不能将“旧切片没运行”解释为每次协议维护都必须重跑。

## 尚未关闭的验证

这些项保留原维护切片的未验收结果，**不宣称已经发布或在用户环境复测通过**。只有选择对应 scope 时才构成当次 gate；缺原始输入时先取得受控复现材料，不猜测附件或线上日志。

| 范围 | 下一步及停止条件 |
| --- | --- |
| 未绑定模型的转换能力 | 对矩阵中仍无精确 runtime binding 的模型，取得 `/models` ID/API 与合法/非法参数对照证据，再评审 profile；不靠展示名注入参数 |
| Opus 5 / reference profile | 当前 reference 配置不等于 Copilot 实测。账号可见后验证 text、stream/tool、signed thinking、续轮及 off/xhigh/max 组合；以现有 profile 为基线，不沿用旧日志中已被覆盖的配置判断 |
| GPT reasoning 互转 | 受控重放 GPT-5.4、5.5、5.6 的同源客户端历史/工具集，对照精确 profile 行为；新增失败只围绕新的 path/kind 建反例 |
| Responses 流与 thinking bridge | 重放 GPT Responses item-ID 轮换、Sonnet/Opus 工具循环与续轮，确认 UI 无重复回答且 tool 后有合法 final/terminal；不扩展未授权 bridge |
| Messages 参数与原生流 | 在选定目标重放 summarized thinking、未知可选字段、tool hint、beta/终态与 context-management；检查规范化日志只含安全 path，不含正文/值 |
| Gemini Messages 流 | 验证省略不可表示的 unsigned reasoning 后仍交付 final text 和合法 `message_stop` |
| 客户端上游拒绝与 Risk | 对未获得逐字节材料的单次 400/502 重新取得 request/trace ID、受控原文及安全 status/hash；无可重复失败不新增 schema 清洗。本地协议错误不应提高账号 Risk |
| Dashboard / 模型目录 | 对新 Admin 镜像检查首次加载、真实 Refresh → Save、上游有效 limits、连字符 exposed 与原始 upstream ID；已有持久目录不自动迁移，1M alias 不凭名称推测 |
| Redis coordination 重启恢复 | 按当前生命周期合同单独复现 Compose/数据集恢复，不通过关闭协议、正文或 readiness 的 fail-closed 来解决 |
| OpenCode 上游身份 | 继续[独立认证验收](opencode-upstream-auth.zh.md)，不新增下游客户端 family |

使用[人工验证](../runbooks/manual-validation.zh.md)的隐私和证据规则。原始 probe report、dirty 工作树、旧 release 的通过记录都不能作为新 release attestation。

## 客户端能力仍需独立资格验证

- Claude Code 已登记版本的 `--resume` 会涉及当前合同未覆盖的 Opus 路径，状态以矩阵为准；Sonnet 首轮成功不能证明整条 workflow。
- Claude Code `2.1.238` 的 adaptive-effort 探针尚不构成正式 matrix entry。若纳入支持，须独立冻结 Opus runtime contract、profile/pool/entitlement、exact CLI workflow 和 clean release evidence；不能仅凭 alias 或一次 medium effort 请求放行。
- `count_tokens`、`compact`、WebSocket、Codex 动态工具回调及其他未签约能力保持关闭。只有独立 capability artifact 与完整测试通过后才修改合同。
- 模型 ID 及合法 thinking/effort 值只在对应矩阵维护；不在路线图重复一份随时间漂移的模型清单。

## 未批准方向：声明式能力策略

目标是将频繁变化的参数能力、rename/map/clamp/drop/reject 和 evidence 编译为版本化策略，减少逐模型代码分支。**尚无批准的实施 issue、schema、compiler、shadow evaluator 或性能基线，不属于当前 release acceptance。**

若立项必须保留：

1. 协议类型、必填字段、union/role/tool lifecycle、signature、图片安全与 SSE 终态由代码强制，数据不能放宽硬拒绝。
2. 精确模型转换、客户端授权、动态账号可用性分层维护；有效能力取各层交集，不合并成无边界的大表。
3. 启动/后台严格校验并编译不可变 snapshot；热路径只做有限查表，不读 JSON、查库、远程探测或运行通用脚本。
4. 先 schema/离线 validator，再 shadow comparison；差异清零后按单模型/单方向启用。每步有非法配置反例、协议回归、量化性能边界与回滚。
5. 如支持在线 overlay，须签名/版本化、全量验证、原子切换与 last-known-good；内嵌基线保持安全默认。

下一步仅是独立设计评审，可从已有 Messages → OpenAI effort 映射选一个有限样例；未经批准不进入实现。性能模式另见[Ultra 提案](../proposals/ultra-performance.zh.md)，同样不因旧阶段完成而自动获批。
