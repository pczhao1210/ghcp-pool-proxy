# OpenCode 上游认证：剩余验收

实现与本地可复现门禁已经完成；本页仅保留尚未完成的真实目标环境验收，不重复实现日志。认证机制见[架构](../architecture.zh.md#上游认证-profile)，启用与管理员操作见[运维](../operations.zh.md)。

## 范围

`opencode` 是管理员为池账号选择的**上游认证身份**，不是新的下游客户端 family。保留 `vscode` 兼容默认值、固定身份 header、未知值 fail closed、旧 generation 的 401 失效隔离及禁止静默回退；正常请求不新增 profile 查询或上游探测。

此验收不修改客户端矩阵、路由、RPM、并发或协议合同，也不授权终端用户选择 OAuth client ID 或上游身份。

## 待验收门禁

- [ ] 在隔离且已授权、拥有有效 Copilot seat 的账号上完成 OpenCode Device Flow。
- [ ] 同一 credential 验证 Codex Responses 与 Claude Code Messages；客户端版本、模型及 text/stream/tool/resume 范围严格取自当次[兼容矩阵](../../compatibility/matrix.json)。矩阵禁用的能力不能作为“应当通过”项。
- [ ] 验证模型发现、capability snapshot、客户端取消、token 撤销后的 401 和重新授权；迟到的旧 credential 响应不得破坏新 credential。
- [ ] 如形成新 release，收集同一不可变产物的 fixed-CLI 报告与 attestation，按[兼容说明](../../compatibility/README.zh.md)验证。

## 停止条件

先冻结账号、环境、revision 和具体用例，按[人工验证](../runbooks/manual-validation.zh.md)保存脱敏结果。可复现本地测试不替代真实账号验收，真实上游请求成功也不自动提升客户端兼容等级。未具备受控账号或有效发布证据时，本计划保持待验收，不以旧日志结案。
