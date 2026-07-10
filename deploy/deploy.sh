#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/deploy.sh"

ACTION="start"
ACTION_SET=0

DEFAULT_DATA_DIR="$HOME/ghcp_proxy"
DATA_DIR="${GHCP_PROXY_HOME:-${DATA_DIR:-}}"
ENV_FILE="${ENV_FILE:-}"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/docker-compose.vm.yml}"
LOCAL_MIGRATIONS_DIR="${LOCAL_MIGRATIONS_DIR:-$SCRIPT_DIR/../migrations}"
SCHEMA_VERSION_FILE_NAME="${SCHEMA_VERSION_FILE_NAME:-schema_version}"
INIT_SCHEMA_SQL_NAME="${INIT_SCHEMA_SQL_NAME:-001_init.sql}"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-ghcp-proxy}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-120}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
LOG_TAIL_LINES="${LOG_TAIL_LINES:-200}"
GATEWAY_IMAGE="pczhao1210/ghcp-pool-proxy:gateway-latest"
ADMIN_IMAGE="pczhao1210/ghcp-pool-proxy:admin-latest"
WORKER_IMAGE="pczhao1210/ghcp-pool-proxy:worker-latest"
MIGRATION_IMAGE="$ADMIN_IMAGE"
DISTRO_ID=""
DISTRO_ID_LIKE=""
DISTRO_NAME=""
DISTRO_FAMILY=""
ARCH_RAW=""
ARCH=""
HOST_ENV_READY=0
APT_UPDATED=0
SUDO_VALIDATED=0
SUDO_KEEPALIVE_PID=""
DOCKER_CMD=(docker)
DOCKER_REQUIRES_SUDO=0
COMPOSE_MODE=""

usage() {
  cat <<'EOF'
Usage: deploy/deploy.sh [action] [options]

Actions:
  --start | start    Pull fixed Docker Hub images, initialize data, migrate, and start the VM stack. Default.
  --stop  | stop     Stop the VM stack and hourly file log collector.
  --reset | reset    Stop the VM stack and delete PostgreSQL/Redis data. Requires GHCP_RESET_CONFIRM=reset.
  --logs  | logs     Tail the newest hourly file log.

Options:
  --data-dir DIR     Persistent VM data directory. Default: ~/ghcp_proxy
  --env-file FILE    Deployment environment file. Default: <data-dir>/.env
  --tail-lines N     Lines to show for logs. Default: 200
  -h, --help         Show this help.

Environment:
  GHCP_PROXY_HOME      Alternative default for the persistent data directory.
  LOG_RETENTION_DAYS   Hourly file log retention days. Default: 30
  WAIT_TIMEOUT         Seconds to wait for containers and HTTP endpoints. Default: 120
  GHCP_RESET_CONFIRM   Must be set to reset before using --reset/reset.

Host setup:
  Automatically validates x86_64 Linux, detects Ubuntu/Debian, Fedora, Red Hat family, or SUSE,
  installs Docker Engine/Compose when missing, and adds the invoking user to the docker group.

Generated host files and bind-mount directories:
  ~/ghcp_proxy/.env             Private deployment settings and generated secrets.
  ~/ghcp_proxy/data/postgres    Host bind mount for PostgreSQL data.
  ~/ghcp_proxy/data/redis       Host bind mount for Redis data.
  ~/ghcp_proxy/logs             Host directory for hourly service logs.
EOF
}

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

stop_sudo_keepalive() {
  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
    SUDO_KEEPALIVE_PID=""
  fi
}

start_sudo_keepalive() {
  [[ -z "$SUDO_KEEPALIVE_PID" ]] || return 0
  (
    while true; do
      sudo -n true >/dev/null 2>&1 || exit 0
      sleep 60
    done
  ) &
  SUDO_KEEPALIVE_PID="$!"
  trap stop_sudo_keepalive EXIT
}

ensure_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    return 0
  fi
  require_cmd sudo
  if [[ "$SUDO_VALIDATED" -eq 0 ]]; then
    log "Requesting sudo privileges for host setup"
    sudo -v || die "sudo privileges are required to install Docker, manage its service, or update docker group membership"
    SUDO_VALIDATED=1
    start_sudo_keepalive
  fi
}

run_privileged() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
    return $?
  fi
  ensure_sudo
  sudo "$@"
}

set_action() {
  local next_action="$1"
  if [[ "$ACTION_SET" -eq 1 && "$ACTION" != "$next_action" ]]; then
    die "only one action can be used at a time"
  fi
  ACTION="$next_action"
  ACTION_SET=1
}

