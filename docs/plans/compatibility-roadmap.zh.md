# 兼容性路线图

> 状态：Phase 7 已完成；仅在新的 release、matrix/schema/build 变化或经批准的新能力出现时创建新的兼容性任务。
>
> 最近确认：2026-08-21

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

## 2026-08-21 Cherry Studio Messages 502 调查

- 状态：Phase 7 后维护修复已实现。第一处失败是 Messages -> Chat 的 `$.system[0]: system_block_not_representable`：方向级 validator 错把纯文本 system block 的合法 `cache_control` 当作不可表达语义；现在 Chat/Responses 投影允许丢弃该 metadata，非文本 system block 仍 fail closed，原生 Messages 保持 typed cache-control 透传。部署后 `gpt-5.6-luna` 的 Messages -> Responses 已到达 Copilot，但稳定返回 `400 invalid_request`；直连反例证明 Copilot Responses 同时拒绝 `temperature` 和 `top_p`，普通 Responses builder 现统一丢弃这两个采样字段。`max_tokens=128000` 单独及与 30 个工具组合均已通过，因此不实施 catalog clamp。`claude-sonnet-4.6` 的原生 Messages 失败是独立问题，当前证据不支持归因于 `/v1/messages` parser 或 dispatch。
- 诊断改进：外置 `manual_test.sh` 修复 Go bool flag 的调用形式，`CATALOG_ONLY=false` 不再被误解析为 true；新增 `PROBE_MAX_TOKENS`、Anthropic `streaming_tool`、复杂 schema、工具数量、长 description、Cherry 采样参数与大工具集场景。Gateway 的 provider dispatch 日志新增 request body 字节数、message/system/tool 数和 `max_tokens`；上游 HTTP 失败日志仅在 Provider 已生成安全 metadata 时保留 status、error type、response body length/hash，不记录请求、响应正文或凭据，客户端仍只收到通用 `model provider error`。
- 性能边界：修复只删除一次跨协议 validator 的 metadata 拒绝分支，不增加序列化、网络调用、重试、探测或存储访问；既有 dispatch 诊断仍只读取固定字段和 slice 长度。
- 验证：新增协议红灯先精确复现 Messages -> Chat 400，修复后 Chat/Messages/Responses 三目标均通过；完整 Cherry 风格流式 HTTP 回归覆盖 system `ephemeral`、message `"[Circular]"`、tool cache-control、`eager_input_streaming`、`max_tokens=128000`，三个目标子测试均到达正确 Provider API 并正常结束。Responses `top_p=1` 直连反例稳定返回 HTTP `400 invalid_request`、body length `119`、SHA-256 `339df6d9c6c106b5fabc8248b5ceac2cc55d4133768648511732e4c2c6feda56`；Provider 边界删除 `top_p` 后，同一 `top_p_only` 与完整 `client_params` 探针均转为 `supported`。聚焦单测通过。
- 新证据：远端 `/version` 确认 09:43 的重放命中 build `2026.08.18.1`、revision `0374fca07d3003ad631ef4b692e18ba7f59fd692`，该 clean revision 已包含 Responses 删除 `temperature` 的修复，故仍失败的 Luna 请求由 `top_p` 解释。使用同一 active 账号直连 Copilot，复杂 schema 关键字、30 个工具、单个约 `16KB` description、两个失败端点各约 `60KB` 工具 description，以及 30 个工具叠加 `max_tokens=128000` 均为 `supported`；Sonnet 原生 Messages 也接受 `top_p=1`。这已否证 parser/dispatch、复杂关键字本身、工具数量、单项长度、总 description 大小、128K 输出上限及其与工具数量的组合，但尚未否证原始 Cherry 工具集中某个具体 schema/字段组合。对 CC Switch revision `0b5da510168914b251481654a568c3ffacd62cf4` 的源码核对确认：GitHub Copilot 的 Claude 模型将 `/v1/messages` 改写到 `/chat/completions`，Anthropic tools 重建为 Chat function tools；`clean_schema` 仅在根 schema 缺少 `type` 时补 `type: object`（同时按需补空 `properties`），并递归删除 `properties`/`items` 路径上的 `format: uri`，不会清理 `$defs`、`$ref`、`anyOf`、`default` 或 `additionalProperties`。因此 CC Switch 成功首先证明的是 Messages -> Chat 路径可用，不构成原生 Messages schema 兼容证据。
- 未运行检查：尚未取得 09:43 两条 trace 的远端 Gateway 安全日志；会话存储只保留 `#attachment:Pasted text` 占位符，无法恢复原始 Sonnet request body，因而不能做忠实工具集二分；尚未部署包含 `top_p` 修复的新 Gateway，也未运行完整 `make validate`、release、Redis Cluster 或 Kubernetes 门禁。外置探针与 dirty 工作树结果不构成 release evidence。
- 下一最小步骤：将原始 Sonnet 失败 request JSON 作为工作区文件提供，在同一账号先完整直连重放，再按工具数组二分定位最小失败 schema；若需先验证 CC Switch 的两个 schema 差异，只增加“根 `type` 缺失”和嵌套 `format: uri`”两组独立原生探针。同时部署新的 Gateway 后重放 Luna 请求，确认 Messages -> Responses 不再出现同一 `400` 指纹。只在 native 反例稳定复现后才修改 Anthropic provider，不先清洗 tool schema 或改变 limits。

