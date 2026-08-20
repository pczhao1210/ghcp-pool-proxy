# 兼容性路线图

> 状态：Phase 7 已完成；仅在新的 release、matrix/schema/build 变化或经批准的新能力出现时创建新的兼容性任务。
>
> 最近确认：2026-08-20

## 事实源

按以下优先级裁决：

1. [数据库迁移](../../migrations/) 决定已部署 schema。
2. 当前代码和可复现测试决定已实现行为。
3. [兼容矩阵](../../compatibility/matrix.json) 决定静态客户端合同与最高候选等级。
4. 外置、未提交的 release-evidence attestation 决定一个不可变 release 的有效等级。
5. [兼容矩阵说明](../../compatibility/README.md) 说明 evidence 输入与验证命令。

## 已完成边界

- Gateway 只通过 typed canonical DTO 支持 GitHub Copilot 上游；不会透传任意请求 body 或 header。
- Claude Code 的正式路径是 Messages -> Messages；Codex 的正式路径是 Responses -> Responses。跨协议只作为明确降级路径。
- 模型能力、CLI 验证和账号 probe 均不进入 Gateway 请求热路径。
- `require_fresh` profile 使用请求开始时的不可变账号模型证据；健康、预算、风险、并发、seat 与 entitlement 始终优先于 affinity。
- Codex `0.147.0 + gpt-5.5 + Responses` 的静态合同与 release evidence 以 matrix 和 attestation 为准。当前 Claude Code 版本在 `--resume` 使用未签约的 Opus 模型，保持 `unsupported`。

完整实施证据、已关闭切片和历史决策见 [Phase 7 执行历史](../history/phase-7-execution-log.zh.md)。协议语义见 [协议文档](../protocol.zh.md)。

## 新任务触发条件

只有出现下列任一输入时才创建独立任务：

- 新的 Gateway build、schema、matrix revision 或固定 CLI 版本；
- 已批准的新客户端能力、模型合同或上游协议形状；
- 可复现回归、release gate 失败或运行环境证据与静态合同冲突。

每个任务必须冻结范围、相关 artifact、验收门禁与退出条件；不得用历史 report 或 attestation 提升新 release 的等级。

## 发布与可选验证

每个不可变 release 都需要同一身份的 clean fixed-CLI report、四角色 release manifest 和 schema 2 attestation，并执行 `make release-validate`。真实 Copilot、目标 VM 与 deployed Gateway 检查属于可选人工证据，步骤见 [人工验证](../runbooks/manual-validation.zh.md)；它们不能替代固定 CLI 门禁。

## 文档治理状态

- 2026-08-19：活动路线图从 Phase 7 历史执行记录中分离；历史记录保留在 `docs/history/`，不再作为当前 backlog。项目现状和功能指南已并入架构、运维与兼容性主文档。
- 验证：全仓库 25 份 Markdown 的本地链接检查通过；运行包 README 按其 staged release root 解析链接；`make release-manifest-test` 通过，确认 staging 包含文档索引与兼容矩阵。
- 未运行检查：本次只改变文档与本地构建产物，不需要运行 Go、Dashboard、Compose 或 Kubernetes 门禁。
- 下一最小步骤：仅在新的 release、matrix/schema/build 变化或经批准的新能力出现时创建独立兼容性任务。

## 2026-08-20 Dashboard 首次加载回归