expand_path() {
  local path="$1"
  case "$path" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOME" "${path#~/}"
      ;;
    /*)
      printf '%s\n' "$path"
      ;;
    *)
      printf '%s/%s\n' "$PWD" "$path"
      ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --start|start|deploy)
        set_action start
        ;;
      --stop|stop)
        set_action stop
        ;;
      --reset|reset)
        set_action reset
        ;;
      --logs|logs)
        set_action logs
        ;;
      __collect-logs)
        set_action __collect_logs
        ;;
      --data-dir)
        [[ $# -ge 2 ]] || die "--data-dir requires a value"
        DATA_DIR="$2"
        shift
        ;;
      --env-file)
        [[ $# -ge 2 ]] || die "--env-file requires a value"
        ENV_FILE="$2"
        shift
        ;;
      --tail-lines)
        [[ $# -ge 2 ]] || die "--tail-lines requires a value"
        LOG_TAIL_LINES="$2"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option or action: $1"
        ;;
    esac
    shift
  done
}

refresh_paths() {
  if [[ -z "$DATA_DIR" ]]; then
    DATA_DIR="$DEFAULT_DATA_DIR"
  fi
  DATA_DIR="$(expand_path "$DATA_DIR")"
  [[ -n "$ENV_FILE" ]] || ENV_FILE="$DATA_DIR/.env"
  ENV_FILE="$(expand_path "$ENV_FILE")"
  COMPOSE_FILE="$(expand_path "$COMPOSE_FILE")"
  LOG_DIR="${LOG_DIR:-$DATA_DIR/logs}"
  RUN_DIR="${RUN_DIR:-$DATA_DIR/run}"
  POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-$DATA_DIR/data/postgres}"
  REDIS_DATA_DIR="${REDIS_DATA_DIR:-$DATA_DIR/data/redis}"
}

require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || die "this VM deploy script expects Linux"
}

detect_architecture() {
  ARCH_RAW="$(uname -m)"
  case "$ARCH_RAW" in
    x86_64|amd64)
      ARCH="amd64"
      ;;
    aarch64|arm64|armv*|arm)
      die "ARM architecture ($ARCH_RAW) is not supported; only x86_64/amd64 Linux hosts are currently supported"
      ;;
    i386|i686)
      die "32-bit x86 architecture ($ARCH_RAW) is not supported; only x86_64/amd64 Linux hosts are currently supported"
      ;;
    *)
      die "unsupported CPU architecture: $ARCH_RAW; only x86_64/amd64 Linux hosts are currently supported"
      ;;
  esac
}

detect_linux_distro() {
  [[ -r /etc/os-release ]] || die "cannot detect Linux distribution: /etc/os-release is missing"
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_ID_LIKE="${ID_LIKE:-}"
  DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"

  case "$DISTRO_ID" in
    ubuntu|debian)
      DISTRO_FAMILY="debian"
      ;;
    fedora)
      DISTRO_FAMILY="fedora"
      ;;
    rhel|redhat|centos|rocky|almalinux|ol)
      DISTRO_FAMILY="redhat"
      ;;
    opensuse*|sles|suse)
      DISTRO_FAMILY="suse"
      ;;
    *)
      case " $DISTRO_ID_LIKE " in
        *" rhel "*|*" redhat "*|*" centos "*)
          DISTRO_FAMILY="redhat"
          ;;
        *" fedora "*)
          DISTRO_FAMILY="fedora"
          ;;
        *" ubuntu "*|*" debian "*)
          DISTRO_FAMILY="debian"
          ;;
        *" suse "*|*" opensuse "*)
          DISTRO_FAMILY="suse"
          ;;
        *)
          die "unsupported Linux distribution: $DISTRO_NAME. Supported families: Ubuntu/Debian, Fedora, Red Hat/CentOS/Rocky/AlmaLinux, and SUSE/openSUSE"
          ;;
      esac
      ;;
  esac
}

package_manager() {
  case "$DISTRO_FAMILY" in
    debian)
      require_cmd apt-get
      printf '%s\n' apt-get
      ;;
    fedora|redhat)
      if command -v dnf >/dev/null 2>&1; then
        printf '%s\n' dnf
      elif command -v yum >/dev/null 2>&1; then
        printf '%s\n' yum
      else
        die "dnf or yum is required to install Docker on $DISTRO_NAME"
      fi
      ;;
    suse)
      require_cmd zypper
      printf '%s\n' zypper
      ;;
    *)
      die "unsupported Linux distribution family: $DISTRO_FAMILY"
      ;;
  esac
}

apt_update_once() {
  if [[ "$APT_UPDATED" -eq 0 ]]; then
    run_privileged apt-get update
    APT_UPDATED=1
  fi
}

install_host_packages() {
  local pm
  [[ "$#" -gt 0 ]] || return 0
  pm="$(package_manager)"
  case "$DISTRO_FAMILY" in
    debian)
      apt_update_once
      run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    fedora|redhat)
      run_privileged "$pm" install -y "$@"
      ;;
    suse)
      run_privileged zypper --non-interactive install --no-recommends "$@"
      ;;
  esac
}

ensure_command_package() {
  local command_name="$1"
  local package_name="$2"
  if command -v "$command_name" >/dev/null 2>&1; then
    return 0
  fi
  log "Installing missing host command: $command_name"
  install_host_packages "$package_name"
  command -v "$command_name" >/dev/null 2>&1 || die "failed to install required command: $command_name"
}

docker_compose_binary_available() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

install_docker_debian() {
  local repo_os="$DISTRO_ID"
  local codename="${VERSION_CODENAME:-}"

  if [[ "$repo_os" != "ubuntu" && "$repo_os" != "debian" ]]; then
    if [[ " $DISTRO_ID_LIKE " == *" ubuntu "* ]]; then
      repo_os="ubuntu"
      codename="${UBUNTU_CODENAME:-$codename}"
    elif [[ " $DISTRO_ID_LIKE " == *" debian "* ]]; then
      repo_os="debian"
    fi
  fi
  [[ -n "$codename" ]] || die "cannot determine Debian/Ubuntu codename for Docker repository"

  apt_update_once
  run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
  run_privileged install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL "https://download.docker.com/linux/$repo_os/gpg" | run_privileged gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  fi
  run_privileged chmod a+r /etc/apt/keyrings/docker.gpg
  printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' "$repo_os" "$codename" | run_privileged tee /etc/apt/sources.list.d/docker.list >/dev/null
  APT_UPDATED=0
  apt_update_once
  run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

dnf_add_docker_repo() {
  local pm="$1"
  local repo_url="$2"
  if [[ "$pm" == "dnf" ]]; then
    run_privileged dnf install -y dnf-plugins-core ca-certificates curl
    if ! run_privileged dnf config-manager --add-repo "$repo_url"; then
      run_privileged dnf config-manager addrepo --from-repofile="$repo_url"
    fi
    return 0
  fi

  run_privileged yum install -y yum-utils ca-certificates curl
  run_privileged yum-config-manager --add-repo "$repo_url"
}

install_docker_dnf_family() {
  local pm
  local repo_url
  pm="$(package_manager)"
  if [[ "$DISTRO_FAMILY" == "fedora" ]]; then
    repo_url="https://download.docker.com/linux/fedora/docker-ce.repo"
  elif [[ "$DISTRO_ID" == "rhel" || "$DISTRO_ID" == "redhat" ]]; then
    repo_url="https://download.docker.com/linux/rhel/docker-ce.repo"
  else
    repo_url="https://download.docker.com/linux/centos/docker-ce.repo"
  fi

  dnf_add_docker_repo "$pm" "$repo_url"
  run_privileged "$pm" install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_suse() {
  run_privileged zypper --non-interactive refresh
  if ! run_privileged zypper --non-interactive install --no-recommends docker docker-compose-plugin curl; then
    run_privileged zypper --non-interactive install --no-recommends docker docker-compose curl
  fi
}

install_docker_stack() {
  log "Installing Docker Engine and Compose for $DISTRO_NAME"
  case "$DISTRO_FAMILY" in
    debian)
      install_docker_debian
      ;;
    fedora|redhat)
      install_docker_dnf_family
      ;;
    suse)
      install_docker_suse
      ;;
    *)
      die "automatic Docker installation is not supported on $DISTRO_NAME"
      ;;
  esac
}

start_docker_service() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet docker 2>/dev/null; then
      return 0
    fi
    log "Starting Docker service"
    run_privileged systemctl enable --now docker || run_privileged systemctl start docker || true
  elif command -v service >/dev/null 2>&1; then
    if service docker status >/dev/null 2>&1; then
      return 0
    fi
    log "Starting Docker service"
    run_privileged service docker start || true
  else
    warn "systemctl/service not found; assuming Docker daemon is managed externally"
  fi
}

docker_group_user() {
  if [[ "$(id -u)" -eq 0 ]]; then
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
      printf '%s\n' "$SUDO_USER"
    fi
    return 0
  fi
  id -un
}

ensure_docker_group_membership() {
  local target_user
  target_user="$(docker_group_user)"
  if [[ -z "$target_user" ]]; then
    warn "running as root; no non-root user was detected for docker group membership"
    return 0
  fi

  if command -v getent >/dev/null 2>&1; then
    getent group docker >/dev/null 2>&1 || run_privileged groupadd docker
  else
    run_privileged groupadd -f docker
  fi

  if ! id -nG "$target_user" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    log "Adding $target_user to docker group"
    run_privileged usermod -aG docker "$target_user"
    warn "User '$target_user' was added to docker group. Start a new login shell or run 'newgrp docker' to use Docker without sudo in future sessions."
  fi
}

docker_cli() {
  "${DOCKER_CMD[@]}" "$@"
}

select_docker_command() {
  DOCKER_CMD=(docker)
  DOCKER_REQUIRES_SUDO=0
  if docker info >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$(id -u)" -ne 0 ]]; then
    ensure_sudo
    if sudo docker info >/dev/null 2>&1; then
      DOCKER_CMD=(sudo docker)
      DOCKER_REQUIRES_SUDO=1
      warn "Using sudo for Docker in this session; docker group membership will remove that requirement after the next login shell."
      return 0
    fi
  fi

  docker info >/dev/null 2>&1 || die "docker daemon is not available; start Docker or check permissions"
}

select_compose_command() {
  if docker_cli compose version >/dev/null 2>&1; then
    COMPOSE_MODE="plugin"
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    if [[ "$DOCKER_REQUIRES_SUDO" -eq 1 && "$(id -u)" -ne 0 ]]; then
      run_privileged docker-compose version >/dev/null 2>&1 || return 1
    else
      docker-compose version >/dev/null 2>&1 || return 1
    fi
    COMPOSE_MODE="standalone"
    return 0
  fi
  return 1
}

ensure_docker_stack() {
  local needs_install=0
  command -v docker >/dev/null 2>&1 || needs_install=1
  if [[ "$needs_install" -eq 0 ]] && ! docker_compose_binary_available; then
    needs_install=1
  fi

  if [[ "$needs_install" -eq 1 ]]; then
    install_docker_stack
  fi

  require_cmd docker
  ensure_docker_group_membership
  start_docker_service
  select_docker_command
  select_compose_command || die "Docker Compose is required but was not found after installation"
}

prepare_host_environment() {
  [[ "$HOST_ENV_READY" -eq 0 ]] || return 0
  require_linux
  detect_architecture
  detect_linux_distro
  log "Detected host: $DISTRO_NAME ($DISTRO_FAMILY), architecture: $ARCH_RAW"
  ensure_docker_stack
  HOST_ENV_READY=1
}

require_common_cmds() {
  prepare_host_environment
  require_cmd awk
  require_cmd date
  require_cmd find
  require_cmd grep
  require_cmd od
  require_cmd sed
  require_cmd sort
  require_cmd tail
  require_cmd tr
}

require_start_cmds() {
  require_common_cmds
  ensure_command_package curl curl
  ensure_command_package nohup coreutils
}

random_hex() {
  local bytes="$1"
  od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

prepare_directories() {
  mkdir -p "$DATA_DIR" "$POSTGRES_DATA_DIR" "$REDIS_DATA_DIR" "$LOG_DIR" "$RUN_DIR"
}

add_env_if_missing() {
  local key="$1"
  local value="$2"
  if ! grep -Eq "^${key}=" "$ENV_FILE"; then
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

set_env_value() {
  local key="$1"
  local value="$2"
  if grep -Eq "^${key}=" "$ENV_FILE"; then
    sed -i "s/^${key}=.*/${key}=${value}/" "$ENV_FILE"
    return 0
  fi
  printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
}

source_schema_version() {
  local version=""
  if [[ -f "$LOCAL_MIGRATIONS_DIR/$SCHEMA_VERSION_FILE_NAME" ]]; then
    version="$(tr -d '[:space:]' < "$LOCAL_MIGRATIONS_DIR/$SCHEMA_VERSION_FILE_NAME")"
  elif [[ -n "${SCHEMA_VERSION:-}" ]]; then
    version="$SCHEMA_VERSION"
  else
    version="$(docker_cli run --rm --entrypoint sh "$MIGRATION_IMAGE" -c 'tr -d "[:space:]" < "/srv/ghcp/migrations/$1"' sh "$SCHEMA_VERSION_FILE_NAME")"
  fi

  [[ "$version" =~ ^[0-9]+$ ]] || die "invalid schema version: $version"
  printf '%s\n' "$version"
}

write_env_file_if_missing() {
  if [[ -f "$ENV_FILE" ]]; then
    log "Using deployment environment at $ENV_FILE"
    chmod 600 "$ENV_FILE"
    set_env_value SCHEMA_VERSION "$(source_schema_version)"
    add_env_if_missing COMPOSE_NETWORK_NAME "ghcp-proxy-net"
    add_env_if_missing POSTGRES_USER "ghcp"
    add_env_if_missing POSTGRES_PASSWORD "$(random_hex 24)"
    add_env_if_missing POSTGRES_DB "ghcp"
    add_env_if_missing POSTGRES_DATA_DIR "$POSTGRES_DATA_DIR"
    add_env_if_missing REDIS_DATA_DIR "$REDIS_DATA_DIR"
    add_env_if_missing GATEWAY_PORT "8000"
    add_env_if_missing ADMIN_PORT "8001"
    add_env_if_missing ADMIN_TOKEN "$(random_hex 32)"
    add_env_if_missing PROVIDER "copilot"
    add_env_if_missing CREDENTIAL_KEY_VERSION "vm"
    add_env_if_missing CREDENTIAL_MASTER_KEY "$(random_hex 32)"
    add_env_if_missing LOG_RETENTION_DAYS "$LOG_RETENTION_DAYS"
    return 0
  fi

  log "Creating deployment environment at $ENV_FILE"
  umask 077
  cat > "$ENV_FILE" <<EOF
# Generated by deploy/deploy.sh. Keep this file private.
SCHEMA_VERSION=$(source_schema_version)

POSTGRES_USER=ghcp
POSTGRES_PASSWORD=$(random_hex 24)
POSTGRES_DB=ghcp
POSTGRES_DATA_DIR=$POSTGRES_DATA_DIR
REDIS_DATA_DIR=$REDIS_DATA_DIR

GATEWAY_PORT=8000
ADMIN_PORT=8001
COMPOSE_NETWORK_NAME=ghcp-proxy-net

ADMIN_TOKEN=$(random_hex 32)
PROVIDER=copilot
CREDENTIAL_KEY_VERSION=vm
CREDENTIAL_MASTER_KEY=$(random_hex 32)

LOG_RETENTION_DAYS=$LOG_RETENTION_DAYS

# Optional runtime settings. Saved Dashboard settings are used when these are unset.
# Set PROVIDER=fake only for explicit non-production troubleshooting.
# LOG_LEVEL=info
# LOG_FORMAT=json
# GITHUB_TOKEN=
# GITHUB_OAUTH_CLIENT_ID=Iv1.b507a08c87ecfe98
# GITHUB_OAUTH_SCOPES=read:user
EOF
  chmod 600 "$ENV_FILE"
}

load_environment() {
  [[ -f "$ENV_FILE" ]] || die "environment file not found: $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a

  PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$PROJECT_NAME}"
  POSTGRES_USER="${POSTGRES_USER:-ghcp}"
  POSTGRES_DB="${POSTGRES_DB:-ghcp}"
  GATEWAY_PORT="${GATEWAY_PORT:-8000}"
  ADMIN_PORT="${ADMIN_PORT:-8001}"
  GATEWAY_URL="${GATEWAY_URL:-http://localhost:$GATEWAY_PORT}"
  ADMIN_URL="${ADMIN_URL:-http://localhost:$ADMIN_PORT}"
  LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
  LOG_DIR="${LOG_DIR:-$DATA_DIR/logs}"
  RUN_DIR="${RUN_DIR:-$DATA_DIR/run}"
  POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-$DATA_DIR/data/postgres}"
  REDIS_DATA_DIR="${REDIS_DATA_DIR:-$DATA_DIR/data/redis}"
}