## 2026-08-21 Claude Code 原生 Messages 流终态修复

- 状态：Phase 7 后维护修复已完成。Claude Code `2.1.238` 的真实请求经 `claude-opus-4-6 -> claude-opus-4.6 / anthropic_messages` 到达 Copilot；失败请求约 `121KB`，包含 1 条 message、3 个 system block、24 个工具和 `max_tokens=64000`。上游已返回 usage 并开始输出，Gateway 随后以 `upstream_protocol_error path=$.context_management kind=unknown_field` 中止，因此工具 schema、连接、认证、路由和请求前校验均不是该次失败根因。
- 修复：Anthropic 官方流合同把 context editing 结果放在最终 `message_delta.context_management`。Provider parser 现在只在 `message_delta` 接受 object 类型的该字段，经 canonical `StreamEvent` 保留，并由 Anthropic stream writer 在相同根级位置写回；非 object 值、其它事件上的同名字段和其它未知 envelope 字段继续 fail closed。Gateway 的协议错误日志只增加安全的 `path/kind`，不记录触发值、SSE body、请求正文或凭据。
- 可用性策略：Claude Code `2.1.238` 交互模式新增的 `Anthropic-Beta` token 曾在 `$.headers.anthropic-beta[2]` 触发 `unknown_beta`，导致完整 27/29-tool 请求在上游 dispatch 前返回 502，而同模型最小请求和 24-tool 非交互请求均成功。原生 Copilot Messages 现在只转发已验证 beta allowlist，丢弃未知 beta 并以 `unknown_count/unknown_indexes` 记录安全告警，不记录 token 原值；canonical 正文、工具 schema、响应 envelope 和 credential header 边界不变。
- 验证：Provider 正向/类型反例和 Anthropic writer 原生生命周期聚焦测试通过；`go test ./internal/provider/copilot ./internal/protocol ./internal/api/gateway -count=1` 与 `git diff --check` 通过。单独重建 Gateway 且不重建 Redis/Admin/Worker 后，使用本地 Claude Code `2.1.238`、真实 Copilot provider 和默认模型执行相同请求，CLI 返回 `is_error=false`、`terminal_reason=completed`、结果 `OK`，Gateway 无 stream error。公网 `74.226.217.165:8000` 的 `/version` 返回 build `2026.08.18.1`、revision `c1df4a550710bff85832ad401ac82ba83a1fa8d7`，与 release manifest 一致；`/readyz` 返回 200。使用部署端临时 API key 的最小 `claude-sonnet-4-6` 原生 Messages 请求返回 200/`OK`；同一公网 URL 和模型的真实 Claude Code 24-tool 请求在约 3.4 秒内返回 `is_error=false`、`terminal_reason=completed`、结果 `OK`。错误使用本地 smoke key 时公网明确返回 401 `auth_error`，请求不会进入协议转换。
- 最新验证：单独重建本地 Gateway 后，真实 Claude Code `2.1.238` 交互式 Opus 请求包含 27 个工具、约 `133KB` body；日志记录 `unknown_count=1`、`unknown_indexes=[2]` 后继续 dispatch，客户端约 4 秒返回 `OK`，不再出现 502。
- 未满足门禁：`make validate`、不可变 release attestation、目标 VM 新版本部署、Redis Cluster、实际 Kubernetes 集群和 Cherry Studio 原始 payload 重放尚未执行。当前 dirty 工作树与本地 smoke 结果不单独构成 release evidence。`start.sh restart` 清空无持久卷 Redis 后仍需人工 reconcile，是独立运行问题。
- 下一最小步骤：发布并部署该 beta 过滤策略，再以公网 Claude Code 交互式 Opus/Sonnet 各重放一次；随后以原始 Cherry Studio payload 重放原生 Messages。若仍失败，只按新的安全 `status/path/kind` 建立最小反例。另开运行切片修复 Compose restart 后的 Redis coordination 恢复，不关闭正文和响应协议的现有 fail-closed。

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