- 状态：已完成。`AdminAPI` 默认 `fetch` 现在绑定到 `globalThis`，避免经实例字段调用浏览器 `Window.fetch` 时抛出 `Illegal invocation`；该问题由 schema 19 页面首次请求暴露，不是 schema `18 -> 19` migration 的允许错误或重试策略。
- 验证：严格校验默认 `fetch` 接收者的回归测试先失败后通过；`npm --prefix web/dashboard test` 共 25 项通过，`npm --prefix web/dashboard run build` 通过且无警告，相关编辑器诊断为零。经 VS Code 转发的 Chromium 可载入 Vite Dashboard；带测试 token 的首次加载进入已登录视图并向 `/admin/*` 发出网络请求，页面未出现 `Illegal invocation` 或未捕获异常。
- 桌面布局：Quick Start 的 Client、Client profile、API key、Endpoint 与 Load 控件已统一为 `40px` 高和 `14px` 字号；Chromium 桌面视口量测确认四列顶部坐标一致。手机布局不在本次验收范围。
- Dashboard 收口：已删除 Capabilities 与 Compatibility 两个导航页，以及对应的前端状态、轮询、刷新请求、DTO、渲染组件和专属样式。Gateway 的 `require_fresh` 路由快照、Worker capability-sync、静态兼容矩阵与 Admin API 保留为后端运行/发布合同，不再由 Dashboard 暴露。
- 未运行检查：本地 Admin `8001` 未启动，Vite proxy 因而返回 `500`，未验证成功的真实 Admin payload；未执行目标 VM、真实 Copilot、Compose、Redis Cluster、Kind 或完整 `make validate`。本切片不改变后端、数据库 schema、协议、路由或发布身份。
- 下一最小步骤：将修复纳入新的不可变 Dashboard/Admin 镜像与 release manifest，再在目标环境首次加载 Dashboard；若不创建新 release，则兼容性路线图仍保持关闭。

## 2026-08-20 Responses 非白名单兼容 fallback

- 状态：实现与包级回归完成。原生 Responses 请求中的 `reasoning.encrypted_content` 不再因客户端不在固定 Codex 白名单内而拒绝；Gateway 允许这条已知安全降级，由 Copilot Provider 在序列化前过滤该 include 值。白名单命中仍记录 `ignored_by_declared_downgrade`，其它客户端记录 WARN 和 `applied_compatibility_fallback/provider_include_filtered` 指标。
- 性能边界：请求热路径只增加常数级 include 检查；仅命中 fallback 时增加一条结构化日志和一次计数，不增加网络调用、重试、探测、存储读写或请求内容持久化。
- 验证：新增普通 profile 的红灯回归，先复现 `400 provider_include_not_supported`，实现后确认 `200`、一次 provider dispatch、一次 fallback 指标；普通 UA、未认证 Codex UA、伪装固定 UA、仅 Lite header 和 `additional_tools` 五种形态均通过；固定 Codex declared downgrade 与其它 provider 不支持语义的拒绝用例继续通过。`go test ./internal/compatibility ./internal/protocol ./internal/provider/copilot ./internal/api/gateway -count=1` 通过。
- 未运行检查：`make validate`、真实 Copilot、Compose、Redis Cluster、Kind、目标 VM 与 release 门禁尚未执行。
- 下一最小步骤：在隔离 pool 的真实账号上运行人工探针；本切片停止扩展，release 时再执行聚合门禁。

## 2026-08-20 真实账号可选人工探针

- 状态：Phase 7 后维护验证工具已收敛为仓库根目录的外置 `manual_test.sh`，不新增 `cmd/*` 命令、不修改服务入口、不进入 Dockerfile 或发布镜像。脚本运行时在仓库内生成一次性 Go helper，复用 Worker 的配置、PostgreSQL credential、`DBTokenSource` 和 Copilot Provider，执行后删除临时源码与容器内二进制；Gateway 不参与探测。报告已升级为 schema 2。
- 探测边界：先直接读取 Copilot `/models` 原始 JSON，再严格按 `GPT 5.4 / responses`、`GPT 5.6 Terra / responses`、`Claude Sonnet 4.6 / anthropic_messages`、`Claude Opus 4.8 / anthropic_messages`、`Gemini 3.5 Flash / chat_completions` 顺序执行目录可见目标。每个模型执行 text、streaming、强制 function tool；GPT 追加 reasoning，Claude 追加 thinking，共 19 个串行请求，默认每次请求前等待 15 秒且不允许低于 10 秒。
- 运行时白名单：Codex declared-downgrade 识别接受严格 `codex_exec/<major>.<minor>.<patch>` 家族 UA 并继续要求已启用 `codex-candidate` profile；Claude Code runtime contract 原本就只按 profile/model/API 查找。matrix 的 exact version entries 和 fixed-CLI registry 保留为发布证据，不进入运行时路由键。
- 验证：`bash -n manual_test.sh` 与 `./manual_test.sh --check` 通过，临时目录在退出后清理；`go test ./internal/api/gateway ./internal/provider/copilot ./internal/compatibility -count=1` 通过，覆盖 Codex 多版本/伪造 UA、Codex 与 Claude Code 共享版本无关 runtime contract，以及实测 `prompt_cache_retention`、`copilot_info_messages`、`stop_details` 响应字段；其它未知字段仍 fail closed。
- 未运行检查：扩展后的 19 场景真实 Copilot 探针、`make validate`、release、Redis Cluster 或 Kubernetes 门禁尚未执行。人工报告不能直接提升静态等级，也不能替代 fixed-CLI report、release manifest 或 schema 2 attestation。
- 下一最小步骤：对同一隔离测试账号运行扩展后的 `manual_test.sh`，按场景结果决定模型/API 合同，不依据单次成功修改 release evidence。