compose() {
  if [[ "$COMPOSE_MODE" == "standalone" ]]; then
    if [[ "$DOCKER_REQUIRES_SUDO" -eq 1 && "$(id -u)" -ne 0 ]]; then
      run_privileged docker-compose --env-file "$ENV_FILE" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
      return $?
    fi
    docker-compose --env-file "$ENV_FILE" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
    return $?
  fi
  docker_cli compose --env-file "$ENV_FILE" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
}

pull_runtime_images() {
  log "Pulling fixed runtime images from Docker Hub"
  compose pull postgres redis gateway admin worker
}

wait_container_healthy() {
  local service="$1"
  local elapsed=0
  local container_id=""
  local status=""

  log "Waiting for $service to become healthy"
  while (( elapsed < WAIT_TIMEOUT )); do
    container_id="$(compose ps -q "$service")"
    if [[ -n "$container_id" ]]; then
      status="$(docker_cli inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
      if [[ "$status" == "healthy" ]]; then
        return 0
      fi
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  compose ps
  die "$service did not become healthy within ${WAIT_TIMEOUT}s"
}

wait_http() {
  local name="$1"
  local url="$2"
  local elapsed=0

  log "Waiting for $name at $url"
  while (( elapsed < WAIT_TIMEOUT )); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  die "$name did not respond successfully within ${WAIT_TIMEOUT}s"
}