## 2026-08-20 Cherry Studio Anthropic tool hint 兼容

- 状态：Phase 7 后维护修复已完成。Messages parser 接受并丢弃布尔 `tools[].eager_input_streaming`，不让客户端流式输入提示进入 canonical/provider body；非布尔值仍按精确 JSON path 返回 `400`，其它未知 tool 字段继续拒绝。Cherry Studio 在 content `cache_control` 中生成的 `"[Circular]"` 仅作为该位置的序列化占位符清除，普通文本与 tool schema 不做全局替换。
- 验证：parser 正向、类型反例和完整 HTTP/provider capture 回归通过；`go test ./internal/api/gateway ./internal/protocol ./internal/provider/copilot -count=1` 通过。随后以 matrix 固定 build 与仓库外权限 `0600` 的 CLI manifest 执行 `make validate`，lint、全仓 Go race、Dashboard 25 tests/build、静态 matrix、fixed-CLI candidate、release-manifest、VM 部署/迁移修复脚本、Kubernetes manifest/cluster 脚本与 Azure Bicep 检查全部通过；dirty 工作树结果不构成 release evidence。
- 未运行检查：尚未执行 release、Redis Cluster、实际 Kubernetes 集群、目标 VM 或更新后的远端 Gateway 请求重放。
- 下一最小步骤：构建并部署包含本修复的 Gateway 镜像，然后从 Cherry Studio 重放同一 `/v1/messages` 请求；若出现新的精确字段错误，只按已证明为非语义客户端 hint 的字段建立有界兼容，不放宽 tool schema/lifecycle 校验。

## 2026-08-20 Claude Code 输出 reservation 上界兼容

