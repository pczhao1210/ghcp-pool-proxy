# 文件索引（繁體中文）

[English](README.en.md) | [简体中文](README.zh.md) | 繁體中文

請閱讀與部署版本一同提供的文件；原始碼主分支可能已包含尚未發布的行為。

## 部署與日常操作

- [專案入口](../README.zh-TW.md)：區分原始碼倉庫與發布倉庫。
- [Azure／Linux VM 操作手冊](runbooks/azure-vm-operations.zh-TW.md)：首次部署、設定重啟、冷備份、還原、搬遷及排障。
- [人工驗證（簡體中文）](runbooks/manual-validation.zh.md)：功能驗證與證據要求。

## 行為規格

以下維持現有權威文件，不另複製參數表或功能清單：

| 主題 | English | 简体中文 |
| --- | --- | --- |
| 架構與元件邊界 | [Architecture](architecture.en.md) | [架构](architecture.zh.md) |
| 完整運維與設定 | [Operations](operations.en.md) | [运维](operations.zh.md) |
| API 協定與轉換限制 | [Protocol](protocol.en.md) | [协议](protocol.zh.md) |
| 帳號池、綁定與路由 | [Routing](routing.en.md) | [路由](routing.zh.md) |
| 客戶端相容合同 | [Compatibility](../compatibility/README.md) | [兼容矩阵](../compatibility/README.zh.md) |
| Kubernetes 部署基線 | [Kubernetes](../deploy/k8s/README.en.md) | [Kubernetes](../deploy/k8s/README.zh.md) |

## 計畫與歷史

- [集群部署計畫（簡體中文）](plans/cluster-deployment.zh.md)
- [相容性路線圖（簡體中文）](plans/compatibility-roadmap.zh.md)
- [OpenCode 上游認證計畫（簡體中文）](plans/opencode-upstream-auth.zh.md)
- [歷史與參考索引（簡體中文）](README.zh.md#参考与历史)

計畫與歷史記錄不是當前生產支援承諾；實作、測試、migration 與指定發布版本的相容證據決定實際行為。