db_psql() {
  compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"
}

db_scalar() {
  db_psql -Atc "$1" | tr -d '[:space:]'
}

db_setting() {
  local key="$1"
  db_psql -Atc "SELECT value FROM system_settings WHERE key = '$key' AND value <> '' LIMIT 1;" | sed -n '1p'
}

database_migrated() {
  local migrated
  migrated="$(db_scalar "SELECT to_regclass('public.accounts') IS NOT NULL AND to_regclass('public.system_settings') IS NOT NULL;")"
  [[ "$migrated" == "t" ]]
}

schema_conflict() {
  cat >&2 <<EOF
ERROR: Database schema conflict detected: $*

The database contains a GHCP schema that does not match this version and cannot be updated automatically.
Back up any data you need, then initialize a fresh VM database with a new --data-dir, or stop the stack and move aside the PostgreSQL data directory before starting again.

Current PostgreSQL data directory:
  $POSTGRES_DATA_DIR
EOF
  exit 1
}

schema_table_exists() {
  local table="$1"
  local exists
  exists="$(db_scalar "SELECT to_regclass('public.$table') IS NOT NULL;")"
  [[ "$exists" == "t" ]]
}

schema_require_table() {
  local table="$1"
  schema_table_exists "$table" || schema_conflict "required table public.$table is missing"
}

schema_column_exists_with_type() {
  local table="$1"
  local column="$2"
  local expected_udt="$3"
  local column_count
  local type_ok

  column_count="$(db_scalar "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '$table' AND column_name = '$column';")"
  [[ "$column_count" != "0" ]] || return 1

  type_ok="$(db_scalar "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '$table' AND column_name = '$column' AND udt_name = '$expected_udt');")"
  [[ "$type_ok" == "t" ]] || schema_conflict "column public.$table.$column has an incompatible type; expected $expected_udt"
  return 0
}

schema_require_column() {
  local table="$1"
  local column="$2"
  local expected_udt="$3"
  schema_column_exists_with_type "$table" "$column" "$expected_udt" || schema_conflict "table public.$table exists but required column $column is missing"
}

schema_project_objects_exist() {
  local object_count
  object_count="$(db_scalar "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name IN ('accounts', 'system_settings', 'backend_pools', 'client_profiles', 'route_policies', 'usage_ledger', 'secure_settings', 'account_user_bindings');")"
  [[ "$object_count" != "0" ]]
}

route_policy_request_format_schema_current() {
  schema_require_table route_policies
  schema_column_exists_with_type route_policies request_format text
}

runtime_config_schema_current() {
  if ! schema_table_exists secure_settings; then
    return 1
  fi

  schema_require_column secure_settings key text
  schema_require_column secure_settings encrypted_value bytea
  schema_require_column secure_settings key_version text
  schema_require_column secure_settings description text
  schema_require_column secure_settings updated_by text
  schema_require_column secure_settings updated_at timestamptz
  return 0
}

route_policy_client_profile_schema_current() {
  schema_require_table route_policies
  schema_column_exists_with_type route_policies client_profile_id uuid
}

schema_cleanup_schema_current() {
  local cleanup_needed
  schema_require_table backend_pools
  schema_require_table usage_ledger
  cleanup_needed="$(db_scalar "SELECT to_regclass('public.routing_affinities') IS NOT NULL OR to_regclass('public.budget_snapshots') IS NOT NULL OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'backend_pools' AND column_name = 'default_model') OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'usage_ledger' AND column_name = 'prefix_hash');")"
  [[ "$cleanup_needed" != "t" ]]
}

route_policy_load_balance_schema_current() {
  schema_require_table route_policies
  schema_column_exists_with_type route_policies load_balance_strategy text
}

usage_ai_credits_schema_current() {
  local missing=0
  schema_require_table usage_ledger
  schema_column_exists_with_type usage_ledger reasoning_tokens int4 || missing=1
  schema_column_exists_with_type usage_ledger nano_aiu int8 || missing=1
  schema_column_exists_with_type usage_ledger estimated_ai_credits numeric || missing=1
  schema_column_exists_with_type usage_ledger token_details jsonb || missing=1
  [[ "$missing" -eq 0 ]]
}

usage_rollups_schema_current() {
  local missing=0
  if schema_table_exists usage_rollup_state; then
    schema_require_column usage_rollup_state name text
    schema_require_column usage_rollup_state last_processed_at timestamptz
    schema_require_column usage_rollup_state updated_at timestamptz
  else
    missing=1
  fi

  if schema_table_exists usage_rollup_hourly; then
    schema_require_column usage_rollup_hourly bucket_start timestamptz
    schema_require_column usage_rollup_hourly client_profile_id text
    schema_require_column usage_rollup_hourly client_name text
    schema_require_column usage_rollup_hourly account_id text
    schema_require_column usage_rollup_hourly pool_id text
    schema_require_column usage_rollup_hourly model text
    schema_require_column usage_rollup_hourly request_format text
    schema_require_column usage_rollup_hourly status text
    schema_require_column usage_rollup_hourly requests int8
    schema_require_column usage_rollup_hourly input_tokens int8
    schema_require_column usage_rollup_hourly cached_input_tokens int8
    schema_require_column usage_rollup_hourly cache_write_tokens int8
    schema_require_column usage_rollup_hourly output_tokens int8
    schema_require_column usage_rollup_hourly reasoning_tokens int8
    schema_require_column usage_rollup_hourly nano_aiu int8
    schema_require_column usage_rollup_hourly estimated_ai_credits numeric
    schema_require_column usage_rollup_hourly estimated_cost numeric
    schema_require_column usage_rollup_hourly latency_ms_sum int8
    schema_require_column usage_rollup_hourly latency_ms_count int8
    schema_require_column usage_rollup_hourly latency_ms_max int4
    schema_require_column usage_rollup_hourly sticky_hits int8
    schema_require_column usage_rollup_hourly errors int8
    schema_require_column usage_rollup_hourly updated_at timestamptz
  else
    missing=1
  fi

  if schema_table_exists usage_rollup_daily; then
    schema_require_column usage_rollup_daily bucket_date date
    schema_require_column usage_rollup_daily client_profile_id text
    schema_require_column usage_rollup_daily client_name text
    schema_require_column usage_rollup_daily account_id text
    schema_require_column usage_rollup_daily pool_id text
    schema_require_column usage_rollup_daily model text
    schema_require_column usage_rollup_daily request_format text
    schema_require_column usage_rollup_daily status text
    schema_require_column usage_rollup_daily requests int8
    schema_require_column usage_rollup_daily input_tokens int8
    schema_require_column usage_rollup_daily cached_input_tokens int8
    schema_require_column usage_rollup_daily cache_write_tokens int8
    schema_require_column usage_rollup_daily output_tokens int8
    schema_require_column usage_rollup_daily reasoning_tokens int8
    schema_require_column usage_rollup_daily nano_aiu int8
    schema_require_column usage_rollup_daily estimated_ai_credits numeric
    schema_require_column usage_rollup_daily estimated_cost numeric
    schema_require_column usage_rollup_daily latency_ms_sum int8
    schema_require_column usage_rollup_daily latency_ms_count int8
    schema_require_column usage_rollup_daily latency_ms_max int4
    schema_require_column usage_rollup_daily sticky_hits int8
    schema_require_column usage_rollup_daily errors int8
    schema_require_column usage_rollup_daily updated_at timestamptz
  else
    missing=1
  fi

  [[ "$missing" -eq 0 ]]
}

