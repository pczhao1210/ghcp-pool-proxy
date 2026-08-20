#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/deploy.sh"

ACTION="start"
ACTION_SET=0

DEFAULT_DATA_DIR="$HOME/ghcp_proxy"
DATA_DIR="${GHCP_PROXY_HOME:-${DATA_DIR:-}}"
ENV_FILE="${ENV_FILE:-}"
APP_CONFIG_FILE="${APP_CONFIG_FILE:-}"
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
MIGRATION_IMAGE="pczhao1210/ghcp-pool-proxy:migration-latest"
RELEASE_MANIFEST_FILE="${RELEASE_MANIFEST:-${RELEASE_MANIFEST_FILE:-$SCRIPT_DIR/../release-manifest.env}}"
RELEASE_MANIFEST_TOOL="$SCRIPT_DIR/release_manifest.sh"
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
EFFECTIVE_PROVIDER=""
INSTALL_MISSING=0

usage() {
  cat <<'EOF'
Usage: deploy/deploy.sh [action] [options]

Actions:
  --generate-config | generate-config
                     Create config.yaml, migrating startup values from an existing .env. Does not require Docker.
  --start | start | deploy
                     Pull fixed Docker Hub images, initialize data, migrate, and start the VM stack. Default.
  --stop  | stop     Stop the VM stack and hourly file log collector.
  --reset | reset    Stop the VM stack and delete PostgreSQL/Redis data. Requires GHCP_RESET_CONFIRM=reset.
  --logs  | logs     Tail the newest hourly file log.

Options:
  --data-dir DIR     Persistent VM data directory. Default: ~/ghcp_proxy
  --env-file FILE    Deployment environment file. Default: <data-dir>/.env
  --config-file FILE Application YAML file. Default: <data-dir>/config.yaml
  --release-manifest FILE
                      Immutable release-set manifest. Default: bundled release-manifest.env
  --install-missing  Allow non-interactive installation of missing prerequisites.
  --tail-lines N     Lines to show for logs. Default: 200
  -h, --help         Show this help.

Environment:
  GHCP_PROXY_HOME      Alternative default for the persistent data directory.
  LOG_RETENTION_DAYS   Hourly file log retention days. Default: 30
  WAIT_TIMEOUT         Seconds to wait for containers and HTTP endpoints. Default: 120
  RELEASE_MANIFEST     Immutable release-set manifest. RELEASE_MANIFEST_FILE remains a legacy alias.
  GHCP_RESET_CONFIRM   Must be set to reset before using --reset/reset.

Host setup:
  Automatically validates x86_64 Linux, detects Ubuntu/Debian, Fedora, Red Hat family, or SUSE,
  asks before installing missing tools, and adds the invoking user to the docker group.

Generated host files and bind-mount directories:
  ~/ghcp_proxy/.env             Private deployment settings and generated secrets.
  ~/ghcp_proxy/config.yaml      Application startup settings; create with generate-config.
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

confirm_install() {
  local label="$1"
  [[ "$INSTALL_MISSING" -eq 1 ]] && return 0
  [[ -t 0 ]] || die "missing $label; install it first or pass --install-missing to allow automatic installation"
  local answer
  printf 'Missing %s. Install it now? [y/N]: ' "$label" >&2
  IFS= read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || die "required component was not installed: $label"
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
      --generate-config|generate-config)
        set_action generate_config
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
      --config-file)
        [[ $# -ge 2 ]] || die "--config-file requires a value"
        APP_CONFIG_FILE="$2"
        shift
        ;;
      --release-manifest)
        [[ $# -ge 2 ]] || die "--release-manifest requires a value"
        RELEASE_MANIFEST_FILE="$2"
        shift
        ;;
      --install-missing)
        INSTALL_MISSING=1
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
  [[ -n "$APP_CONFIG_FILE" ]] || APP_CONFIG_FILE="$DATA_DIR/config.yaml"
  APP_CONFIG_FILE="$(expand_path "$APP_CONFIG_FILE")"
  RELEASE_MANIFEST_FILE="$(expand_path "$RELEASE_MANIFEST_FILE")"
  export APP_CONFIG_FILE
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
  confirm_install "$command_name"
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

load_release_manifest() {
  local schema
  [[ -x "$RELEASE_MANIFEST_TOOL" ]] || die "release manifest tool is missing: $RELEASE_MANIFEST_TOOL"
  [[ -r "$RELEASE_MANIFEST_FILE" ]] || die "release manifest is missing: $RELEASE_MANIFEST_FILE"
  schema="$(source_schema_version)"
  "$RELEASE_MANIFEST_TOOL" validate "$RELEASE_MANIFEST_FILE" "$schema"
  GATEWAY_IMAGE="$($RELEASE_MANIFEST_TOOL image-ref "$RELEASE_MANIFEST_FILE" gateway)"
  ADMIN_IMAGE="$($RELEASE_MANIFEST_TOOL image-ref "$RELEASE_MANIFEST_FILE" admin)"
  WORKER_IMAGE="$($RELEASE_MANIFEST_TOOL image-ref "$RELEASE_MANIFEST_FILE" worker)"
  MIGRATION_IMAGE="$($RELEASE_MANIFEST_TOOL image-ref "$RELEASE_MANIFEST_FILE" migration)"
  export GATEWAY_IMAGE ADMIN_IMAGE WORKER_IMAGE MIGRATION_IMAGE
}

validate_pulled_release_images() {
  local role image expected_digest actual_digests
  for role in gateway admin worker migration; do
    case "$role" in
      gateway) image="$GATEWAY_IMAGE" ;;
      admin) image="$ADMIN_IMAGE" ;;
      worker) image="$WORKER_IMAGE" ;;
      migration) image="$MIGRATION_IMAGE" ;;
    esac
    expected_digest="$($RELEASE_MANIFEST_TOOL value "$RELEASE_MANIFEST_FILE" "RELEASE_${role^^}_DIGEST")"
    actual_digests="$(docker_cli image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image" 2>/dev/null || true)"
    if ! grep -Fq "@${expected_digest}" <<<"$actual_digests"; then
      die "pulled $role image $image does not match release manifest digest $expected_digest"
    fi
  done
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
    confirm_install "Docker Engine and Compose"
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

