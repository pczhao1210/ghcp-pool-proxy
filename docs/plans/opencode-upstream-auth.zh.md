# OpenCode 上游认证 profile 实施计划

> 状态：P1 与P2可复现本地门禁已完成；真实 GitHub Copilot 环境门禁待受控账号验证。
> 范围冻结：仅新增管理员为池账号选择 OpenCode GitHub OAuth Device Flow 的上游认证通路；下游客户端仍为 Codex 与 Claude Code，不新增 OpenCode 客户端合同，不改变兼容矩阵、路由、预算或协议转换边界。

## 目标

在保留现有 VS Code/Copilot Chat Device Flow 与短期 Copilot token 兑换行为的同时，增加受控的 `opencode` 认证 profile：

- 使用固定 OpenCode OAuth client、`read:user` scope、JSON Device Flow 请求和 OpenCode User-Agent。
- 将 GitHub OAuth access token 直接作为 Copilot Bearer token。
- profile 与 token mode 随加密 credential payload 持久化，并参与 Gateway、Worker、模型发现和健康探针的上游 header 选择。
- 旧 credential payload 缺少新增字段时继续按 `vscode` 解释；未知值 fail closed。
- 正常请求热路径不新增远程探测、重试或额外数据库读取；profile 元数据与 token 共用现有短 TTL 缓存。

## 非目标

- 不把 OpenCode 增加为下游客户端 family。
- 不修改 `compatibility/matrix.json` 或现有 Codex、Claude Code runtime contract。
- 不增加终端用户自助授权、durable Device Flow transaction 或新数据库 schema。
- 不允许客户端注入 OAuth client ID、上游 User-Agent 或 GitHub API version。
- 不在 OpenCode direct OAuth 失败时静默回退到 VS Code token exchange。

## P1：实现

- [x] 定义 `vscode` / `opencode` auth profile、`copilot_exchange` / `direct_oauth` / `static_bearer` token mode 和固定 header policy。
- [x] Device Flow 按 profile选择表单或 JSON wire contract；OpenCode profile由启动配置显式启用。
- [x] Admin start/complete API 接收并回显 profile，完成时验证 token 的模型访问权限后加密保存。
- [x] TokenSource 缓存 token、credential generation、profile 与 mode；刷新只适用于 exchange mode。
- [x] Provider、模型发现、Worker capability session 与环境收集器使用凭据 profile。
- [x] direct OAuth 收到 401 时按 credential generation 条件失效，并发布 Redis cache invalidation；延迟响应不得失效较新的 credential。
- [x] Dashboard 提供 VS Code/OpenCode 两个管理员入口并在当前 session 中保持profile。
- [x] 更新配置示例、架构和运维文档。

## P2：验证门禁

### 可复现本地门禁

- [x] 精确验证两种 Device Flow 编码、client ID、scope、User-Agent 和 polling error。
- [x] 精确验证模型发现、非流和流式请求的 profile headers。
- [x] 验证旧 payload 默认值、未知 profile拒绝、exchange刷新保留profile、direct OAuth不刷新。
- [x] 验证 direct OAuth 401 的 generation fencing、credential失效和cache invalidation。
- [x] 验证 Admin profile传播、加密payload、禁用开关和错误映射。
- [x] 运行受影响包测试、Dashboard构建和 `make validate`。

### 目标环境门禁

- [ ] 使用独立且已分配 Copilot seat 的账号完成 OpenCode Device Flow。
- [ ] 同一 credential分别验证 Codex Responses text/stream/function tool 与当前已签约resume能力。
- [ ] 同一 credential分别验证 Claude Code Messages text/stream/tool use。
- [ ] 验证模型发现、capability snapshot、客户端取消、token撤销后的401与重新授权。
- [ ] 如形成release，运行现有fixed-CLI兼容门禁和不可变release attestation。

## 当前证据