pool_user_binding_schema_current() {
  local missing=0
  schema_require_table accounts
  schema_require_table backend_pools
  schema_require_table client_profiles
  schema_column_exists_with_type backend_pools allocation_mode text || missing=1
  schema_column_exists_with_type backend_pools binding_max_concurrency int4 || missing=1
  schema_column_exists_with_type backend_pools binding_ttl_seconds int4 || missing=1

  if schema_table_exists account_user_bindings; then
    schema_require_column account_user_bindings id uuid
    schema_require_column account_user_bindings client_profile_id uuid
    schema_require_column account_user_bindings pool_id uuid
    schema_require_column account_user_bindings account_id uuid
    schema_require_column account_user_bindings user_id_hash text
    schema_require_column account_user_bindings user_id_display text
    schema_require_column account_user_bindings user_id_source text
    schema_require_column account_user_bindings status text
    schema_require_column account_user_bindings last_used_at timestamptz
    schema_require_column account_user_bindings expires_at timestamptz
    schema_require_column account_user_bindings released_at timestamptz
    schema_require_column account_user_bindings release_reason text
    schema_require_column account_user_bindings created_at timestamptz
    schema_require_column account_user_bindings updated_at timestamptz
  else
    missing=1
  fi

  if schema_table_exists account_session_bindings; then
    schema_require_column account_session_bindings id uuid
    schema_require_column account_session_bindings client_profile_id uuid
    schema_require_column account_session_bindings pool_id uuid
    schema_require_column account_session_bindings account_id uuid
    schema_require_column account_session_bindings session_id_hash text
    schema_require_column account_session_bindings session_id_display text
    schema_require_column account_session_bindings session_id_source text
    schema_require_column account_session_bindings status text
    schema_require_column account_session_bindings last_used_at timestamptz
    schema_require_column account_session_bindings expires_at timestamptz
    schema_require_column account_session_bindings released_at timestamptz
    schema_require_column account_session_bindings release_reason text
    schema_require_column account_session_bindings created_at timestamptz
    schema_require_column account_session_bindings updated_at timestamptz
  else
    missing=1
  fi

  [[ "$missing" -eq 0 ]]
}

target_schema_current() {
  case "$(target_schema_version)" in
    10)
      pool_user_binding_schema_current
      ;;
    *)
      return 0
      ;;
  esac
}

apply_incremental_migrations() {
  reconcile_database_schema
}

apply_migration_file() {
  local migration_name="$1"
  if [[ -f "$LOCAL_MIGRATIONS_DIR/$migration_name" ]]; then
    db_psql -v ON_ERROR_STOP=1 --single-transaction -f - < "$LOCAL_MIGRATIONS_DIR/$migration_name"
    return 0
  fi

  docker_cli run --rm --entrypoint sh "$MIGRATION_IMAGE" -c 'cat "/srv/ghcp/migrations/$1"' sh "$migration_name" | db_psql -v ON_ERROR_STOP=1 --single-transaction -f -
}

target_schema_version() {
  local version="${SCHEMA_VERSION:-}"
  if [[ -z "$version" ]]; then
    version="$(source_schema_version)"
  fi

  [[ "$version" =~ ^[0-9]+$ ]] || die "invalid schema version: $version"
  printf '%s\n' "$version"
}

database_schema_version() {
  local version
  if ! schema_table_exists system_settings; then
    return 0
  fi

  version="$(db_psql -Atc "SELECT value FROM system_settings WHERE key = 'schema_version' LIMIT 1;" | tr -d '[:space:]')"
  [[ -n "$version" ]] || return 0
  [[ "$version" =~ ^[0-9]+$ ]] || schema_conflict "system_settings.schema_version is invalid: $version"
  printf '%s\n' "$version"
}

set_database_schema_version() {
  local version="$1"
  db_psql -v ON_ERROR_STOP=1 <<SQL
INSERT INTO system_settings (key, value, description, updated_by, updated_at)
VALUES ('schema_version', '$version', 'Installed database schema version', 'deploy.sh', now())
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value,
    description = EXCLUDED.description,
    updated_by = EXCLUDED.updated_by,
    updated_at = now();
SQL
}

infer_legacy_schema_version() {
  if ! schema_table_exists accounts; then
    return 0
  fi

  if pool_user_binding_schema_current; then
    printf '10\n'
  elif usage_rollups_schema_current; then
    printf '9\n'
  elif usage_ai_credits_schema_current; then
    printf '8\n'
  elif route_policy_load_balance_schema_current; then
    printf '7\n'
  elif schema_cleanup_schema_current; then
    printf '6\n'
  elif route_policy_client_profile_schema_current; then
    printf '5\n'
  elif runtime_config_schema_current; then
    printf '4\n'
  elif route_policy_request_format_schema_current; then
    printf '3\n'
  elif schema_table_exists system_settings; then
    printf '2\n'
  else
    printf '1\n'
  fi
}

apply_smooth_schema_upgrade() {
  local current="$1"
  local target="$2"

  if [[ "$target" != "10" ]]; then
    schema_conflict "automatic smooth migration to schema version $target is not defined"
  fi
  if (( current > target )); then
    schema_conflict "database schema version $current is newer than local schema version $target"
  fi

  log "Applying smooth schema upgrade from version $current to $target"
  db_psql -v ON_ERROR_STOP=1 --single-transaction <<'SQL'
CREATE TABLE IF NOT EXISTS system_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT 'false',
    description TEXT,
    updated_by TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO system_settings (key, value, description) VALUES
    ('copilot_metrics_sync_enabled', 'false', 'Enable GitHub Copilot Metrics sync worker'),
    ('audit_search_enabled', 'false', 'Enable audit log search API endpoint'),
    ('advanced_metrics_enabled', 'false', 'Enable detailed sticky/rebind/overflow metrics'),
    ('model_catalog_json', '[{"exposed":"gpt-4o","upstream":"gpt-4o","enabled":true},{"exposed":"gpt-4o-mini","upstream":"gpt-4o-mini","enabled":true},{"exposed":"gpt-5.5","upstream":"gpt-5.5","upstream_api":"responses","enabled":true},{"exposed":"claude-sonnet-4-20250514","upstream":"claude-sonnet-4-20250514","enabled":true},{"exposed":"claude-3.5-sonnet","upstream":"claude-3.5-sonnet","enabled":true},{"exposed":"o3-mini","upstream":"o3-mini","enabled":true}]', 'Model catalog exposed to downstream clients')
ON CONFLICT (key) DO NOTHING;

ALTER TABLE route_policies
    ADD COLUMN IF NOT EXISTS request_format TEXT NOT NULL DEFAULT '*';

CREATE INDEX IF NOT EXISTS idx_route_policies_request_format
    ON route_policies(request_format);

CREATE TABLE IF NOT EXISTS secure_settings (
    key TEXT PRIMARY KEY,
    encrypted_value BYTEA NOT NULL,
    key_version TEXT NOT NULL,
    description TEXT,
    updated_by TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE route_policies
    ADD COLUMN IF NOT EXISTS client_profile_id UUID REFERENCES client_profiles(id);

DROP TABLE IF EXISTS routing_affinities;
DROP TABLE IF EXISTS budget_snapshots;

ALTER TABLE backend_pools
    DROP COLUMN IF EXISTS default_model;

ALTER TABLE usage_ledger
    DROP COLUMN IF EXISTS prefix_hash;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'route_policies'
          AND column_name = 'client_profile_id'
    ) AND NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'route_policies_client_profile_id_fkey'
    ) THEN
        ALTER TABLE route_policies
            ADD CONSTRAINT route_policies_client_profile_id_fkey
            FOREIGN KEY (client_profile_id) REFERENCES client_profiles(id) ON DELETE CASCADE;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_route_policies_client_profile
    ON route_policies(client_profile_id);

