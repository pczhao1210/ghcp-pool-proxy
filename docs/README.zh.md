# 文档索引

[English](README.en.md) | [简体中文](README.zh.md) | [繁體中文](README.zh-TW.md)

## 当前行为

请阅读随部署版本提供的文档；源码 `main` 可能描述尚未发布的行为。

| 归属 | 维护内容 |
| --- | --- |
| [架构](architecture.zh.md) | 范围、组件边界、状态归属与设计理由 |
| [运维](operations.zh.md) | 配置、部署、容量、观测与排障 |
| [协议](protocol.zh.md) | 请求、响应、流式语义与转换限制 |
| [路由](routing.zh.md) | pool 选择、entitlement、亲和、绑定、RPM 与并发 |
| [兼容说明](../compatibility/README.zh.md) | 固定客户端合同、证据采集与发布资格 |

## 运行手册

- [Azure／Linux VM 操作手册（繁體中文）](runbooks/azure-vm-operations.zh-TW.md)
- [Kubernetes 操作](../deploy/k8s/README.zh.md)
- [人工验证](runbooks/manual-validation.zh.md)

## 有效计划与提案

- [集群部署计划](plans/cluster-deployment.zh.md)
- [兼容性路线图](plans/compatibility-roadmap.zh.md)
- [OpenCode 认证：剩余目标环境验收](plans/opencode-upstream-auth.zh.md)
- [Ultra 性能提案（尚未实现）](proposals/ultra-performance.zh.md)

## 维护规则

- 代码与可复现测试决定实现行为，[migrations](../migrations/) 决定部署 schema；[矩阵](../compatibility/matrix.json) 决定静态客户端合同与最高候选等级，外置且不提交的 release attestation 决定单个不可变发布的有效等级。
- 每份详细合同只在上表归属文档维护。入口与翻译优先链接，不复制模型清单、API 表、价格或完整验证日志。
- 计划只保留剩余工作、验收门禁和停止条件；runbook 只保留可重复步骤。计划或提案不是已经实现或获准生产使用的证据。
- 完成后将长期有效的设计理由移入归属文档，再删除过程计划和执行日志。旧实施与测试记录保留在 Git 历史，无需另建 `docs/history` 副本。
- 新兼容案例必须来自现有合同、可复现回归、阶段门禁或已批准 issue；先冻结范围与验证，选定门禁通过后停止。