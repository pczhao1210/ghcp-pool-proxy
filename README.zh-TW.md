# GHCP Pool Proxy

[English](README.en.md) | [简体中文](README.zh.md) | 繁體中文

GHCP Pool Proxy 是受控 GitHub Copilot 帳號資源的 API 閘道與管理系統，提供 OpenAI Chat Completions、Responses 與 Anthropic Messages 入口。

## 選擇入口

- **部署使用者**：取得[發布倉庫](https://github.com/pczhao1210/ghcp-pool-proxy)的完整版本，依[Azure／Linux VM 操作手冊](docs/runbooks/azure-vm-operations.zh-TW.md)部署、備份及還原。
- **開發者**：在[原始碼倉庫](https://github.com/pczhao1210/ghcp-pool-proxy-codebase)修改程式與測試，再同步發布產物。發布倉庫不包含應用原始碼或建置工具。
- **查閱規格**：使用[繁體中文文件索引](docs/README.zh-TW.md)。架構、協定、路由及完整參數連至現有英文／簡體中文文件，避免多份規格不同步。

## VM 快速開始

以下在已取得的**完整發布包目錄**執行；不要只下載部署腳本或混用不同版本檔案：

```bash
deploy/deploy.sh generate-config
deploy/deploy.sh start --install-missing
```

`generate-config` 適用於首次部署；若檔案已存在，先檢視而非覆寫。`--install-missing` 允許安裝缺少的主機工具；不需要自動安裝時可省略。

Gateway 與 Dashboard 預設只監聽 VM 的回環介面，請透過 SSH 通道存取。登入、設定變更與健康檢查見[操作手冊](docs/runbooks/azure-vm-operations.zh-TW.md)。

## 版本與資料邊界

- `release-manifest.env` 綁定應用版本、原始碼 SHA、schema 與四個不可變映像 digest；腳本／文件熱修復不代表應用映像已升級。
- 持久化資料預設位於 `~/ghcp_proxy`。保護 `.env` 與其中的 `CREDENTIAL_MASTER_KEY`；遺失金鑰後無法解密已存憑證。
- YAML 啟動設定需停止後重新啟動服務才會可靠生效，會造成停機；Dashboard 的可編輯設定則依各自刷新週期生效。
- Kubernetes 清單存在不代表已完成目標環境的高可用驗收。部署範圍與門禁以[集群部署計畫](docs/plans/cluster-deployment.zh.md)為準。