yaml_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "$value"
}

config_string_value() {
  local key="$1"
  local fallback="$2"
  yaml_quote "${!key:-$fallback}"
}

config_integer_value() {
  local key="$1"
  local fallback="$2"
  local value="${!key:-$fallback}"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$key must be a non-negative integer, got: $value"
  printf '%s' "$value"
}

config_decimal_value() {
  local key="$1"
  local fallback="$2"
  local value="${!key:-$fallback}"
  [[ "$value" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] || die "$key must be a decimal number, got: $value"
  awk -v value="$value" 'BEGIN { exit !(value >= 0 && value <= 1) }' || die "$key must be between 0 and 1, got: $value"
  printf '%s' "$value"
}

validate_generated_config_values() {
  config_integer_value POSTGRES_MAX_OPEN_CONNS 12 >/dev/null
  config_integer_value USAGE_WRITER_QUEUE_SIZE 10000 >/dev/null
  config_integer_value USAGE_WRITER_BATCH_SIZE 500 >/dev/null
  config_integer_value USAGE_WRITER_FLUSH_THRESHOLD 100 >/dev/null
  config_integer_value USAGE_RAW_RETENTION_DAYS 7 >/dev/null
  config_integer_value USAGE_HOURLY_RETENTION_DAYS 90 >/dev/null
  config_integer_value USAGE_DAILY_RETENTION_MONTHS 13 >/dev/null
  config_integer_value USAGE_PARTITION_AHEAD_DAYS 7 >/dev/null
  config_integer_value HEALTH_TOKEN_PROBE_CONCURRENCY 5 >/dev/null
  config_integer_value HEALTH_TOKEN_PROBE_STARTS_PER_SECOND 2 >/dev/null
  config_integer_value HEALTH_UPSTREAM_PROBE_CONCURRENCY 2 >/dev/null
  config_integer_value HEALTH_UPSTREAM_PROBE_STARTS_PER_MINUTE 12 >/dev/null
  config_integer_value HEALTH_DEGRADE_THRESHOLD 70 >/dev/null
  config_integer_value HEALTH_REACTIVATE_THRESHOLD 60 >/dev/null
  config_integer_value HEALTH_QUARANTINE_THRESHOLD 90 >/dev/null
  config_decimal_value GATEWAY_SUCCESS_LOG_SAMPLE_RATE 0.01 >/dev/null
}

generate_config() {
  [[ ! -e "$APP_CONFIG_FILE" ]] || die "config file already exists: $APP_CONFIG_FILE"
  validate_generated_config_values
  mkdir -p "$(dirname "$APP_CONFIG_FILE")"

  local temporary_file="$APP_CONFIG_FILE.tmp.$$"
  umask 077
  cat > "$temporary_file" <<EOF
# Application startup configuration generated by deploy/deploy.sh.
# Environment values from an existing deployment .env were migrated when present.
# Edit this file, then run deploy/deploy.sh start. Startup changes require a restart.
# Secrets, host paths, ports, and database/Redis addresses remain in .env.
# Dashboard-managed database settings override the retention fallbacks below.

gateway:
  # Maximum time to read a complete request, including its body.
  read_timeout: $(config_string_value GATEWAY_READ_TIMEOUT 30s)
  # Maximum time to read request headers.
  read_header_timeout: $(config_string_value GATEWAY_READ_HEADER_TIMEOUT 5s)
  # Keep at 0s for long-lived SSE responses.
  write_timeout: $(config_string_value GATEWAY_WRITE_TIMEOUT 0s)
  # HTTP keep-alive idle timeout.
  idle_timeout: $(config_string_value GATEWAY_IDLE_TIMEOUT 120s)

provider:
  # VM deployments use copilot by default; fake is for explicit troubleshooting.
  type: $(config_string_value PROVIDER copilot)
  # Empty uses the provider default endpoint.
  base_url: $(config_string_value COPILOT_BASE_URL "")
  # Timeout for non-stream upstream requests.
  timeout: $(config_string_value COPILOT_TIMEOUT 120s)

github:
  # GitHub OAuth Device Flow and Copilot token exchange configuration.
  oauth_client_id: $(config_string_value GITHUB_OAUTH_CLIENT_ID Iv1.b507a08c87ecfe98)
  oauth_scopes: $(config_string_value GITHUB_OAUTH_SCOPES read:user)
  login_base_url: $(config_string_value GITHUB_LOGIN_BASE_URL https://github.com)
  api_base_url: $(config_string_value GITHUB_API_BASE_URL https://api.github.com)
  # Empty derives the token URL from api_base_url.
  copilot_token_url: $(config_string_value COPILOT_TOKEN_URL "")

health:
  enabled: $(config_string_value HEALTH_ENABLED true)
  scheduler_poll_interval: $(config_string_value HEALTH_SCHEDULER_POLL_INTERVAL 1s)
  active_token_probe_interval: $(config_string_value HEALTH_ACTIVE_TOKEN_PROBE_INTERVAL 60m)
  degraded_token_probe_interval: $(config_string_value HEALTH_DEGRADED_TOKEN_PROBE_INTERVAL 60s)
  token_probe_timeout: $(config_string_value HEALTH_TOKEN_PROBE_TIMEOUT 5s)
  token_probe_claim_lease: $(config_string_value HEALTH_TOKEN_PROBE_CLAIM_LEASE 15s)
  token_probe_concurrency: $(config_integer_value HEALTH_TOKEN_PROBE_CONCURRENCY 5)
  token_probe_starts_per_second: $(config_integer_value HEALTH_TOKEN_PROBE_STARTS_PER_SECOND 2)
  re_admission_cooldown: $(config_string_value HEALTH_RE_ADMISSION_COOLDOWN 5m)
  upstream_probe_timeout: $(config_string_value HEALTH_UPSTREAM_PROBE_TIMEOUT 15s)
  upstream_probe_claim_lease: $(config_string_value HEALTH_UPSTREAM_PROBE_CLAIM_LEASE 30s)
  # Covers token validation, upstream probe, and completion writes.
  recovery_task_claim_lease: $(config_string_value HEALTH_RECOVERY_TASK_CLAIM_LEASE 45s)
  upstream_probe_concurrency: $(config_integer_value HEALTH_UPSTREAM_PROBE_CONCURRENCY 2)
  upstream_probe_starts_per_minute: $(config_integer_value HEALTH_UPSTREAM_PROBE_STARTS_PER_MINUTE 12)
  probe_model: $(config_string_value HEALTH_PROBE_MODEL gpt-4o)
  probe_upstream_api: $(config_string_value HEALTH_PROBE_UPSTREAM_API chat_completions)
  degrade_threshold: $(config_integer_value HEALTH_DEGRADE_THRESHOLD 70)
  reactivate_threshold: $(config_integer_value HEALTH_REACTIVATE_THRESHOLD 60)
  quarantine_threshold: $(config_integer_value HEALTH_QUARANTINE_THRESHOLD 90)

postgres_pool:
  # Maximum PostgreSQL connections opened by each application process.
  max_open_connections: $(config_integer_value POSTGRES_MAX_OPEN_CONNS 12)
  # Recycle connections periodically and close long-idle connections.
  max_conn_lifetime: $(config_string_value POSTGRES_CONN_MAX_LIFETIME 5m)
  max_conn_idle_time: $(config_string_value POSTGRES_MAX_CONN_IDLE_TIME 5m)

usage_writer:
  # In-memory records waiting for PostgreSQL COPY.
  queue_size: $(config_integer_value USAGE_WRITER_QUEUE_SIZE 10000)
  # Maximum rows in one COPY transaction.
  batch_size: $(config_integer_value USAGE_WRITER_BATCH_SIZE 500)
  # Queue depth that triggers an immediate COPY.
  flush_threshold: $(config_integer_value USAGE_WRITER_FLUSH_THRESHOLD 100)
  # Maximum delay before flushing a partial batch.
  flush_interval: $(config_string_value USAGE_WRITER_FLUSH_INTERVAL 250ms)
  # Maximum request-side wait while the queue is full.
  enqueue_timeout: $(config_string_value USAGE_WRITER_ENQUEUE_TIMEOUT 50ms)
  # Maximum duration of one PostgreSQL COPY attempt.
  write_timeout: $(config_string_value USAGE_WRITER_WRITE_TIMEOUT 5s)

maintenance:
  # Startup fallbacks until Dashboard stores a DB override; 0 disables pruning.
  raw_retention_days: $(config_integer_value USAGE_RAW_RETENTION_DAYS 7)
  hourly_retention_days: $(config_integer_value USAGE_HOURLY_RETENTION_DAYS 90)
  daily_retention_months: $(config_integer_value USAGE_DAILY_RETENTION_MONTHS 13)
  # Number of future raw-ledger daily partitions created by Worker.
  partition_ahead_days: $(config_integer_value USAGE_PARTITION_AHEAD_DAYS 7)

logging:
  # debug, info, warn, or error.
  level: $(config_string_value LOG_LEVEL info)
  # json or text.
  format: $(config_string_value LOG_FORMAT json)
  # Fraction of successful access logs retained; errors are always logged.
  success_sample_rate: $(config_decimal_value GATEWAY_SUCCESS_LOG_SAMPLE_RATE 0.01)
EOF
  mv "$temporary_file" "$APP_CONFIG_FILE"
  chmod 644 "$APP_CONFIG_FILE"

  log "Created application configuration at $APP_CONFIG_FILE"
  if [[ -f "$ENV_FILE" ]]; then
    printf 'Migrated supported startup values from %s.\n' "$ENV_FILE"
  else
    printf 'No existing environment file was found; VM defaults were used.\n'
  fi
  printf 'Review the file, then run:\n  %s --start\n' "$SCRIPT_PATH"
}

prepare_directories() {
  mkdir -p "$DATA_DIR" "$POSTGRES_DATA_DIR" "$REDIS_DATA_DIR" "$LOG_DIR" "$RUN_DIR"
}

require_config_file() {
  if [[ -f "$APP_CONFIG_FILE" ]]; then
    return 0
  fi
  if [[ ! -e "$DATA_DIR" ]]; then
    log "Creating default application configuration for first start"
    generate_config
    return 0
  fi
  cat >&2 <<EOF
ERROR: application config not found: $APP_CONFIG_FILE

Create and review it before starting:
  $SCRIPT_PATH generate-config --data-dir "$DATA_DIR" --config-file "$APP_CONFIG_FILE"
EOF
  exit 1
}

ensure_config_file_permissions() {
  # Runtime images use an unprivileged UID; this file intentionally excludes secrets.
  if ! chmod 644 "$APP_CONFIG_FILE"; then
    run_privileged chmod 644 "$APP_CONFIG_FILE" || die "cannot make application config readable: $APP_CONFIG_FILE"
  fi
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
    add_env_if_missing GATEWAY_BIND_ADDR "127.0.0.1"
    add_env_if_missing GATEWAY_PORT "8000"
    add_env_if_missing ADMIN_BIND_ADDR "127.0.0.1"
    add_env_if_missing ADMIN_PORT "8001"
    add_env_if_missing WORKER_METRICS_PORT "8002"
    add_env_if_missing ADMIN_TOKEN "$(random_hex 32)"
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

GATEWAY_BIND_ADDR=127.0.0.1
GATEWAY_PORT=8000
ADMIN_BIND_ADDR=127.0.0.1
ADMIN_PORT=8001
WORKER_METRICS_PORT=8002
COMPOSE_NETWORK_NAME=ghcp-proxy-net

ADMIN_TOKEN=$(random_hex 32)
CREDENTIAL_KEY_VERSION=vm
CREDENTIAL_MASTER_KEY=$(random_hex 32)

LOG_RETENTION_DAYS=$LOG_RETENTION_DAYS

# Optional secrets. Application startup settings belong in config.yaml.
# GITHUB_TOKEN_FILE=/absolute/path/to/github-token
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
  GATEWAY_BIND_ADDR="${GATEWAY_BIND_ADDR:-127.0.0.1}"
  GATEWAY_PORT="${GATEWAY_PORT:-8000}"
  ADMIN_BIND_ADDR="${ADMIN_BIND_ADDR:-127.0.0.1}"
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
      run_privileged env APP_CONFIG_FILE="$APP_CONFIG_FILE" GATEWAY_IMAGE="$GATEWAY_IMAGE" ADMIN_IMAGE="$ADMIN_IMAGE" WORKER_IMAGE="$WORKER_IMAGE" MIGRATION_IMAGE="$MIGRATION_IMAGE" SCHEMA_VERSION="${SCHEMA_VERSION:-}" MIGRATION_DSN_HOST_FILE="${MIGRATION_DSN_HOST_FILE:-/dev/null}" docker-compose --env-file "$ENV_FILE" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
      return $?
    fi
    GATEWAY_IMAGE="$GATEWAY_IMAGE" ADMIN_IMAGE="$ADMIN_IMAGE" WORKER_IMAGE="$WORKER_IMAGE" MIGRATION_IMAGE="$MIGRATION_IMAGE" SCHEMA_VERSION="${SCHEMA_VERSION:-}" MIGRATION_DSN_HOST_FILE="${MIGRATION_DSN_HOST_FILE:-/dev/null}" docker-compose --env-file "$ENV_FILE" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
    return $?
  fi
  if [[ "$DOCKER_REQUIRES_SUDO" -eq 1 && "$(id -u)" -ne 0 ]]; then
    run_privileged env APP_CONFIG_FILE="$APP_CONFIG_FILE" GATEWAY_IMAGE="$GATEWAY_IMAGE" ADMIN_IMAGE="$ADMIN_IMAGE" WORKER_IMAGE="$WORKER_IMAGE" MIGRATION_IMAGE="$MIGRATION_IMAGE" SCHEMA_VERSION="${SCHEMA_VERSION:-}" MIGRATION_DSN_HOST_FILE="${MIGRATION_DSN_HOST_FILE:-/dev/null}" docker compose --env-file "$ENV_FILE" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
    return $?
  fi
  GATEWAY_IMAGE="$GATEWAY_IMAGE" ADMIN_IMAGE="$ADMIN_IMAGE" WORKER_IMAGE="$WORKER_IMAGE" MIGRATION_IMAGE="$MIGRATION_IMAGE" SCHEMA_VERSION="${SCHEMA_VERSION:-}" MIGRATION_DSN_HOST_FILE="${MIGRATION_DSN_HOST_FILE:-/dev/null}" docker_cli compose --env-file "$ENV_FILE" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
}

pull_runtime_images() {
  log "Pulling fixed runtime images from Docker Hub"
  compose pull postgres redis migration gateway admin worker
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


run_migration_runner() {
  local target
  local dsn_file
  local status=0

  target="$(target_schema_version)"
  dsn_file="$(mktemp)"
  chmod 600 "$dsn_file"
  printf 'postgres://%s:%s@postgres:5432/%s?sslmode=disable\n' "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$POSTGRES_DB" > "$dsn_file"

  log "Applying manifest-backed database migrations to schema version $target"
  MIGRATION_DSN_HOST_FILE="$dsn_file" \
    compose run --rm --no-deps \
      -e "MIGRATION_TARGET_VERSION=$target" \
      -e "MIGRATION_PHASE=expand" \
      migration || status=$?
  rm -f "$dsn_file"
  return "$status"
}


target_schema_version() {
  local version="${SCHEMA_VERSION:-}"
  if [[ -z "$version" ]]; then
    version="$(source_schema_version)"
  fi

  [[ "$version" =~ ^[0-9]+$ ]] || die "invalid schema version: $version"
  printf '%s\n' "$version"
}






apply_migrations_if_needed() {
  run_migration_runner
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

load_runtime_environment() {
  EFFECTIVE_PROVIDER="$(compose run --rm --no-deps gateway --print-config provider.type)" || die "invalid application config: $APP_CONFIG_FILE"
  [[ "$EFFECTIVE_PROVIDER" == "fake" || "$EFFECTIVE_PROVIDER" == "copilot" ]] || die "invalid provider returned from $APP_CONFIG_FILE: $EFFECTIVE_PROVIDER"
  log "Using gateway provider: $EFFECTIVE_PROVIDER"
}

run_start_checks() {
  wait_http "gateway health" "$GATEWAY_URL/healthz"
  wait_http "gateway readiness" "$GATEWAY_URL/readyz"
  wait_http "admin dashboard" "$ADMIN_URL/"
  wait_container_healthy worker
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
      APP_CONFIG_FILE="$APP_CONFIG_FILE" \
      COMPOSE_FILE="$COMPOSE_FILE" \
      COMPOSE_PROJECT_NAME="$PROJECT_NAME" \
      LOG_DIR="$LOG_DIR" \
      RUN_DIR="$RUN_DIR" \
      LOG_RETENTION_DAYS="$LOG_RETENTION_DAYS" \
      nohup "$SCRIPT_PATH" __collect-logs >> "$LOG_DIR/log-collector.log" 2>&1 &
  else
    GHCP_PROXY_HOME="$DATA_DIR" \
      ENV_FILE="$ENV_FILE" \
      APP_CONFIG_FILE="$APP_CONFIG_FILE" \
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
  require_config_file
  require_start_cmds
  ensure_config_file_permissions
  log "Preparing host bind-mount directories under $DATA_DIR"
  prepare_directories
  write_env_file_if_missing
  load_environment
  load_release_manifest
  prepare_directories
  pull_runtime_images
  validate_pulled_release_images
  load_runtime_environment
  start_data_services
  apply_migrations_if_needed
  start_app_services
  run_start_checks
  start_log_collector

  cat <<EOF

VM stack is ready.
  Gateway:       $GATEWAY_URL
  Admin UI:      $ADMIN_URL/
  Provider:      $EFFECTIVE_PROVIDER
  Host data dir: $DATA_DIR
  PostgreSQL:    $POSTGRES_DATA_DIR -> postgres:/var/lib/postgresql/data
  Redis:         $REDIS_DATA_DIR -> redis:/data
  Log dir:       $LOG_DIR
  Log retention: ${LOG_RETENTION_DAYS} days
  Env file:      $ENV_FILE
  Config file:   $APP_CONFIG_FILE

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
    if ! compose down; then
      die "failed to stop VM stack; persistent data was not deleted"
    fi
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
    generate_config)
      generate_config
      ;;
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