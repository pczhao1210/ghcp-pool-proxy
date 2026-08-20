# 兼容性路线图

> 状态：Phase 7 已完成；仅在新的 release、matrix/schema/build 变化或经批准的新能力出现时创建新的兼容性任务。
>
> 最近确认：2026-08-19

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