CREATE INDEX IF NOT EXISTS idx_route_policies_match
    ON route_policies(client_profile_id, request_format, model_pattern, priority)
    WHERE enabled = TRUE;

CREATE INDEX IF NOT EXISTS idx_usage_ledger_client
    ON usage_ledger(client_profile_id, created_at);

ALTER TABLE route_policies
    ADD COLUMN IF NOT EXISTS load_balance_strategy TEXT NOT NULL DEFAULT 'risk_weighted';

ALTER TABLE route_policies
    DROP CONSTRAINT IF EXISTS route_policies_load_balance_strategy_check;

ALTER TABLE route_policies
    ADD CONSTRAINT route_policies_load_balance_strategy_check
    CHECK (load_balance_strategy IN ('risk_weighted', 'round_robin', 'least_concurrency'));

ALTER TABLE usage_ledger
  ADD COLUMN IF NOT EXISTS reasoning_tokens INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS nano_aiu BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS estimated_ai_credits NUMERIC(20,9) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS token_details JSONB NOT NULL DEFAULT '[]'::jsonb;

CREATE INDEX IF NOT EXISTS idx_usage_ledger_model_created ON usage_ledger(model, created_at);
CREATE INDEX IF NOT EXISTS idx_usage_ledger_pool_created ON usage_ledger(pool_id, created_at);

CREATE TABLE IF NOT EXISTS usage_rollup_state (
    name TEXT PRIMARY KEY,
    last_processed_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS usage_rollup_hourly (
    bucket_start TIMESTAMPTZ NOT NULL,
    client_profile_id TEXT NOT NULL DEFAULT '',
    client_name TEXT NOT NULL DEFAULT 'unknown',
    account_id TEXT NOT NULL DEFAULT '',
    pool_id TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    request_format TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL,
    requests BIGINT NOT NULL DEFAULT 0,
    input_tokens BIGINT NOT NULL DEFAULT 0,
    cached_input_tokens BIGINT NOT NULL DEFAULT 0,
    cache_write_tokens BIGINT NOT NULL DEFAULT 0,
    output_tokens BIGINT NOT NULL DEFAULT 0,
    reasoning_tokens BIGINT NOT NULL DEFAULT 0,
    nano_aiu BIGINT NOT NULL DEFAULT 0,
    estimated_ai_credits NUMERIC(20,9) NOT NULL DEFAULT 0,
    estimated_cost NUMERIC(20,8) NOT NULL DEFAULT 0,
    latency_ms_sum BIGINT NOT NULL DEFAULT 0,
    latency_ms_count BIGINT NOT NULL DEFAULT 0,
    latency_ms_max INT NOT NULL DEFAULT 0,
    sticky_hits BIGINT NOT NULL DEFAULT 0,
    errors BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (bucket_start, client_profile_id, account_id, pool_id, model, request_format, status)
);

CREATE INDEX IF NOT EXISTS idx_usage_rollup_hourly_bucket ON usage_rollup_hourly(bucket_start);
CREATE INDEX IF NOT EXISTS idx_usage_rollup_hourly_client_bucket ON usage_rollup_hourly(client_profile_id, bucket_start);
CREATE INDEX IF NOT EXISTS idx_usage_rollup_hourly_model_bucket ON usage_rollup_hourly(model, bucket_start);

CREATE TABLE IF NOT EXISTS usage_rollup_daily (
    bucket_date DATE NOT NULL,
    client_profile_id TEXT NOT NULL DEFAULT '',
    client_name TEXT NOT NULL DEFAULT 'unknown',
    account_id TEXT NOT NULL DEFAULT '',
    pool_id TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    request_format TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL,
    requests BIGINT NOT NULL DEFAULT 0,
    input_tokens BIGINT NOT NULL DEFAULT 0,
    cached_input_tokens BIGINT NOT NULL DEFAULT 0,
    cache_write_tokens BIGINT NOT NULL DEFAULT 0,
    output_tokens BIGINT NOT NULL DEFAULT 0,
    reasoning_tokens BIGINT NOT NULL DEFAULT 0,
    nano_aiu BIGINT NOT NULL DEFAULT 0,
    estimated_ai_credits NUMERIC(20,9) NOT NULL DEFAULT 0,
    estimated_cost NUMERIC(20,8) NOT NULL DEFAULT 0,
    latency_ms_sum BIGINT NOT NULL DEFAULT 0,
    latency_ms_count BIGINT NOT NULL DEFAULT 0,
    latency_ms_max INT NOT NULL DEFAULT 0,
    sticky_hits BIGINT NOT NULL DEFAULT 0,
    errors BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (bucket_date, client_profile_id, account_id, pool_id, model, request_format, status)
);

CREATE INDEX IF NOT EXISTS idx_usage_rollup_daily_date ON usage_rollup_daily(bucket_date);
CREATE INDEX IF NOT EXISTS idx_usage_rollup_daily_client_date ON usage_rollup_daily(client_profile_id, bucket_date);
CREATE INDEX IF NOT EXISTS idx_usage_rollup_daily_model_date ON usage_rollup_daily(model, bucket_date);

INSERT INTO usage_rollup_state (name, last_processed_at, updated_at)
SELECT 'usage_rollup', COALESCE(MIN(created_at), now()), now()
FROM usage_ledger
ON CONFLICT (name) DO NOTHING;

ALTER TABLE backend_pools
  ADD COLUMN IF NOT EXISTS allocation_mode TEXT NOT NULL DEFAULT 'shared',
  ADD COLUMN IF NOT EXISTS binding_max_concurrency INT NOT NULL DEFAULT 10,
  ADD COLUMN IF NOT EXISTS binding_ttl_seconds INT;

ALTER TABLE backend_pools
  DROP CONSTRAINT IF EXISTS backend_pools_allocation_mode_check;

ALTER TABLE backend_pools
  ADD CONSTRAINT backend_pools_allocation_mode_check
  CHECK (allocation_mode IN ('shared', 'user_binding', 'session_binding'));

CREATE TABLE IF NOT EXISTS account_user_bindings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_profile_id UUID NOT NULL REFERENCES client_profiles(id) ON DELETE CASCADE,
    pool_id UUID NOT NULL REFERENCES backend_pools(id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  user_id_hash TEXT NOT NULL,
  user_id_display TEXT NOT NULL,
  user_id_source TEXT,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'released', 'expired')),
    last_used_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    released_at TIMESTAMPTZ,
    release_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

  DO $$
  BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'account_user_bindings' AND column_name = 'owner_key_hash')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'account_user_bindings' AND column_name = 'user_id_hash') THEN
      ALTER TABLE account_user_bindings RENAME COLUMN owner_key_hash TO user_id_hash;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'account_user_bindings' AND column_name = 'owner_display')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'account_user_bindings' AND column_name = 'user_id_display') THEN
      ALTER TABLE account_user_bindings RENAME COLUMN owner_display TO user_id_display;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'account_user_bindings' AND column_name = 'source_header')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'account_user_bindings' AND column_name = 'user_id_source') THEN
      ALTER TABLE account_user_bindings RENAME COLUMN source_header TO user_id_source;
    END IF;
  END $$;

  ALTER TABLE account_user_bindings
    ADD COLUMN IF NOT EXISTS user_id_hash TEXT,
    ADD COLUMN IF NOT EXISTS user_id_display TEXT,
    ADD COLUMN IF NOT EXISTS user_id_source TEXT;

  UPDATE account_user_bindings
  SET user_id_hash = COALESCE(user_id_hash, id::text),
    user_id_display = COALESCE(user_id_display, user_id_hash, id::text)
  WHERE user_id_hash IS NULL OR user_id_display IS NULL;

  ALTER TABLE account_user_bindings
    ALTER COLUMN user_id_hash SET NOT NULL,
    ALTER COLUMN user_id_display SET NOT NULL;

  DROP INDEX IF EXISTS idx_account_user_bindings_active_owner;

