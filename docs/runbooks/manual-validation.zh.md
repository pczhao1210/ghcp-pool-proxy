# 手动测试指南

## 范围

本指南说明使用真实 GitHub Copilot 账号、Gateway API key 或已部署环境的可选检查。它们不属于 `make validate`、release evidence 创建或 `make release-validate` 的必需项。

必需发布路径是确定且无凭据的：干净源码树、digest 绑定的 release manifest，以及覆盖全部候选 matrix entry 的干净 fixed-CLI report。真实账号检查可以为 attestation 增加可选 environment artifact，但绝不能替代 fixed CLI gate。

## 当前状态

截至 2026-08-17，P1 不要求真实账号、凭据、Provider probe 或已部署 Gateway 检查。可选 evidence 实现属于候选版本 `2026.08.17.4`；仓库中未加入任何凭据值或真实账号结果。P1 剩余自动化工作为 `.4` 源码 freeze、干净 fixed-CLI report、schema 2 attestation 和 `make release-validate`。

## 安全规则

- 使用隔离的测试 profile、pool 和账号。不得针对共享生产 pool 测试。
- 不得将 token、cookie、API key、authorization header、账号名称、prompt、tool 参数或原始响应写入本仓库、issue tracker、聊天记录、shell history 或报告。
- 临时 profile-key 文件必须存放在仓库外、权限设为 `0600`，测试后删除。
- 不得尝试 CAPTCHA、2FA、反检测、credential stuffing 或其他未经授权的访问流程。
- 已部署 Gateway 的版本、Git SHA、schema、模型映射、profile 或 pool 与预期 release manifest 不一致时，立即停止测试。

## 可选目标环境预检

仅在当前 shell 设置非敏感值。敏感值应直接在终端输入或保存在受保护的本地文件中；绝不可粘贴到本文件。

```sh
export GATEWAY_URL=https://gateway.example.invalid
export EXPECTED_BUILD=2026.08.17.4
```

在任何认证请求前验证已部署身份：

```sh
curl --fail --silent --show-error "$GATEWAY_URL/version"
```

预期结果：响应标识预期的 immutable build、Git SHA 和 schema 19。任一值与 release manifest 不一致时停止。

## 可选模型与请求检查

使用本地提供的 scoped Gateway key，验证隔离的 `codex-candidate` profile 只暴露预期的 `gpt-5.5 / responses` 映射。随后使用 Codex 0.147.0 的精确 user agent 发起一个最小 streamed `/v1/responses` 请求。

预期结果：

- model discovery 返回该映射模型，且不宣告 `function_tools`、WebSocket 等已禁用能力；
- 请求抵达正常 Responses terminal event，或返回已记录且经过脱敏的错误；
- 取消、认证失败或不完整 stream 不得表现为成功的 completed response；
- 日志或报告中不得写入真实凭据、prompt 或原始 upstream payload。

不得借此手动检查启用 tools、MCP、WebSocket、`compact`、`count_tokens` 或 matrix 中仍保持禁用的其他能力。

### 真实账号未知能力探针

根目录的 `manual_test.sh` 是外置人工工具，不是服务命令。它不调用 Gateway，也不依赖 client profile、pool 路由或 Gateway API key。脚本在运行时临时编译一个 helper，复用 Worker 容器已有的配置、PostgreSQL credential、credential master key、Copilot token 刷新和 Provider 请求实现；退出时删除临时源码与容器内二进制。

脚本严格执行以下顺序：

1. 直接请求 Copilot `/models`，将原始 JSON 写入报告的 `catalog.raw`；
2. `gpt-5.4`，使用 Responses API；
3. `gpt-5.6-terra`，使用 Responses API；
4. `claude-sonnet-4.6`，使用 Anthropic Messages API；
5. `claude-opus-4.8`，使用 Anthropic Messages API；
6. `gemini-3.5-flash`，使用 Chat Completions API。

每个可见模型按顺序执行基础文本、流式终态和强制 function tool；两个 GPT 目标追加 reasoning，两个 Claude 目标追加 thinking，共 19 个生成场景。所有请求串行执行，每次请求前默认等待 15 秒；`PROBE_INTERVAL` 最低为 10 秒。模型 ID 必须与 `/models` 返回值精确匹配；目录中不存在的目标记录为 `model_not_visible`，不会用相近模型替代，也不会发送生成请求。

前置条件：

