# 人工验证

本页只维护可复用的验证步骤，不记录已完成阶段、某次发布结果或固定模型清单。客户端合同及证据要求由[兼容说明](../../compatibility/README.zh.md)维护，未完成工作由[兼容路线图](../plans/compatibility-roadmap.zh.md)与[集群计划](../plans/cluster-deployment.zh.md)维护。

## 验证边界

开始前冻结待测 Git revision / release manifest、客户端与协议范围、预期结果、选定门禁和停止条件。一次只闭环一个可复现反例，不把新的理论组合扩成当前验收要求。

- 本地确定性测试和固定 CLI + FakeProvider 是发布验证基础，不需要真实 Copilot 凭据。
- 真实目标环境检查是显式授权的可选补充，需要操作者提供私有凭据文件；不得自动发现其他账号。
- 不把临时探针结果、人工文字结论或旧报告当作新 release 的兼容证据。
- 对外报告仅保留脱敏元数据；不得提交 token、私有 key 文件、prompt、原始请求/响应或完整会话。

## 目标身份与最小模型请求

在受控网络内检查 Gateway：

```bash
curl -fsS http://127.0.0.1:8000/version
curl -fsS http://127.0.0.1:8000/healthz
curl -fsS http://127.0.0.1:8000/readyz
```

`/version` 返回 `version`、`build_time`、`git_revision`，**不返回 schema**。将构建字段与待测发布身份核对；通过 migration 状态与发布 manifest 单独核对 schema。任一身份不匹配时停止，不用修改报告字段来绕过。

按[矩阵](../../compatibility/matrix.json)选择精确客户端版本、profile、pool 与 exposed model，使用该 profile 的 scoped Gateway key 验证模型发现及最小请求：

- 模型发现只宣告已启用的映射与能力。
- 流式响应有合法 terminal event；取消、认证失败和不完整流不能伪装成成功。
- tools、MCP、WebSocket、`compact`、`count_tokens` 等只在当前合同允许时验证，不能以人工检查为由解除禁用。
- 原始探针成功不等于客户端兼容；需要对应的固定 CLI 用例与不可变 release 证据。

## 可选真实账号能力探针

源码根目录的 `manual_test.sh` 是外置人工工具，不随运行包提供。它临时编译 helper，复用指定 Worker 容器的配置、加密 credential、token 刷新及 Provider 实现，**直接请求 Copilot，不经过 Gateway、Router 或 client profile**。

前提：完整源码树、Go、Docker / Compose、正在运行且配置了已授权真实 credential 的 Worker，以及操作者指定的账号 UUID。脚本不自动挑选账号。

先检查 helper 编译；此命令不连接数据库或 GitHub：

```bash
./manual_test.sh --check
```

开发 Compose 默认路径：

```bash
./manual_test.sh ACCOUNT_UUID
```

VM Compose 与私有报告示例：

```bash
COMPOSE_FILE=deploy/docker-compose.vm.yml \
  PROBE_INTERVAL=15s \
  ./manual_test.sh ACCOUNT_UUID /tmp/ghcp-direct-capabilities.json
```

模型与场景以脚本中的注册表为准，不在文档复制另一份清单。`PROBE_MODEL` 和 `PROBE_SCENARIO` 可选择精确目标；无匹配项在连接数据库或 GitHub 前失败。脚本先取 `/models`，不以相近模型替代不可见 ID；请求串行，默认间隔 15 秒、最低 10 秒。

脚本将 JSON 打印到 stdout，并以 `0600` 写入报告。`catalog.raw` 和诊断细节属于**私有原始诊断**；文件权限不能保护被终端录制、CI 日志或会话记录复制的 stdout。不要在公开流水线运行或上传原始报告，需要共享时另行提取脱敏结果。

- 退出码 `0`：目录可见的目标全部通过。
- 退出码 `2`：至少一个目标不可见或探测失败。
- 其它非零：配置、credential、数据库、目录请求或执行环境失败。

检查 `probes[].catalog_match/upstream_api/scenario/result/error` 与 `summary`。这些结果只支持所执行的样例；图片、取消、并行/多轮工具、客户端恢复及完整 CLI 合同仍需要各自测试。查看 JSON 时优先使用本地查看器，不把原始 MCP dump 或 private report 附入发布证据。

若需定位 Gateway 的 MCP/tool 流式差异，可另用源码中的 `scripts/probe_stream_mcp.py`；它不同于直连账号探针。先查看工具帮助、核对已获批准的模型与工具合同，原始 dump 只留在私有临时目录；无需在协议规格中复制固定模型列表或原始输出命令。

## 迁移与部署验收

在隔离环境使用待测 release 自带的部署入口与 migration runner，不复制旧阶段的 schema 数字或 SQL：

| 用例 | 必须确认 |
| --- | --- |
| 空数据库 | 完整迁移到 manifest 要求的版本，migration history 与 schema 一致 |
| 明确支持的旧版本 fixture | 旧数据、Client-to-Pool 关系与凭据仍可用，升级符合 manifest 路径 |
| 重复运行 | migration 幂等，不重复建表或伪造成功 |
| 不支持的旧版本、半成品或身份不匹配 | 拒绝继续，不手写 schema marker 绕过 |
| 启动后检查 | Gateway/Admin/Worker 就绪，数据库与 Redis 依赖正常；HTTP 健康不替代模型调用验收 |
| 故障恢复 | 备份包含一致的数据与配套私钥；按[冷备份/恢复流程](azure-vm-operations.zh-TW.md)演练 |

独立设置测试项目名、端口和数据路径。只清理本次创建并已核实的资源，禁止针对共享生产目录执行 reset 或数据覆盖。升级入口、版本支持及回滚限制详见[运维](../operations.zh.md#发布与迁移)；Kubernetes 的持久化、故障域与生产批准由集群计划单独约束。

## 可选目标环境证据

需要机器可验证的目标环境报告时，使用 `make compat-target-collect` / `make compat-target-validate`，参数、字段、有效期与 release 绑定方式统一见[兼容说明](../../compatibility/README.zh.md)。报告必须来自真实 collector 输出，不手填 passed 状态。

目标环境报告不会自动替代固定 CLI 证据，也不会把静态 candidate level 提升为某个 release 的有效等级。完成选定门禁后停止；新增兼容能力或未通过的生产环境门禁另行立项。
