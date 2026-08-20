# 兼容性矩阵

[matrix.json](matrix.json) 是静态客户端合同的唯一事实源。它把 runtime contract 与精确客户端版本分离：前者定义 profile、pool、模型、路由、能力和 typed wire contract，后者定义客户端家族、版本、安装来源、静态等级和证据身份。运行时只用 profile、模型和上游 API 查找合同；Codex 与 Claude Code 都不按精确客户端版本路由。版本条目只保留 fixed-CLI 发布证据的可审计身份。

## 当前边界

- Codex `0.147.0 + gpt-5.5 + Responses` 的静态等级为 `candidate_native`。模型发现或单次真实请求不会改变该等级。
- Claude Code `2.1.225`、`2.1.226` 和 `2.1.233` 在 `--resume` 请求未签约的 `claude-opus-5`，当前均为 `unsupported`。网关不会用 Sonnet 首轮成功伪造多轮兼容。
- `count_tokens`、`compact`、WebSocket 和 Codex 动态工具回调都不在当前 HTTP 网关合同内。
- `require_fresh` profile 会使用不可变请求快照，要求候选账号对解析后的模型/API 具有当前完整证据；`allow_unknown` 是显式兼容策略。

协议保真、转换和 fail-closed 规则见 [协议文档](../docs/protocol.zh.md)，活动边界与新任务触发条件见 [兼容性路线图](../docs/plans/compatibility-roadmap.zh.md)。已关闭实施切片与历史证据见 [Phase 7 执行历史](../docs/history/phase-7-execution-log.zh.md)。

## 发布证据

静态矩阵不会自行产生 `verified_native`。一个不可变 release 的有效等级只能由外置 attestation 派生，它必须绑定同一身份的：

1. 四角色 digest release manifest；
2. clean fixed-CLI report；
3. matrix payload、build、Git SHA 与 schema；
4. 可选的脱敏目标环境报告。

外置 attestation 和报告不能提交到仓库。真实 Copilot、目标 VM 和 deployed Gateway 的人工验证属于可选环境证据，不能替代 fixed-CLI gate；步骤见 [人工验证](../docs/runbooks/manual-validation.zh.md)。

## 最小验证路径

```sh
make compat-validate

COMPAT_GATEWAY_BUILD=<immutable-build> \
COMPAT_CLI_BINARIES_FILE=/secure/ghcp-cli-binaries.json \
make compat-test

COMPAT_RELEASE_MANIFEST=/secure/release-manifest.env \
COMPAT_FAKE_CLI_REPORT=/secure/ghcp-compat-fake-cli.json \
COMPAT_RELEASE_EVIDENCE=/secure/ghcp-release-evidence.json \
make release-validate
```

`COMPAT_CLI_BINARIES_FILE` 必须是仓库外、权限为 `0600` 的 manifest，明确绑定每个矩阵 entry 的 CLI 与 runtime 路径、版本和 SHA-256。收集器不会从环境 `PATH` 任意选择 CLI。

英文命令说明和完整输入合同见 [README.md](README.md)。