- 当前目录是包含 `manual_test.sh`、`go.mod` 和 `internal/` 的源码树；
- Go、Docker 和 Docker Compose 可用；
- 待测栈的 Worker 容器正在运行，且已配置真实账号 credential；
- 已取得待测账号 UUID。脚本只测试该 UUID，不经过 Router 选择账号。

先验证外置 helper 能编译；该命令不连接数据库或 GitHub：

```bash
./manual_test.sh --check
```

使用开发 Compose 默认路径执行：

```bash
./manual_test.sh ACCOUNT_UUID
```

使用 VM Compose 或自定义报告路径执行：

```bash
COMPOSE_FILE=deploy/docker-compose.vm.yml \
	PROBE_INTERVAL=15s \
	./manual_test.sh ACCOUNT_UUID /tmp/ghcp-direct-capabilities.json
```

脚本同时向标准输出打印 JSON，并以 `0600` 权限写入报告。退出码含义：`0` 表示所有目录可见目标均通过，`2` 表示至少一个目标不可见或探测失败，其它非零值表示配置、credential、数据库、目录请求或执行环境失败。

重点查看：

- `catalog.raw.data`：Copilot 返回的原始模型 ID、展示名和能力元数据；
- `probes[].catalog_match`：固定目标是否在目录可见；
- `probes[].upstream_api`：实际使用的原生协议；
- `probes[].scenario`：`text`、`streaming`、`tool`、`reasoning` 或 `thinking`；
- `probes[].result`：`supported`、`model_not_visible` 或 `failed`；
- `probes[].error`：HTTP 状态、Provider 错误类型和诊断细节；
- `summary`：所有已执行场景的最终计数。

该报告用于提出模型/协议合同变更，不直接证明完整客户端兼容。它只证明这些最小 streaming、function tool、reasoning/thinking 样例；MCP、图片、取消、并行工具、多轮工具结果、Claude Code `--resume`、Codex encrypted-reasoning fallback 和完整 CLI 合同仍需各自的兼容门禁。

## P2.4 Compose/VM 迁移运行时手动验收（中文）

这是 P2 的剩余退出门禁。当前仓库的 Go migration integration test、Kubernetes overlay 和本地开发 Compose 不能替代 VM release runtime 检查：后者还验证固定镜像、release manifest、`deploy.sh`、`.env` 生成、DSN 临时文件挂载和宿主机持久化目录。

### 安全边界

- 只在新建、一次性、x86_64 Linux 测试 VM 执行。不得使用开发共享 Docker project、staging、生产 VM、生产 dump、真实账号或真实凭据。
- schema `18 -> 19` 只能使用已审阅、仅含测试数据的 PostgreSQL 16 schema-18 dump，或已验证的 schema-18 测试 release 包。禁止通过修改 `system_settings.schema_version`、清空 `migration_history` 或运行旧 shell DDL 伪造 schema-18。
- 全程使用 `set +x`；不回显、提交或记录 `.env`、DSN、token、credential master key 或 dump 内容。
- 任一步失败后停止本场景，保留脱敏日志和 exit code；先执行清理，再排查。不要在同一数据目录上试探性重跑。

### 1. 开发 Compose：空库与重复 migration

在当前 P2 工作树根目录执行。该场景仅启动 PostgreSQL 与 migration service，不启动 Gateway/Admin/Worker。

```bash
set -euo pipefail
set +x
RUN_ID="p2-compose-$(date -u +%Y%m%d%H%M%S)"
export COMPOSE_PROJECT_NAME="$RUN_ID"
export MIGRATION_TARGET_VERSION=19
export MIGRATION_PHASE=expand
DSN_FILE="$(mktemp)"
chmod 600 "$DSN_FILE"
printf '%s\n' 'postgres://ghcp:ghcp@postgres:5432/ghcp?sslmode=disable' > "$DSN_FILE"
export MIGRATION_DSN_HOST_FILE="$DSN_FILE"
cleanup_compose() {
	docker compose -p "$COMPOSE_PROJECT_NAME" -f deploy/docker-compose.yml down -v --remove-orphans || true
	rm -f "$DSN_FILE"
}
trap cleanup_compose EXIT

docker compose -p "$COMPOSE_PROJECT_NAME" -f deploy/docker-compose.yml up -d postgres
docker compose -p "$COMPOSE_PROJECT_NAME" -f deploy/docker-compose.yml run --rm --build migration
docker compose -p "$COMPOSE_PROJECT_NAME" -f deploy/docker-compose.yml exec -T postgres \
	psql -U ghcp -d ghcp -Atc "SELECT value FROM system_settings WHERE key = 'schema_version';"
FIRST_COUNT="$(docker compose -p "$COMPOSE_PROJECT_NAME" -f deploy/docker-compose.yml exec -T postgres \
	psql -U ghcp -d ghcp -Atc "SELECT count(*) FROM migration_history WHERE status = 'succeeded';")"
test "$FIRST_COUNT" -gt 0

docker compose -p "$COMPOSE_PROJECT_NAME" -f deploy/docker-compose.yml run --rm migration
SECOND_COUNT="$(docker compose -p "$COMPOSE_PROJECT_NAME" -f deploy/docker-compose.yml exec -T postgres \
	psql -U ghcp -d ghcp -Atc "SELECT count(*) FROM migration_history WHERE status = 'succeeded';")"
test "$FIRST_COUNT" = "$SECOND_COUNT"
```