- 状态：Phase 7 后维护修复已完成。真实 `/v1/messages` 请求已越过 parser、模型目录和账号选择，但客户端显式输出窗口超过默认 `4096` 时，budget checker 即使只启用 RPM 也返回 `503 budget_unavailable`。现在仅在启用 account/global daily-token 预算时把 `BUDGET_MAX_RESERVATION_OUTPUT_TOKENS` 作为硬上界；未启用 daily-token 预算时原样保留客户端显式输出上限，未指定输出上限的请求仍使用配置 fallback。已启用的 daily-token 预算继续 fail closed，不因兼容性目标放宽。
- 部署合同：本地与 VM Compose 已把 `BUDGET_MAX_RESERVATION_INPUT_TOKENS`、`BUDGET_MAX_RESERVATION_OUTPUT_TOKENS` 和 `BUDGET_MAX_RESERVATION_NANO_AIU` 传入 Gateway。两个 Compose 文件均以 `200000/32000/9000` 覆盖值完成渲染验证；默认值保持 `128000/4096/0`。若目标环境启用了 daily-token 预算，operator 必须将输出 reservation 上界配置为不低于计划接纳的最大 `max_tokens`/`max_output_tokens`。
- 验证：budget 正反例证明 RPM-only 32K reservation 被原样保留、daily-token 超界仍拒绝；完整 Anthropic HTTP 回归证明 `claude-opus-4.8`、`max_tokens:32000` 不再在 Provider dispatch 前返回 503。预算、Gateway、Redis 相邻包测试、`make lint` 与 `make deploy-test` 通过。随后以 matrix 固定 build `2026.08.18.1` 和仓库外 CLI manifest 执行 `make validate`，lint、全仓 Go race、Dashboard 25 tests/build、compat candidate、release workflow、VM 部署、Kubernetes/cluster 与 Azure Bicep 门禁全部通过；dirty 工作树结果不构成 release evidence。
- 未运行检查：尚未构建/发布包含本修复的新不可变 Gateway 镜像，未在目标 VM 重放原始 Claude Code 请求，也未执行 release、Redis Cluster 或实际 Kubernetes 集群门禁。
- 下一最小步骤：创建并部署包含本修复的 Gateway 镜像；确认目标环境 daily-token 预算是否为 `0`。若已启用，将 `BUDGET_MAX_RESERVATION_OUTPUT_TOKENS` 设为计划接纳的最大客户端输出窗口后重建 Gateway，再用原始 Claude Code 请求确认不再出现 reservation bound 503。

## 2026-08-20 Models 页面 Copilot 有效窗口

- 状态：Phase 7 后维护功能已完成。经用户确认只采用 Copilot 当前有效上限，不按模型名称维护原生规格；`FetchCopilotModels` typed 解析 `/models.data[].capabilities.limits` 的 context、prompt/input、output 与 non-streaming output 数值，Admin refresh/catalog response 和严格 `model_catalog_json` 合同保留四个可选非负字段。旧目录不含字段时继续兼容，缺失值保持未知。
- Dashboard：现有 `Refresh from Copilot -> Save` 流程批量更新并持久化 limits；刷新预览和 Models 主表均以紧凑数值显示 Context、Input 和 Output，Output 同时显示可用的 non-streaming 上限。修改 GHCP Model ID 会清除旧 limits，避免跨模型残留。展示数据不进入 Gateway 请求校验、路由或预算 reservation。
- 验证：Provider fixture 证明 nested capabilities limits 被完整解析；Model Catalog 正向/负值反例和 Admin response 回归通过；Provider、Model Catalog、Admin 三包完整测试通过；Dashboard 26 tests 与 production build 通过且无警告，编辑器诊断为零。
- 未运行检查：尚未执行完整 `make validate`、release、目标 VM 的真实 `/models` 刷新与浏览器视觉验收、Redis Cluster 或实际 Kubernetes 集群门禁。
- 下一最小步骤：运行完整提交级门禁；部署新 Admin/Dashboard 后选择 active Copilot account 执行 Refresh，确认目标 `/models` 数值进入预览，保存后在 Models 主表持续显示。

## 2026-08-21 Responses 1M context management 透传

