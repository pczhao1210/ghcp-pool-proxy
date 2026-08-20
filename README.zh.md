<!-- Runtime release README；链接相对于发布包根目录。 -->
# GHCP Pool Proxy 运行包

这是 GHCP Pool Proxy 的纯运行期发布仓库，使用预构建 Docker Hub 镜像，支持 Linux VM Docker Compose、本地单节点 Kind，以及 AKS + Azure PostgreSQL/Managed Redis；不包含应用源码和本地构建工具。

中文 | [English](README.en.md)

## 目录

- [快速开始](#快速开始)
- [发布内容](#发布内容)
- [配置边界](#配置边界)
- [日常运维](#日常运维)

## 快速开始

### Linux VM

在支持的 x86_64 Linux VM 上执行：

```bash
chmod +x deploy/deploy.sh
deploy/deploy.sh start
```

首次 `start` 会自动创建 `~/ghcp_proxy/config.yaml` 和 `~/ghcp_proxy/.env`，且不会覆盖已有文件。可在首次启动前运行 `deploy/deploy.sh generate-config` 以创建并审阅 YAML；若已有持久化目录但 YAML 意外缺失，`start` 会拒绝继续，避免静默恢复默认配置。

两个部署入口默认都使用随包的 `release-manifest.env`，也都支持通过 `--release-manifest FILE` 或 `RELEASE_MANIFEST` 选择另一份不可变 release set。缺少前置组件时会先请求确认；非交互自动化需传入 `--install-missing` 才允许安装。`deploy` 是共享动作别名：VM 入口等价于 `start`，集群入口等价于 `apply`。集群的 `--yes` 只接受资源/部署确认，不授权安装工具。VM `reset` 仍保留更严格的 `GHCP_RESET_CONFIRM=reset` 删除门禁。

Gateway 和 Admin 默认只绑定 VM 回环接口。请在工作站通过 SSH 转发：

```bash
ssh -N -L 8000:127.0.0.1:8000 -L 8001:127.0.0.1:8001 <user>@<server>
```

随后通过 `http://127.0.0.1:8001/` 访问 Dashboard，通过 `http://127.0.0.1:8000/` 调用模型 API。若私有反向代理位于另一台主机，可将 `GATEWAY_BIND_ADDR` 和 `ADMIN_BIND_ADDR` 设置为经审核的私网接口，并强制使用 TLS 和防火墙限制。不要在不可信网络上明文发布 Admin。

只有 Gateway health/readiness、Admin Dashboard 和 Worker 容器健康检查全部通过后，`start` 才会报告 stack ready。

### 本地单节点 Kubernetes

```bash
deploy/deploy-cluster.sh local apply
```

脚本会检查 Docker、Kind、kubectl 和 Kustomize。缺少组件时会说明安装内容并请求确认，再根据 Linux 发行版选择包管理器；需要系统权限时使用 `sudo`。该模式创建或复用 `ghcp-local` Kind 集群，并在集群内运行一次性 PostgreSQL/Redis。

### AKS 与 Azure PaaS

```bash
deploy/deploy-cluster.sh azure apply
```

交互向导会为 resource group、VNet、三个 subnet、AKS、PostgreSQL Flexible Server 和 Azure Managed Redis 分别选择 `create` 或 `reuse`。提示中的方括号值可通过直接回车采用。交互式复用会列出当前可见的 resource group、同区域网络/服务和所选 VNet 内的 subnet，并支持输入编号选择；直接回车选择 `[1]`，输入 `0` 可改为手工填写。非交互复用仍必须通过环境变量提供 resource group 名称和完整 ARM ID。新建资源先执行 Bicep build 与 Azure what-if，确认后才 apply。新建 AKS 使用预授权的 user-assigned control-plane identity，并仅在 node subnet 范围授予 Network Contributor；复用 AKS 与 PostgreSQL 必须使用所选 VNet/subnet。复用 Redis 本体保持不变，本部署仍会创建对应 private endpoint 与 DNS attachment。敏感参数使用隐藏输入和权限为 `0600` 的临时文件，退出时删除。

## 发布内容

| 路径 | 用途 |
| --- | --- |
| `deploy/deploy.sh` | VM 初始化、配置生成、迁移、生命周期和日志命令 |
| `deploy/docker-compose.vm.yml` | PostgreSQL、Redis、Gateway、Admin 和 Worker 服务 |
| `deploy/deploy-cluster.sh` | 本地 Kind 与 Azure AKS 的交互式部署入口 |
| `deploy/azure/` | Azure 网络、AKS identity/RBAC、PostgreSQL、Managed Redis 与私网连接 Bicep |
| `deploy/k8s/` | production、staging、一次性 test overlay 与有序 rollout |
| `deploy/lib/` | 前置组件安装和 Azure 编排 helper |
| `scripts/` | release manifest 与 Gateway smoke 工具 |
| `config.example.yaml` | 与 `generate-config` 使用同一生成逻辑的 VM 启动默认值 |
| `migrations/` | 当前 schema 基线、版本标记和编号 migration SQL |
| `release-manifest.env` | 非敏感 release set：共享 app version、Git SHA、schema 版本、四个 latest tag 及对应 immutable digest |
| `docs/` | 架构、运维、协议和路由文档 |

发布构建使用以下 tag 作为四个角色的可读别名：

- `pczhao1210/ghcp-pool-proxy:gateway-latest`
- `pczhao1210/ghcp-pool-proxy:admin-latest`
- `pczhao1210/ghcp-pool-proxy:worker-latest`
- `pczhao1210/ghcp-pool-proxy:migration-latest`

启动服务前，`deploy.sh` 会验证 release manifest 的 schema 与随包 migration schema 一致，再从 manifest 为四个角色派生 `repository@sha256:...` 引用并直接拉取。tag 后续移动不会改变部署或阻断旧 bundle 按 digest 回滚。

## 配置边界

- `~/ghcp_proxy/config.yaml`：Provider 端点、超时、连接与队列容量、维护 fallback 和日志配置。
- `~/ghcp_proxy/.env`：自动生成的密钥、宿主机路径、回环监听地址、端口以及 PostgreSQL/Redis 地址。
- PostgreSQL：Dashboard 管理的预算、feature flags、模型目录、URL、key 和 retention override。

请保护好 `.env`。已有凭据数据后，不要随意替换 `CREDENTIAL_MASTER_KEY`。

## 日常运维

```bash
deploy/deploy.sh logs
deploy/deploy.sh stop
deploy/deploy.sh start
```

发布更新流程：更新发布文件、检查随包 migration、备份 PostgreSQL，再运行 `deploy/deploy.sh start`。`~/ghcp_proxy` 下已有的 `.env` 和 `config.yaml` 会被保留。

Reset 会永久删除 PostgreSQL 和 Redis 运行数据；若 `docker compose down` 无法停止服务，reset 会直接中止且不会删除任何数据目录：

```bash
GHCP_RESET_CONFIRM=reset deploy/deploy.sh reset
```

详细说明见[运维文档](docs/operations.zh.md)、[协议文档](docs/protocol.zh.md)和[路由文档](docs/routing.zh.md)。