CREATE UNIQUE INDEX IF NOT EXISTS idx_account_user_bindings_active_owner
    ON account_user_bindings(client_profile_id, pool_id, user_id_hash)
    WHERE status = 'active';

CREATE UNIQUE INDEX IF NOT EXISTS idx_account_user_bindings_active_account
    ON account_user_bindings(account_id)
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_account_user_bindings_pool_status
    ON account_user_bindings(pool_id, status, expires_at);

CREATE INDEX IF NOT EXISTS idx_account_user_bindings_expires
    ON account_user_bindings(status, expires_at);

CREATE TABLE IF NOT EXISTS account_session_bindings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_profile_id UUID NOT NULL REFERENCES client_profiles(id) ON DELETE CASCADE,
  pool_id UUID NOT NULL REFERENCES backend_pools(id) ON DELETE CASCADE,
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  session_id_hash TEXT NOT NULL,
  session_id_display TEXT NOT NULL,
  session_id_source TEXT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'released', 'expired')),
  last_used_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  released_at TIMESTAMPTZ,
  release_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_account_session_bindings_active_owner
  ON account_session_bindings(client_profile_id, pool_id, session_id_hash)
  WHERE status = 'active';

CREATE UNIQUE INDEX IF NOT EXISTS idx_account_session_bindings_active_account
  ON account_session_bindings(account_id)
  WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_account_session_bindings_pool_status
  ON account_session_bindings(pool_id, status, expires_at);

CREATE INDEX IF NOT EXISTS idx_account_session_bindings_expires
  ON account_session_bindings(status, expires_at);
SQL

  set_database_schema_version "$target"
}

apply_init_schema() {
  local target="$1"
  apply_migration_file "$INIT_SCHEMA_SQL_NAME"
  set_database_schema_version "$target"
}

reconcile_database_schema() {
  local target
  local current
  target="$(target_schema_version)"
  current="$(database_schema_version)"

  if [[ -z "$current" ]] && schema_project_objects_exist; then
    current="$(infer_legacy_schema_version)"
    [[ -n "$current" ]] || schema_conflict "database contains a partial GHCP schema but the version cannot be inferred"
    log "Detected legacy database schema version $current"
  fi

  if [[ -n "$current" ]]; then
    log "Database schema version: current=$current target=$target"
    if (( current == target )); then
      if ! target_schema_current; then
        warn "Database schema version is $target but required objects are missing; applying idempotent schema repair"
        apply_smooth_schema_upgrade "$current" "$target"
        return 0
      fi
      set_database_schema_version "$target"
      log "Database schema is up to date"
      return 0
    fi
    if (( current > target )); then
      schema_conflict "database schema version $current is newer than local schema version $target"
    fi
    apply_smooth_schema_upgrade "$current" "$target"
    return 0
  fi

  if schema_project_objects_exist; then
    schema_conflict "database contains a partial GHCP schema but the required initial schema is incomplete"
  fi

  log "Database schema is empty; applying consolidated init schema version $target"
  apply_init_schema "$target"
}

apply_migrations_if_needed() {
  reconcile_database_schema
}

reset_data_dir_with_container() {
  local path="$1"
  mkdir -p "$path"
  docker_cli run --rm \
    --entrypoint sh \
    -v "$path:/target" \
    alpine:3.24 \
    -c 'find /target -mindepth 1 -maxdepth 1 -exec rm -rf {} +'
}

export_runtime_setting() {
  local env_name="$1"
  local setting_key="$2"
  local value=""

  if [[ -v "$env_name" ]]; then
    return 0
  fi

  value="$(db_setting "$setting_key")"
  if [[ -n "$value" ]]; then
    export "$env_name=$value"
  fi
}

load_runtime_environment() {
  if ! database_migrated; then
    return 0
  fi

  export_runtime_setting GITHUB_OAUTH_CLIENT_ID github_oauth_client_id
  export_runtime_setting GITHUB_OAUTH_SCOPES github_oauth_scopes
  export_runtime_setting GITHUB_LOGIN_BASE_URL github_login_base_url
  export_runtime_setting GITHUB_API_BASE_URL github_api_base_url
  export_runtime_setting COPILOT_TOKEN_URL copilot_token_url
  export_runtime_setting PROVIDER provider
  export_runtime_setting COPILOT_BASE_URL copilot_base_url
  export_runtime_setting COPILOT_TIMEOUT copilot_timeout
  export_runtime_setting LOG_LEVEL log_level
  export_runtime_setting LOG_FORMAT log_format

  log "Using gateway provider: ${PROVIDER:-copilot}"
}

run_start_checks() {
  wait_http "gateway health" "$GATEWAY_URL/healthz"
  wait_http "gateway readiness" "$GATEWAY_URL/readyz"
  wait_http "admin dashboard" "$ADMIN_URL/"
}

cleanup_old_logs() {
  mkdir -p "$LOG_DIR"
  find "$LOG_DIR" -type f -name 'ghcp-proxy-*.log' -mtime "+$LOG_RETENTION_DAYS" -delete
}

collector_pid_file() {
  printf '%s/log-collector.pid' "$RUN_DIR"
}

collector_is_running() {
  local pid_file
  local pid
  pid_file="$(collector_pid_file)"
  [[ -f "$pid_file" ]] || return 1
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1 && sudo -n kill -0 "$pid" 2>/dev/null
}