- 状态：Phase 7 后维护修复已实现。真实 Copilot 模型元数据的 `billing.token_prices.long_context.max_prompt_tokens` 为 `936000`；当前 VS Code Copilot 请求构造器按所选 prompt 上限的 90% 生成 `context_management:[{"type":"compaction","compact_threshold":842400}]`。Responses parser 现在只接受 typed compaction 数组和正整数阈值，并在原生 Responses 路径写回上游 body；错误容器、未知类型、缺失/未知字段和非法阈值继续 fail closed，跨协议路径按既有策略丢弃不可表达参数。
- 验证：parser 正向与四类反例通过；HTTP -> canonical capture、canonical -> provider body 断言通过；使用真实 Copilot Provider 和受控 HTTP upstream 的 wire capture 确认请求发往 `/v1/responses`，且 body 保留 `type=compaction`、`compact_threshold=842400`。修复 `internal/provider/copilot/auth_test.go` 既有的未检查测试响应写入错误后，以冻结 build `2026.08.18.1` 和仓库外 `0600` 固定 CLI manifest 运行完整 `make validate`，lint、全仓 Go race、Dashboard 26 tests/build、静态兼容、manifest-aware CLI、release workflow、VM 部署、Kubernetes/cluster 与 Azure Bicep 门禁全部通过；编辑器诊断和 `git diff --check` 为零。
- 未满足门禁：真实 Copilot 1M 上游响应、不可变 release、目标 VM、Redis Cluster 与实际 Kubernetes 集群门禁尚未执行；受控 upstream 的 wire capture 与 dirty 工作树聚合结果不构成 release evidence。
- 下一最小步骤：部署新 Gateway 后从已选择 1M 的 VS Code 会话重放请求，确认 Copilot 上游接受 `842400` 阈值并返回成功响应；创建不可变 release 时在 clean revision 上重新生成 evidence。

## 2026-08-21 Models 长上下文自动检测

- 状态：Phase 7 后维护功能已实现。`FetchCopilotModels` 现在解析 `/models.data[].billing.token_prices.long_context.max_prompt_tokens`；仅当 Copilot 明确返回正数上限时标记 `long_context_supported=true`，有效 prompt limit 取普通与 long-context 上限的较大值，有效 context window 取原值与 `long prompt + max output` 的较大值。负数和 `int64` 加法溢出继续 fail closed；未声明该字段的模型不会按名称推断支持。
- Dashboard：`Refresh from Copilot` 会把检测状态和有效 limits 写入严格 `model_catalog_json`。新账号真实刷新证明 Copilot 也可能直接在 `capabilities.limits` 返回 `1050000` context、`922000` prompt、`128000` output，而不返回独立 `billing.long_context` 标记；因此编辑页与主表不再显示重复且可能矛盾的 Long Context 状态列，只以 Context/Input/Output 有效 limits 为准。修改 GHCP Model ID 仍会清除旧 limits 和检测状态，防止跨模型残留。
- 边界：该配置只记录 Copilot 真实能力并让 Models 页采用有效上限，不在 Gateway 热路径自动注入 `context_management`，也不把手工展示值当作授权。Responses 客户端仍需选择 1M 模式或发送已支持的 typed compaction 参数；真正超过默认 272K 输入的 Copilot 成功响应仍是发布门禁。
- 验证：Provider 正例证明默认 `400000/272000/128000` 加 long-context `922000` 自动得到 `1050000/922000/128000`；负值和溢出反例通过。Model Catalog 严格合同、Admin response、Dashboard normalize/save/清理状态回归通过；完整 `make validate` 已通过。移除状态列后 Dashboard production build、编辑器诊断和无残留文案检查通过。
- 未运行检查：状态列移除后的完整 `make validate`、超过 272K 输入的真实 Copilot 响应、不可变 release、Redis Cluster 与实际 Kubernetes 集群门禁尚未执行。
- 下一最小步骤：运行 Dashboard tests 并重新发布 Admin/Dashboard，确认 Models 页仅显示 GPT-5.6 Sol/Terra 的 `1.05M / 922K / 128K`；再用已选择 1M 的 Responses 客户端完成一次真实长输入响应。

## 2026-08-21 客户端失败与账号 Risk 归因

