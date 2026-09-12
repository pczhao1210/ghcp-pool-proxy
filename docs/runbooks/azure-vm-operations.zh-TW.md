# Azure／Linux VM 部署與操作手冊

本手冊適用於完整發布包的單台 x86_64 Linux VM + Docker Compose 部署，不涵蓋 AKS 生產驗收。指令以 Bash、預設專案名稱 `ghcp-proxy` 及資料目錄 `~/ghcp_proxy` 為例；自訂埠、路徑或專案名稱時需一併調整。

[繁體中文入口](../../README.zh-TW.md) · [文件索引](../README.zh-TW.md)

## 1. 準備 VM 與連線

1. 建立支援的 Linux VM，例如 Ubuntu 24.04 x86_64，使用 SSH 金鑰登入。容量依工作負載測試決定，參考[單機容量建議](../operations.en.md#100-account-single-vm-sizing)，不要把帳號數當作吞吐量保證。
2. 在 Azure NSG 僅允許核准的管理來源連入 SSH；不開放公網 8000／8001。若企業網路限制 SSH，使用核准的 VPN／Bastion 或管理通道，不擅自更改埠繞過政策。
3. 確認 VM 可連線至套件來源、映像 registry 與該版本所需的 GitHub／Copilot 端點。
4. 首次 SSH 連線先透過可信通道核對主機指紋。安裝工具需要 sudo；非互動安裝前先由管理員配置必要權限，不把永久停用 sudo 驗證當作通用修復。

Azure 官方指引：[Linux SSH 金鑰](https://learn.microsoft.com/azure/virtual-machines/linux/mac-create-ssh-keys)、[NSG](https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview)、[Bastion](https://learn.microsoft.com/azure/bastion/bastion-overview)。

## 2. 首次部署

取得完整[發布倉庫](https://github.com/pczhao1210/ghcp-pool-proxy)，檢出經核准的 tag 或 commit 後，在該目錄執行：

```bash
deploy/deploy.sh generate-config
deploy/deploy.sh start --install-missing
```

- 首次 `start` 也會自動產生設定；先執行 `generate-config` 是為了檢視 YAML。已有檔案時不會覆寫。
- `--install-missing` 授權安裝缺少的工具，不會解決 sudo 權限不足。已有工具可只執行 `start`。
- 部署會檢查 release manifest 與 schema、拉取指定 digest、啟動資料服務、執行 migration，再啟動應用。不要混用不同版本的 manifest、migration 或腳本。
- `.env` 保存部署密鑰、路徑與連接埠；`config.yaml` 保存非敏感啟動設定。不要提交或貼出 `.env`。

在 VM 上檢查：

```bash
docker ps --filter label=com.docker.compose.project=ghcp-proxy
curl -fsS http://127.0.0.1:8000/healthz
curl -fsS http://127.0.0.1:8000/readyz
curl -fsS -o /dev/null http://127.0.0.1:8001/
curl -fsS http://127.0.0.1:8002/healthz
```

這些檢查只證明服務健康，不代表 Copilot 帳號可呼叫所有模型。

## 3. Dashboard 與客戶端接入

在工作站設定自己的 SSH 目的地並建立通道；此視窗需保持開啟：

```bash
VM_HOST='azureuser@your-vm.example.com'
ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
  -L 8000:127.0.0.1:8000 -L 8001:127.0.0.1:8001 "$VM_HOST"
```

開啟 <http://127.0.0.1:8001/>，在可信的 VM 終端從 `.env` 取得 `ADMIN_TOKEN` 登入。Admin Token 僅供管理，不交給一般 API 使用者。

完成帳號授權與健康檢查、建立 Pool、加入帳號，再建立綁定該 Pool 的 Client 並保存其 API Key。頁面、欄位及限制以[同版本運維文件](../operations.zh.md)為準；此處不重複完整 Dashboard 教學。

客戶端使用 **Client API Key**，先從 `/v1/models` 確認模型名稱：

```bash
read -r -s -p 'Client API Key: ' GHCP_KEY
printf '\n'
curl -fsS http://127.0.0.1:8000/v1/models \
  -H "Authorization: Bearer $GHCP_KEY"
unset GHCP_KEY
```

請在可信工作站執行，不啟用 shell tracing。Claude Code／Codex 的設定與相容條件見[協定文件](../protocol.zh.md)及[相容矩陣](../../compatibility/README.zh.md)；不要只憑模型名稱推斷支援能力。

## 4. 修改設定與日常維護

| 需求 | 操作 |
| --- | --- |
| 檢視服務日誌 | `deploy/deploy.sh logs --tail-lines 200` |
| 停止並保留資料 | `deploy/deploy.sh stop` |
| 啟動目前發布版本 | `deploy/deploy.sh start` |
| 修改 YAML 或部署 `.env` | 備份原檔，於維護時段修改，再依下方停止／啟動 |
| 修改 Dashboard 設定 | 依該設定的刷新週期生效，不假設所有項目即時更新 |

修改 YAML 後使用：

```bash
deploy/deploy.sh stop && deploy/deploy.sh start
```

此流程會停止整套服務並造成停機，應先停止新請求並等待既有請求結束。只執行 `start` 不保證重啟現有容器：Compose 不會因掛載檔案內容改變而必然重建容器。不要直接複製缺少 manifest／環境變數的 `docker compose restart` 範例。

不要隨意更換 `CREDENTIAL_MASTER_KEY`；已有憑證需要原金鑰解密。`reset` 會刪除 PostgreSQL 與 Redis 資料，不是一般重啟或升級步驟。

### 舊版布林值修復

若啟動報 `cannot unmarshal !!str into bool`，檢查既有 `config.yaml`：

```yaml
github:
  opencode_device_flow_enabled: false
health:
  enabled: true
```

只把這兩個欄位改成未加引號的布林值，保留原本要啟用／停用的選擇，**不要以此片段覆蓋整份設定**。更新腳本不會自動修復既有檔案；修正後依上述流程重啟。

## 5. 備份、還原與搬遷

### 維護時段冷備份

本節提供整套資料的**停機備份**，不是線上 PostgreSQL 目錄複製。範例限定所有資料位於 `~/ghcp_proxy`；若 `.env` 指向外部資料目錄、token 檔案或自訂設定，必須另納入同一備份計畫。

先停止新請求並等待既有請求結束，在來源 VM 的發布包目錄執行：

```bash
(
  set -euo pipefail
  umask 077
  mkdir -p "$HOME/ghcp-backups"
  backup="$(mktemp -d "$HOME/ghcp-backups/cold-XXXXXXXX")"
  git rev-parse HEAD > "$backup/release-commit.txt"
  cp release-manifest.env "$backup/release-manifest.env"
  deploy/deploy.sh stop
  sudo tar --acls --xattrs --numeric-owner -czpf "$backup/runtime.tar.gz" \
    -C "$HOME" ghcp_proxy
  sudo chmod 600 "$backup/runtime.tar.gz"
  sudo tar -tzf "$backup/runtime.tar.gz" >/dev/null
  (cd "$backup" && sudo sha256sum runtime.tar.gz > runtime.sha256)
  printf 'Backup directory: %s\n' "$backup"
)
```

- 任一步驟失敗都先處理錯誤，不把部分檔案當作成功備份；檢查封存檔可讀，並在隔離環境演練還原。
- 備份包含加密金鑰和資料，必須加密存放至受控的異地位置，限制存取及保留期；雜湊不是加密。
- 一般備份完成後可在來源 VM 執行 `deploy/deploy.sh start`。若接著搬遷，來源保持停止，避免新舊兩端同時使用帳號或產生分歧資料。
- Azure 磁碟快照／VM Backup 的一致性需另外確認，不能把執行中的磁碟快照直接宣稱為應用一致備份。參考[Azure VM 備份](https://learn.microsoft.com/azure/backup/backup-azure-vms-introduction)。

### 還原或搬遷至乾淨 VM

1. 準備相同架構、相容檔案系統與 Docker／Compose；使用相同管理者 UID/GID、HOME 路徑及 PostgreSQL／Redis 版本。保留／記錄實際資料庫映像版本，不只依賴可移動的 tag。
2. 取得完整發布包，檢出備份記錄的 commit，核對 manifest。不要先啟動應用或跑 migration。
3. 以安全通道傳送備份，在備份目錄執行 `sudo sha256sum -c runtime.sha256` 核對完整性。來源 VM 保持停止。
4. 確認目標沒有運行中的應用或資料庫，且 `~/ghcp_proxy` 不存在。已有資料時先停止、另行備份並移開；**不要用 `reset` 清掉唯一副本**。
5. 從可信備份還原，保留數字擁有者、檔案權限與擴充屬性。以下 `BACKUP_DIR` 必須改成已核對的備份目錄：

   ```bash
   BACKUP_DIR="$HOME/ghcp-backups/cold-REPLACE"
   (
     set -euo pipefail
     test ! -e "$HOME/ghcp_proxy"
     sudo tar --acls --xattrs --numeric-owner -xzpf "$BACKUP_DIR/runtime.tar.gz" \
       -C "$HOME"
   )
   ```

6. 核對 `.env` 中的金鑰、資料路徑與監聽地址；搬遷時也檢查固定私網 IP 和外部 token 檔案。若另有 PostgreSQL 邏輯還原需求，應只啟動必要資料服務、保持 gateway/admin/worker 停止，檢查 `pg_restore` 成功後才啟動應用，不能先用 `deploy.sh start` 建空庫再線上還原。
7. 執行 `deploy/deploy.sh start`，完成第 2 節健康檢查，再核對帳號／Pool／Client、憑證可用性與一筆受控模型請求。成功後才切換客戶端；來源保留但不重新啟動。

不要對運行中的 PostgreSQL／Redis 資料目錄直接 `rsync`。回復點之後的寫入不在備份內；回切前先決定如何處理新端已接受的請求和用量。

## 6. 升級與回滾

1. 檢視新版本說明、schema 相容性及可回滾範圍，先完成備份。
2. 在維護時段停止流量與服務，再檢出核准的新發布 commit。
3. 執行 `deploy/deploy.sh start`，檢查 migration、健康與業務請求；單機 Compose 升級不是零停機滾動更新。
4. migration 失敗時停止操作，不以 `reset`、手改 schema marker 或混用舊映像強行啟動。

只有 schema 與資料合同仍相容時才可直接回退發布版本；否則依第 5 節還原匹配的資料與金鑰，接受回復點之後的資料損失。詳見[回滾原則](../operations.en.md#rollback-principles)。

## 7. 排障入口

| 症狀 | 先查什麼 |
| --- | --- |
| 非互動安裝失敗 | 權限與缺少工具；`--install-missing` 不等於取得 sudo 權限 |
| 設定載入失敗 | YAML 類型、未知欄位與同版本設定合同；非法布林輸入應在產生檔案前失敗 |
| Dashboard 無法連線 | SSH 通道、VM 回環健康端點，再查容器日誌 |
| 401 | 區分 Admin Token 與 Client API Key，確認 Client 啟用狀態 |
| 429／無可用帳號 | 同版本文件中的 Pool、帳號健康、RPM、並發及綁定條件 |
| 502／串流失敗 | 保存 `X-Request-ID`，從 gateway 日誌區分上游錯誤與協定轉換限制 |
| 磁碟不足 | 資料目錄、Docker 日誌、每小時日誌及保留策略，不直接刪資料庫檔案 |

`semantic_compatibility_error` 不一定只有一種原因。若日誌明確指向 Claude thinking 區塊的跨協定轉換，依[協定合同](../protocol.zh.md)選擇支援的入口；不要把所有 502 都歸因於 thinking，或全域切換上游 API。