seconds_until_next_hour() {
  local now
  local next
  now="$(date +%s)"
  next=$(( ((now / 3600) + 1) * 3600 ))
  printf '%s\n' "$((next - now))"
}

collect_logs() {
  require_common_cmds
  load_environment
  prepare_directories
  cleanup_old_logs

  local child_pid=""
  local sleep_pid=""
  local tail_arg="--tail=200"
  trap '[[ -n "$child_pid" ]] && kill "$child_pid" >/dev/null 2>&1 || true; [[ -n "$sleep_pid" ]] && kill "$sleep_pid" >/dev/null 2>&1 || true; exit 0' TERM INT

  while true; do
    local log_file
    local wait_seconds
    log_file="$LOG_DIR/ghcp-proxy-$(date +%Y%m%d-%H).log"
    wait_seconds="$(seconds_until_next_hour)"
    cleanup_old_logs

    compose logs --no-color --timestamps "$tail_arg" -f postgres redis gateway admin worker >> "$log_file" 2>&1 &
    child_pid="$!"
    tail_arg="--tail=0"

    sleep "$wait_seconds" &
    sleep_pid="$!"
    wait "$sleep_pid" || true
    sleep_pid=""

    kill "$child_pid" >/dev/null 2>&1 || true
    wait "$child_pid" >/dev/null 2>&1 || true
    child_pid=""
  done
}

stop_log_collector() {
  local pid_file
  local pid
  pid_file="$(collector_pid_file)"
  if ! collector_is_running; then
    rm -f "$pid_file"
    return 0
  fi

  pid="$(cat "$pid_file")"
  log "Stopping hourly file log collector"
  kill "$pid" 2>/dev/null || run_privileged kill "$pid" 2>/dev/null || true
  rm -f "$pid_file"
}

start_log_collector() {
  mkdir -p "$LOG_DIR" "$RUN_DIR"
  cleanup_old_logs
  if collector_is_running; then
    log "Hourly file log collector is already running"
    return 0
  fi

  log "Starting hourly file log collector in $LOG_DIR"
  if [[ "$DOCKER_REQUIRES_SUDO" -eq 1 && "$(id -u)" -ne 0 ]]; then
    run_privileged env \
      GHCP_PROXY_HOME="$DATA_DIR" \
      ENV_FILE="$ENV_FILE" \
      COMPOSE_FILE="$COMPOSE_FILE" \
      COMPOSE_PROJECT_NAME="$PROJECT_NAME" \
      LOG_DIR="$LOG_DIR" \
      RUN_DIR="$RUN_DIR" \
      LOG_RETENTION_DAYS="$LOG_RETENTION_DAYS" \
      nohup "$SCRIPT_PATH" __collect-logs >> "$LOG_DIR/log-collector.log" 2>&1 &
  else
    GHCP_PROXY_HOME="$DATA_DIR" \
      ENV_FILE="$ENV_FILE" \
      COMPOSE_FILE="$COMPOSE_FILE" \
      COMPOSE_PROJECT_NAME="$PROJECT_NAME" \
      LOG_DIR="$LOG_DIR" \
      RUN_DIR="$RUN_DIR" \
      LOG_RETENTION_DAYS="$LOG_RETENTION_DAYS" \
      nohup "$SCRIPT_PATH" __collect-logs >> "$LOG_DIR/log-collector.log" 2>&1 &
  fi
  printf '%s\n' "$!" > "$(collector_pid_file)"
}

start_data_services() {
  log "Starting PostgreSQL and Redis"
  compose up -d postgres redis
  wait_container_healthy postgres
  wait_container_healthy redis
}

start_app_services() {
  log "Starting gateway, admin, and worker"
  compose up -d --no-build gateway admin worker
}

start_stack() {
  require_start_cmds
  log "Preparing host bind-mount directories under $DATA_DIR"
  prepare_directories
  write_env_file_if_missing
  load_environment
  prepare_directories
  pull_runtime_images
  start_data_services
  apply_migrations_if_needed
  load_runtime_environment
  start_app_services
  run_start_checks
  start_log_collector

  cat <<EOF

VM stack is ready.
  Gateway:       $GATEWAY_URL
  Admin UI:      $ADMIN_URL/
  Provider:      ${PROVIDER:-copilot}
  Host data dir: $DATA_DIR
  PostgreSQL:    $POSTGRES_DATA_DIR -> postgres:/var/lib/postgresql/data
  Redis:         $REDIS_DATA_DIR -> redis:/data
  Log dir:       $LOG_DIR
  Log retention: ${LOG_RETENTION_DAYS} days
  Env file:      $ENV_FILE

Useful commands:
  $SCRIPT_PATH --logs
  $SCRIPT_PATH --stop
EOF
}

stop_stack() {
  if [[ ! -f "$ENV_FILE" ]]; then
    warn "environment file not found: $ENV_FILE"
    return 0
  fi
  require_common_cmds
  load_environment
  prepare_directories
  stop_log_collector
  log "Stopping VM stack"
  compose down
  printf '\nVM stack stopped. Persistent data was preserved in %s.\n' "$DATA_DIR"
}

reset_stack() {
  [[ "${GHCP_RESET_CONFIRM:-}" == "reset" ]] || die "reset deletes PostgreSQL and Redis data. Rerun with GHCP_RESET_CONFIRM=reset to confirm."

  require_common_cmds
  if [[ -f "$ENV_FILE" ]]; then
    load_environment
  fi
  prepare_directories
  stop_log_collector
  log "Stopping VM stack before reset"
  if [[ -f "$ENV_FILE" ]]; then
    compose down || true
  fi

  log "Deleting persistent PostgreSQL and Redis data under $DATA_DIR"
  reset_data_dir_with_container "$POSTGRES_DATA_DIR"
  reset_data_dir_with_container "$REDIS_DATA_DIR"
  rm -rf "$RUN_DIR" || true
  mkdir -p "$POSTGRES_DATA_DIR" "$REDIS_DATA_DIR" "$RUN_DIR" "$LOG_DIR"

  cat <<EOF

VM persistent database state was reset.
  Preserved env file: $ENV_FILE
  Removed PostgreSQL: $POSTGRES_DATA_DIR
  Removed Redis:      $REDIS_DATA_DIR

Next command:
  $SCRIPT_PATH --start
EOF
}

show_logs() {
  [[ -f "$ENV_FILE" ]] || die "environment file not found: $ENV_FILE"
  require_common_cmds
  load_environment
  prepare_directories
  local latest_log
  latest_log="$(find "$LOG_DIR" -maxdepth 1 -type f -name 'ghcp-proxy-*.log' | sort | tail -n 1 || true)"
  if [[ -z "$latest_log" ]]; then
    warn "no hourly log files found in $LOG_DIR; following compose logs instead"
    compose logs --no-color --timestamps --tail="$LOG_TAIL_LINES" -f postgres redis gateway admin worker
    return 0
  fi

  log "Tailing $latest_log"
  tail -n "$LOG_TAIL_LINES" -f "$latest_log"
}

main() {
  parse_args "$@"
  refresh_paths

  if [[ -f "$ENV_FILE" ]]; then
    load_environment
  fi

  case "$ACTION" in
    start)
      start_stack
      ;;
    stop)
      stop_stack
      ;;
    reset)
      reset_stack
      ;;
    logs)
      show_logs
      ;;
    __collect_logs)
      collect_logs
      ;;
    *)
      die "unsupported action: $ACTION"
      ;;
  esac
}

main "$@"