- 状态：Phase 7 后维护修复已实现。使用与 Gateway 相同的本地账号直接探测真实 Copilot：19 个模型/场景中 17 个成功，Claude Sonnet 4.6 的 text、streaming、tool、thinking 全部成功，Claude Opus 4.8 的 text、streaming、tool 成功；其 thinking 请求返回 `400 invalid_request`。GPT 5.4 tool 的唯一失败是模型未遵循 forced tool call，不是 HTTP/provider 失败。账号在探测后仍为 `active`、Risk `0`、连续失败 `0`，因此凭据、seat 与一般配额不是 Claude Code/Cherry Studio 共同失败的根因。
- 修复：`classifyUpstreamFailure` 原先把所有未识别错误兜底归因为 `network_error`，导致 Gateway 自己产生的上游协议解析、本地转换等错误每次错误增加账号 Risk `+3`。现在仅已类型化的 credential、401/403、429/quota、upstream 5xx 和 provider network 错误影响账号 Risk；`invalid_request`、`upstream_4xx`、语义兼容、上游协议解析和未类型化本地错误均不再归因账号。
- 验证：新增反例先复现 `UpstreamProtocolError -> network_error`，修复后协议错误、语义兼容错误和普通本地错误均返回空 Risk reason，显式 `UpstreamError{Type:"network_error"}` 仍映射 `network_error`。聚焦测试和 Gateway 包测试通过；以冻结 build `2026.08.18.1` 和仓库外 `0600` 固定 CLI manifest 运行完整 `make validate`，所有提交级聚合门禁通过。外置探针通过可选 `WORKER_CONTAINER_ID` 使用隔离 idle Worker-compatible 容器，避免启动后台健康/Risk 任务；报告保存在仓库外，不作为 release evidence。
- 未满足门禁：聊天附件正文未暴露给当前工具，现有 Gateway/Worker/Admin 日志结束于本次客户端失败之前，故尚未确定 Claude Code 与 Cherry Studio 的精确共同错误类型；未构建或部署新 Gateway，也未运行 release、Redis Cluster 或实际 Kubernetes 集群门禁。dirty 工作树的聚合结果不构成 release evidence。
- 下一最小步骤：部署包含本修复的 Gateway，分别重放原始 Claude Code 与 Cherry Studio 请求，并按 trace/provider attempt 核对返回状态、`error_type` 与 Risk 变化；预期本地 protocol/compatibility 错误不再提升 Risk。取得附件原文或部署日志后，再针对共同的精确失败路径建立有界兼容测试。

## 2026-08-21 Claude Code 2.1.238 adaptive effort 资格验证

- 状态：Phase 7 后维护兼容已实现。受控 Gateway 抓取证明：自定义 `claude-sonnet-4.6` 和点号 `claude-opus-4.8` 仍发送 `thinking.type=enabled`、固定 `budget_tokens=31999`，不发送 `output_config`；连字符 `claude-opus-4-8` 会发送 `thinking.type=adaptive`、`thinking.display=omitted`、`output_config.effort=medium`，以及 `mid-conversation-system-2026-04-07`、`effort-2025-11-24` beta。Gateway 现对两项 beta 建立精确 allowlist，对 thinking/output_config 建立 typed 嵌套校验，并将验证过的 exposed `claude-opus-4-8` 精确映射到 Copilot upstream `claude-opus-4.8`；其它未知 beta、字段、thinking 类型和 effort 值继续 fail closed。
- 真实验证：使用同一 `ms` 账号、隔离 idle Worker-compatible 容器和不经过 Gateway/Router/Risk scheduler 的 Provider 探针，`claude-opus-4.8/adaptive_thinking` 在完整两项 beta 下 `1/1 supported`，耗时 `12596ms`，无 HTTP/provider error；报告保存在仓库外并设为 `0600`。另以 `CLAUDE_CODE_QUALIFICATION_VERSION=2.1.238` 运行 exact CLI qualification，确认 resolved binary、adaptive thinking、medium effort 和两项 beta 全部通过。两类证据都不是 release attestation。
- 配置：模型目录使用 `{"exposed":"claude-opus-4-8","upstream":"claude-opus-4.8","vendor":"Anthropic","upstream_api":"anthropic_messages","enabled":true}`；Claude Code/CC Switch 的 `model` 与 `opusModel` 使用 exposed 连字符 ID。CC Switch 的 Codex `reasoningEffort` 不适用于 Claude；实测孤立 `settings.json` 的 `effortLevel:"medium"` 被 Claude Code `2.1.238` 忽略并发送默认 `high`，因此档位应在 Claude Code 内选择或显式使用 `--effort medium`。
- 验证：Provider allowlist/wire、Messages parser 正反例、Claude 专用模型列表精确映射、exact Claude Code `2.1.238` qualification 和外置 helper 编译检查均通过。随后以冻结 build `2026.08.18.1` 和仓库外固定 CLI manifest 执行完整 `make validate`，exit `0`；lint 0 issues、全仓 Go race、Dashboard 26 tests/build、compatibility matrix/fixed CLI、release workflow、VM/deploy、Kubernetes/cluster 与 Azure Bicep identity/subnet RBAC 门禁全部通过。
- 未满足门禁：Claude Code `2.1.238` 尚未加入 `compatibility/matrix.json`，当前 qualification、真实账号结果和 dirty 工作树聚合验证不提升静态/effective level；未构建/部署新 Gateway，未执行 clean fixed-CLI report、release attestation、目标 VM、Redis Cluster 或实际 Kubernetes 集群门禁。Sonnet 4.6 尚无已验证 adaptive-capable exposed ID，继续使用固定 manual thinking。
- 下一最小步骤：在 Dashboard 保存精确 alias，部署新 Gateway，并用 CC Switch/Claude Code `2.1.238` 的 `claude-opus-4-8` 重放一次 medium effort 请求。只有在独立 Opus runtime contract、profile/pool/entitlement 和完整 exact workflow 通过后，才考虑新增 matrix entry。

