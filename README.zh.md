<!-- Runtime release README；链接相对于发布包根目录。 -->
# GHCP Pool Proxy VM 运行包

这是 GHCP Pool Proxy 的纯运行期 VM 发布仓库，使用预构建 Docker Hub 镜像，不包含应用源码和本地构建工具。

中文 | [English](README.en.md)

## 目录

- [快速开始](#快速开始)
- [发布内容](#发布内容)
- [配置边界](#配置边界)
- [日常运维](#日常运维)

## 快速开始

在支持的 x86_64 Linux VM 上执行：

```bash
chmod +x deploy/deploy.sh
if [ ! -f "$HOME/ghcp_proxy/config.yaml" ]; then
  deploy/deploy.sh generate-config
fi
# 启动前检查 ~/ghcp_proxy/config.yaml。
deploy/deploy.sh start
```

`generate-config` 不依赖 Docker。它会创建 `~/ghcp_proxy/config.yaml`，不会覆盖已有文件；缺少该文件时 `start` 会拒绝启动。

Dashboard 地址为 `http://<server>:8001/`，模型 API 地址为 `http://<server>:8000/`。

## 发布内容

| 路径 | 用途 |
| --- | --- |
| `deploy/deploy.sh` | VM 初始化、配置生成、迁移、生命周期和日志命令 |
| `deploy/docker-compose.vm.yml` | PostgreSQL、Redis、Gateway、Admin 和 Worker 服务 |
| `config.example.yaml` | 与 `generate-config` 使用同一生成逻辑的 VM 启动默认值 |
| `migrations/` | 当前 schema 基线、版本标记和编号 migration SQL |
| `docs/` | 架构、运维、协议和路由文档 |

部署时会拉取以下镜像：

- `pczhao1210/ghcp-pool-proxy:gateway-latest`
- `pczhao1210/ghcp-pool-proxy:admin-latest`
- `pczhao1210/ghcp-pool-proxy:worker-latest`

## 配置边界

- `~/ghcp_proxy/config.yaml`：Provider 端点、超时、连接与队列容量、维护 fallback 和日志配置。
- `~/ghcp_proxy/.env`：自动生成的密钥、宿主机路径、端口以及 PostgreSQL/Redis 地址。
- PostgreSQL：Dashboard 管理的预算、feature flags、模型目录、URL、key 和 retention override。

请保护好 `.env`。已有凭据数据后，不要随意替换 `CREDENTIAL_MASTER_KEY`。

## 日常运维

```bash
deploy/deploy.sh logs
deploy/deploy.sh stop
deploy/deploy.sh start
```

发布更新流程：更新发布文件、检查随包 migration、备份 PostgreSQL，再运行 `deploy/deploy.sh start`。`~/ghcp_proxy` 下已有的 `.env` 和 `config.yaml` 会被保留。

Reset 会永久删除 PostgreSQL 和 Redis 运行数据：

```bash
GHCP_RESET_CONFIRM=reset deploy/deploy.sh reset
```

详细说明见[运维文档](docs/operations.zh.md)、[功能说明](FEATURES.zh.md)、[协议文档](docs/protocol.zh.md)和[路由文档](docs/routing.zh.md)。