预期：schema 查询为 `19`；两次 migration 成功；第二次未新增 succeeded migration history；退出 trap 后专用容器、network、volume 和 DSN 文件均被清理。

若持有受控 `SCHEMA18_SQL_DUMP`，在同一隔离 Compose project 内、第一次 migration 前导入该 test-only dump，先查询并确认 `schema_version = 18`，再运行 migration。运行后必须确认 schema 为 `19`，且 migration `19` 的 status 为 `succeeded`。不得导入真实数据。

### 2. 一次性 VM：空库、`18 -> 19` 与重复启动

准备两个受控 runtime release 包：当前 P2 包 `CANDIDATE_DIR`，以及已验证 schema-18 测试包 `SCHEMA18_DIR`。两者都必须有自身的 `release-manifest.env`；不要混用镜像、Git SHA 或 schema。

先验证当前 P2 包的空库初始化和重复启动：

```bash
set -euo pipefail
set +x
export CANDIDATE_DIR=/opt/ghcp-p2-candidate
RUN_ID="p2-vm-empty-$(date -u +%Y%m%d%H%M%S)"
export COMPOSE_PROJECT_NAME="$RUN_ID"
export GHCP_PROXY_HOME="/var/tmp/$RUN_ID"
test ! -e "$GHCP_PROXY_HOME"

"$CANDIDATE_DIR/deploy/deploy.sh" generate-config --data-dir "$GHCP_PROXY_HOME"
"$CANDIDATE_DIR/deploy/deploy.sh" start --data-dir "$GHCP_PROXY_HOME"
docker compose --env-file "$GHCP_PROXY_HOME/.env" -p "$COMPOSE_PROJECT_NAME" \
	-f "$CANDIDATE_DIR/deploy/docker-compose.vm.yml" exec -T postgres \
	psql -U ghcp -d ghcp -Atc "SELECT value FROM system_settings WHERE key = 'schema_version';"
FIRST_COUNT="$(docker compose --env-file "$GHCP_PROXY_HOME/.env" -p "$COMPOSE_PROJECT_NAME" \
	-f "$CANDIDATE_DIR/deploy/docker-compose.vm.yml" exec -T postgres \
	psql -U ghcp -d ghcp -Atc "SELECT count(*) FROM migration_history WHERE status = 'succeeded';")"
"$CANDIDATE_DIR/deploy/deploy.sh" start --data-dir "$GHCP_PROXY_HOME"
SECOND_COUNT="$(docker compose --env-file "$GHCP_PROXY_HOME/.env" -p "$COMPOSE_PROJECT_NAME" \
	-f "$CANDIDATE_DIR/deploy/docker-compose.vm.yml" exec -T postgres \
	psql -U ghcp -d ghcp -Atc "SELECT count(*) FROM migration_history WHERE status = 'succeeded';")"
test "$FIRST_COUNT" = "$SECOND_COUNT"
"$CANDIDATE_DIR/deploy/deploy.sh" stop --data-dir "$GHCP_PROXY_HOME"
```

预期：两次 `start` 均通过 migration、Gateway readiness 与 Admin dashboard 检查；schema 为 `19`；第二次没有新增 succeeded migration。

在另一个全新的 `GHCP_PROXY_HOME` 和 `COMPOSE_PROJECT_NAME` 上验证实际升级路径：