## 2026-08-21 Models 页 Claude 默认 exposed ID

- 状态：Phase 7 后维护配置修复已实现。Copilot model refresh 和内置默认目录现在只对 Claude/Anthropic 模型的默认 exposed ID 将 `.` 改为 `-`，例如 `claude-opus-4.7 -> claude-opus-4-7`、`claude-sonnet-4.6 -> claude-sonnet-4-6`；发往 Copilot 的 upstream ID 保持原始点号。OpenAI、Google 等非 Claude 模型不变，operator 已配置的自定义 exposed 也不在读取时被静默改写。
- Context window 边界：Models 页当前只读展示 Copilot 返回的 Context/Input/Output limits，没有 context window 编辑控件。严格 `model_catalog_json` 合同能够持久化正数 `context_window_tokens`，但该字段目前仅用于 Admin DTO 和 Dashboard 展示，不参与 Gateway 请求校验、路由、预算或上游能力变更；手工修改不能扩大 Copilot 的真实 context window。
- 1M 能力门禁：同账号真实 `/models` 报告中 Claude Opus 4.6/4.7/4.8、Sonnet 4.6/5 均只声明 `264000` context、`200000` prompt，且没有 `long_context` 能力，因此当前不能发布 Claude `sonnet[1m]` / `opus[1m]` alias。只有 Copilot 后续返回实际 1M 上限或独立 1M upstream ID 后，才能新增 `[1m]` exposed alias，并继续验证 Claude Code 发出的 1M beta/request wire 与 Copilot 接受度；修改 Dashboard 展示值不能越过该门禁。
- 验证：Claude Opus/Sonnet/旧 3.5 命名正例及 GPT/Gemini 不变反例通过；`internal/modelcatalog` 与 `internal/api/admin` 全包测试通过。随后以冻结 build `2026.08.18.1` 和仓库外固定 CLI manifest 执行完整 `make validate`，lint 0 issues、全仓 Go race、Dashboard 26 tests/build、compatibility matrix/fixed CLI、release workflow、VM/deploy、Kubernetes/cluster 与 Azure Bicep 门禁全部通过。
- 未满足门禁：未构建/部署 Admin/Dashboard，也未在目标环境执行一次真实 Copilot refresh；dirty 工作树聚合验证不构成 release evidence。已有持久化目录不会自动迁移，需 refresh 后 Save 才写入新的默认 exposed ID。
- 下一最小步骤：部署 Admin 后在 Models 页执行 `Refresh from Copilot -> Save`，确认 Claude exposed 使用连字符、GHCP Model ID 保持点号，并显示真实 `264K/200K` 上限；1M alias 等待 Copilot 目录提供可验证能力后再建立。