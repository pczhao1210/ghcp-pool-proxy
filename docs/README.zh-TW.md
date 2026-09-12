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

## 有效計畫與提案

- [集群部署計畫（簡體中文）](plans/cluster-deployment.zh.md)
- [相容性路線圖（簡體中文）](plans/compatibility-roadmap.zh.md)
- [OpenCode 認證：剩餘目標環境驗收（簡體中文）](plans/opencode-upstream-auth.zh.md)
- [Ultra 性能提案（尚未實作，簡體中文）](proposals/ultra-performance.zh.md)

計畫與提案不是生產支援承諾；程式碼、可重現測試與 migration 決定實作及資料契約，matrix 決定候選能力，指定不可變發布的外置 attestation 決定有效相容等級。

## 維護原則

每項詳細規則由上方對應文件維護，入口與翻譯不另複製模型、API 或驗證清單。計畫只保留尚未完成的工作與驗收門檻；完成後將必要的設計理由移入正式文件，刪除過程日誌，舊紀錄由 Git 歷史保留。完整[維護規則（簡體中文）](README.zh.md#维护规则)亦適用於繁體中文文件。