```bash
set -euo pipefail
set +x
export SCHEMA18_DIR=/opt/ghcp-schema18-test-fixture
UPGRADE_ID="p2-vm-upgrade-$(date -u +%Y%m%d%H%M%S)"
export COMPOSE_PROJECT_NAME="$UPGRADE_ID"
export GHCP_PROXY_HOME="/var/tmp/$UPGRADE_ID"
test ! -e "$GHCP_PROXY_HOME"

"$SCHEMA18_DIR/deploy/deploy.sh" generate-config --data-dir "$GHCP_PROXY_HOME"
"$SCHEMA18_DIR/deploy/deploy.sh" start --data-dir "$GHCP_PROXY_HOME"
docker compose --env-file "$GHCP_PROXY_HOME/.env" -p "$COMPOSE_PROJECT_NAME" \
	-f "$SCHEMA18_DIR/deploy/docker-compose.vm.yml" exec -T postgres \
	psql -U ghcp -d ghcp -Atc "SELECT value FROM system_settings WHERE key = 'schema_version';"
"$SCHEMA18_DIR/deploy/deploy.sh" stop --data-dir "$GHCP_PROXY_HOME"

"$CANDIDATE_DIR/deploy/deploy.sh" start --data-dir "$GHCP_PROXY_HOME"
docker compose --env-file "$GHCP_PROXY_HOME/.env" -p "$COMPOSE_PROJECT_NAME" \
	-f "$CANDIDATE_DIR/deploy/docker-compose.vm.yml" exec -T postgres \
	psql -U ghcp -d ghcp -Atc "SELECT value FROM system_settings WHERE key = 'schema_version';"
docker compose --env-file "$GHCP_PROXY_HOME/.env" -p "$COMPOSE_PROJECT_NAME" \
	-f "$CANDIDATE_DIR/deploy/docker-compose.vm.yml" exec -T postgres \
	psql -U ghcp -d ghcp -Atc "SELECT status FROM migration_history WHERE migration_id = 19;"
"$CANDIDATE_DIR/deploy/deploy.sh" start --data-dir "$GHCP_PROXY_HOME"
"$CANDIDATE_DIR/deploy/deploy.sh" stop --data-dir "$GHCP_PROXY_HOME"
```

预期：旧包启动后的 schema 为 `18`；当前 P2 包首次启动后为 `19`，migration `19` 为 `succeeded`；第二次当前包启动成功且不新增 succeeded migration。任何 schema、release manifest identity 或 readiness 不符合预期即失败。

### 3. 记录与清理

每个场景结束后，仅删除本节创建的 `/var/tmp/p2-vm-*` 目录和专用 Compose project；不要对任何非测试目录执行 `reset` 或 `rm -rf`。记录 UTC 时间、release manifest 的非敏感 identity、场景名、schema 查询值、migration status、两次 history count 是否相等、Gateway/Admin readiness 与命令 exit code。不要记录 `.env`、DSN、凭据、真实账号或 dump 内容。

### 4. P2.4 人工验收记录（2026-08-18）

状态：**通过（用户确认）**。

已提供的脱敏 Compose 记录使用一次性 project `p2-compose-20260818085919`：空库 migration 输出 schema `19`，第二次 migration 输出 `starting_schema=19 target_schema=19 applied=[]`，整体命令 exit code 为 `0`。记录中 history-count 比较的末尾在粘贴时损坏，因此不将其作为两次 count 相等的独立证据。P2 阶段退出以用户对本人工 gate 的明确通过确认登记；本节保留完整 VM、schema `18 -> 19` 和运行包复验步骤，供后续 release 再次执行。

## 可选环境报告

当存在受控目标环境时，在本地创建权限为 `0600` 的 scoped key 文件并运行：

```sh
COMPAT_GATEWAY_URL="$GATEWAY_URL" \
COMPAT_GATEWAY_PROFILE_KEYS_FILE=/secure/ghcp-compat-profile-keys.json \
COMPAT_ENVIRONMENT_REPORT=/secure/ghcp-compat-environment.json \
make compat-target-collect
```

收集器会检查 active 和 binding-reserved 账号的模型可见性、一次最小 Provider probe 以及一次最小已部署 Gateway 请求。它生成经过脱敏、具备时限的报告；证据不完整时必须失败，不能发布部分 evidence。

此命令是可选的。成功报告可通过为 `make compat-evidence-create` 和 `make release-validate` 设置 `COMPAT_ENVIRONMENT_REPORT` 而绑定到 attestation；省略它不会改变无凭据发布路径。

## 记录与清理

仅记录 release manifest identity、命令 exit status、UTC 时间和脱敏 error class。不得记录账号标识或请求内容。

审阅窗口结束后，删除临时 profile-key 文件和可选报告。按照正常运维流程撤销或轮换任何 scoped test key。