- 2026-09-01：完成只读代码考古及参考实现/上游OpenCode合同核对。确认现有实现只有单一VS Code OAuth identity；credential refresh和Provider headers尚未按profile区分。
- 2026-09-01：冻结本切片范围和停止条件。当前没有代码变更证据，未执行测试。
- 2026-09-01：实现有界auth profile、token mode、OpenCode JSON Device Flow与模型请求header policy；旧payload默认值和未知值fail-closed规则已固定。定向命令 `go test ./internal/provider/copilot -run 'Test(AuthClientDeviceFlowAndCopilotExchange|OpenCodeDeviceFlowUsesFixedJSONContractAndDirectOAuth|ResolveCredentialAuthCompatibilityAndValidation|FetchCopilotModels|FetchCopilotModelsUsesOpenCodeIdentityHeaders)$' -count=1` 通过。完整包测试尚未运行。
- 2026-09-01：TokenSource已携带profile/mode/generation并按profile选择refresh client；Provider completion、stream和Probe复用credential profile。direct OAuth 401通过账号锁和最新generation比较后使账号所有旧active credential过期，避免回退旧VS Code credential；延迟旧generation不会命中新credential。`go test ./internal/provider/copilot -count=1` 通过；PostgreSQL集成测试尚待执行。
- 2026-09-01：完成默认关闭的OpenCode启动配置、Admin双profile start/complete、direct OAuth `/models` 验证与加密保存、Gateway/Worker/compatcollect registry接线、Dashboard双入口和auth/operation generation fencing。`go test ./internal/api/admin -run 'Test(DeviceFlowStartRejectsUnknownAndDisabledProfiles|DecodeDeviceFlowProfileDefaultsToVSCode|OpenCodeDeviceFlowPersistsDirectOAuthCredentialIntegration)$' -count=1` 与Dashboard `npm run build`通过；本地PostgreSQL测试环境中没有skip。
- 2026-09-01：完成一次有界只读review并修复范围内问题：非2xx OAuth polling error先解析为typed error；Dashboard secret与Device Flow响应增加auth/operation generation和abort fencing；`/models` 401复用credential generation失效；local cache使用invalidation epoch阻止旧load覆盖新失效通知；Worker模型发现继续绑定OpenSession冻结的credential generation。最窄 `go test ./internal/provider/copilot ./cmd/worker -count=1` 通过。
- 2026-09-01：第二次有界review修复延迟401本地cache残留、Worker probe 401委托、OAuth 5xx误分类、terminal Device Flow session清理和禁用profile仍显示入口。最终 `COMPAT_GATEWAY_BUILD=2026.08.18.1 COMPAT_CLI_BINARIES_FILE=/var/tmp/ghcp-p3-cli/cli-binaries.json make -C /home/azureuser/Playground/ghcp-pool-proxy validate` 以exit 0通过：lint 0 issues、全部Go race tests、Dashboard 27 tests/build、静态兼容与fixed-CLI fake collection、release manifest、VM部署和Kubernetes manifest门禁均通过。`compatibility/matrix.json`与schema/migrations未修改；fake collection不提升release或目标环境兼容等级。
- 2026-09-01：最终sanity review发现terminal 409分支仍可能用旧响应清除新session；已在该分支消费错误前再次检查auth generation与per-account operation generation，并补充静态安全回归。更新 `start.sh` 对OpenCode开关的帮助文本后，使用同一固定CLI输入再次运行完整 `make validate`，exit 0。至此达到本地停止条件。

## 停止条件

P1代码、文档和可复现本地门禁通过后停止实现扩张。目标环境门禁因缺少真实账号或外部服务无法执行时，应明确记录为未满足，不得用fake测试提升release兼容等级或修改现有矩阵。

## 下一最小步骤

停止本地实现扩张。下一最小步骤是在隔离且已分配Copilot seat的真实账号上启用OpenCode profile，执行本计划“目标环境门禁”中的Codex Responses与Claude Code Messages smoke；在取得该证据前不得宣称目标环境或release兼容完成。