## 2026-08-20 默认最大兼容与真实响应收口

- 状态：Phase 7 后维护切片已实现。普通 Dashboard client 不再展示或提交 entitlement 选择，新 profile 使用后端默认 `allow_unknown`；编辑既有受控白名单 profile 时保留其 `require_fresh`。Codex/Claude Code 继续按 profile/model/API 与 typed wire contract 使用专用白名单兼容，runtime 不绑定 exact CLI version；matrix exact-version entry 仍只决定静态/release evidence。
- 请求策略：三入口忽略未知顶层参数；模型目录解析后、语义校验前，六个跨协议方向按固定表删除目标协议无法表达的已知参数，并只记录 route 与参数名。未知 role/content/item/block、损坏 tool lifecycle、identity 冲突和显式错误终态仍 fail closed；健康、预算、风险、并发、seat 与 `require_fresh` 过滤未放宽。热路径只有固定字段查找/删除，不增加网络请求、重试、探测或存储访问。
- 响应策略：根据真实 Copilot shape 增加带类型边界的 metadata、reasoning opaque state、缺失/incomplete item status、Chat tool finish reason、Responses response/item ID、output index、终态乱序/省略辅助 item 与 terminal-only reasoning 归一化；终态文本/arguments/reasoning 冲突、item 类型变化、tool identity 冲突及未知嵌套字段仍拒绝。
- 真实证据：外置 schema 2 探针已多轮执行 19 场景，报告保存在 `/tmp/ghcp-direct-capabilities-schema2-*.json`，不经过 Gateway 且不提升 static/release level。最后一轮代码修改前报告为 15/19 supported：两项 Responses streaming 因终态省略增量期辅助 item 被本地 parser 拒绝，GPT 5.4 强制 tool 未服从，Claude Opus 4.8 thinking 返回上游 `400`；前两项已由聚焦回归修正，后两项保留为模型能力/服从性结果，不伪造支持。
- 验证：受影响四个 Go 包共 507 项测试通过；Dashboard 25 项测试和生产 build 通过且无警告。Provider 聚焦反例覆盖不同 item 共用上游 index、终态 ID/顺序漂移、辅助 item 省略、terminal-only reasoning、incomplete status、类型/内容/tool identity 冲突和 `obfuscation` 类型边界。随后以 matrix 固定 build `2026.08.18.1` 和仓库外权限 `0600` 的四 entry CLI manifest 执行 `make validate`，lint、全仓 Go race、Dashboard、静态 matrix、fixed-CLI candidate、release-manifest、VM 部署脚本、Kubernetes manifest/cluster 脚本与 Azure Bicep 检查全部通过；工作树为 dirty，因此该结果不构成 release evidence。
- 未运行检查：最终代码尚未再跑真实 19 场景；`make release-validate`、Redis Cluster、实际 Kubernetes 集群、目标 VM 与目标环境 compatibility 门禁尚未执行。人工报告不能替代 clean fixed-CLI report、release manifest 或 schema 2 attestation。
- 下一最小步骤：可选执行一次最终代码的外置真实探针，确认没有 `upstream_protocol_error`；创建不可变 release 时以 clean revision 重新生成 manifest/report/attestation 并执行 `make release-validate`，不因单次模型服从性波动扩大 parser 或修改 matrix 等级。