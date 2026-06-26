#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/deploy.sh"

ACTION="start"
ACTION_SET=0

DATA_DIR="${GHCP_PROXY_HOME:-${DATA_DIR:-$HOME/ghcp_proxy}}"
ENV_FILE="${ENV_FILE:-}"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/docker-compose.vm.yml}"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-ghcp-proxy}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-120}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
LOG_TAIL_LINES="${LOG_TAIL_LINES:-200}"
GATEWAY_IMAGE="pczhao1210/ghcp-pool-proxy:gateway-latest"
ADMIN_IMAGE="pczhao1210/ghcp-pool-proxy:admin-latest"
WORKER_IMAGE="pczhao1210/ghcp-pool-proxy:worker-latest"
MIGRATION_IMAGE="$ADMIN_IMAGE"

usage() {
  cat <<'EOF'
Usage: deploy/deploy.sh [action] [options]

Actions:
  --start | start    Pull fixed Docker Hub images, initialize data, migrate, and start the VM stack. Default.
  --stop  | stop     Stop the VM stack and hourly file log collector.
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

Generated files:
  ~/ghcp_proxy/.env       Private deployment settings and generated secrets.
  ~/ghcp_proxy/data/*     PostgreSQL and Redis persistent data.
  ~/ghcp_proxy/logs/*     Hourly service logs and log collector diagnostics.
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

require_docker() {
  require_cmd docker
  docker info >/dev/null 2>&1 || die "docker daemon is not available; start Docker or check permissions"
  docker compose version >/dev/null 2>&1 || die "docker compose is required"
}

require_common_cmds() {
  require_linux
  require_docker
  require_cmd awk
  require_cmd date
  require_cmd find
  require_cmd od
  require_cmd sed
  require_cmd sort
  require_cmd tail
  require_cmd tr
}

require_start_cmds() {
  require_common_cmds
  require_cmd curl
  require_cmd nohup
  require_cmd sha256sum
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

write_env_file_if_missing() {
  if [[ -f "$ENV_FILE" ]]; then
    log "Using deployment environment at $ENV_FILE"
    chmod 600 "$ENV_FILE"
    add_env_if_missing COMPOSE_NETWORK_NAME "ghcp-proxy-net"
    add_env_if_missing POSTGRES_USER "ghcp"
    add_env_if_missing POSTGRES_PASSWORD "$(random_hex 24)"
    add_env_if_missing POSTGRES_DB "ghcp"
    add_env_if_missing POSTGRES_DATA_DIR "$POSTGRES_DATA_DIR"
    add_env_if_missing REDIS_DATA_DIR "$REDIS_DATA_DIR"
    add_env_if_missing GATEWAY_PORT "8000"
    add_env_if_missing ADMIN_PORT "8001"
    add_env_if_missing ADMIN_TOKEN "$(random_hex 32)"
    add_env_if_missing API_KEY "$(random_hex 32)"
    add_env_if_missing CREDENTIAL_KEY_VERSION "vm"
    add_env_if_missing CREDENTIAL_MASTER_KEY "$(random_hex 32)"
    add_env_if_missing LOG_RETENTION_DAYS "$LOG_RETENTION_DAYS"
    return 0
  fi

  log "Creating deployment environment at $ENV_FILE"
  umask 077
  cat > "$ENV_FILE" <<EOF
# Generated by deploy/deploy.sh. Keep this file private.
POSTGRES_USER=ghcp
POSTGRES_PASSWORD=$(random_hex 24)
POSTGRES_DB=ghcp
POSTGRES_DATA_DIR=$POSTGRES_DATA_DIR
REDIS_DATA_DIR=$REDIS_DATA_DIR

GATEWAY_PORT=8000
ADMIN_PORT=8001
COMPOSE_NETWORK_NAME=ghcp-proxy-net

ADMIN_TOKEN=$(random_hex 32)
API_KEY=$(random_hex 32)
CREDENTIAL_KEY_VERSION=vm
CREDENTIAL_MASTER_KEY=$(random_hex 32)

LOG_RETENTION_DAYS=$LOG_RETENTION_DAYS

# Optional runtime settings. Saved Dashboard settings are used when these are unset.
# PROVIDER=copilot
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
  docker compose --env-file "$ENV_FILE" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
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
      status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
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

route_policy_request_format_migrated() {
  local migrated
  migrated="$(db_scalar "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'route_policies' AND column_name = 'request_format');")"
  [[ "$migrated" == "t" ]]
}

runtime_config_migrated() {
  local migrated
  migrated="$(db_scalar "SELECT to_regclass('public.secure_settings') IS NOT NULL;")"
  [[ "$migrated" == "t" ]]
}

route_policy_client_profile_migrated() {
  local migrated
  migrated="$(db_scalar "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'route_policies' AND column_name = 'client_profile_id');")"
  [[ "$migrated" == "t" ]]
}

schema_cleanup_migrated() {
  local migrated
  migrated="$(db_scalar "SELECT to_regclass('public.routing_affinities') IS NULL AND to_regclass('public.budget_snapshots') IS NULL AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'backend_pools' AND column_name = 'default_model') AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'usage_ledger' AND column_name = 'prefix_hash');")"
  [[ "$migrated" == "t" ]]
}

route_policy_load_balance_migrated() {
  local migrated
  migrated="$(db_scalar "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'route_policies' AND column_name = 'load_balance_strategy');")"
  [[ "$migrated" == "t" ]]
}

usage_ai_credits_migrated() {
  local migrated
  migrated="$(db_scalar "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'usage_ledger' AND column_name = 'nano_aiu');")"
  [[ "$migrated" == "t" ]]
}

usage_rollups_migrated() {
  local migrated
  migrated="$(db_scalar "SELECT to_regclass('public.usage_rollup_hourly') IS NOT NULL AND to_regclass('public.usage_rollup_daily') IS NOT NULL;")"
  [[ "$migrated" == "t" ]]
}

apply_incremental_migrations() {
  if ! route_policy_request_format_migrated; then
    log "Applying incremental migration 003_route_policy_request_format.sql"
    apply_migration_file 003_route_policy_request_format.sql
  fi
  if ! runtime_config_migrated; then
    log "Applying incremental migration 004_runtime_config.sql"
    apply_migration_file 004_runtime_config.sql
  fi
  if ! route_policy_client_profile_migrated; then
    log "Applying incremental migration 005_route_policy_client_profile.sql"
    apply_migration_file 005_route_policy_client_profile.sql
  fi
  if ! schema_cleanup_migrated; then
    log "Applying incremental migration 006_schema_cleanup.sql"
    apply_migration_file 006_schema_cleanup.sql
  fi
  if ! route_policy_load_balance_migrated; then
    log "Applying incremental migration 007_route_policy_load_balance_strategy.sql"
    apply_migration_file 007_route_policy_load_balance_strategy.sql
  fi
  if ! usage_ai_credits_migrated; then
    log "Applying incremental migration 008_usage_ai_credits.sql"
    apply_migration_file 008_usage_ai_credits.sql
  fi
  if ! usage_rollups_migrated; then
    log "Applying incremental migration 009_usage_rollups.sql"
    apply_migration_file 009_usage_rollups.sql
  fi
}

list_migration_files() {
  docker run --rm --entrypoint sh "$MIGRATION_IMAGE" -c 'for file in /srv/ghcp/migrations/*.sql; do basename "$file"; done | sort'
}

apply_migration_file() {
  local migration_name="$1"
  docker run --rm --entrypoint cat "$MIGRATION_IMAGE" "/srv/ghcp/migrations/$migration_name" | db_psql -v ON_ERROR_STOP=1 -f -
}

apply_migrations_if_needed() {
  if database_migrated; then
    log "Database schema already exists; checking incremental migrations"
    apply_incremental_migrations
    return 0
  fi

  log "Applying database migrations"
  local migration
  while IFS= read -r migration; do
    [[ -n "$migration" ]] || continue
    printf 'Applying %s\n' "$migration"
    apply_migration_file "$migration"
  done < <(list_migration_files)
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

  log "Using gateway provider: ${PROVIDER:-fake}"
}

seed_default_data() {
  local api_key_hash
  local pool_status="active"
  local account_status="active"
  local membership_status="active"
  api_key_hash="$(printf '%s' "$API_KEY" | sha256sum | awk '{print $1}')"

  if [[ "${PROVIDER:-fake}" != "fake" ]]; then
    pool_status="inactive"
    account_status="quarantined"
    membership_status="inactive"
  fi

  log "Ensuring default pool, account, and client profile"
  db_psql -v ON_ERROR_STOP=1 <<SQL
INSERT INTO backend_pools (id, name, status, priority, created_at, updated_at)
VALUES ('00000000-0000-0000-0000-000000000201', 'default-pool', '$pool_status', 1, now(), now())
ON CONFLICT (id) DO UPDATE SET status = '$pool_status', priority = 1, updated_at = now();

INSERT INTO accounts (id, name, provider, account_source, github_login, status, risk_score, priority, max_concurrency, current_failure_count, created_at, updated_at)
VALUES ('00000000-0000-0000-0000-000000000202', 'default-fake-account', 'fake', 'personal', 'default-fake', '$account_status', 0, 1, 10, 0, now(), now())
ON CONFLICT (id) DO UPDATE SET status = '$account_status', risk_score = 0, priority = 1, max_concurrency = 10, current_failure_count = 0, updated_at = now();

INSERT INTO pool_accounts (pool_id, account_id, weight, status, created_at)
VALUES ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000202', 100, '$membership_status', now())
ON CONFLICT (pool_id, account_id) DO UPDATE SET weight = 100, status = '$membership_status';

INSERT INTO client_profiles (id, name, api_key_hash, default_request_format, default_response_format, default_model, model_aliases, sticky_mode, sticky_ttl_seconds, cache_affinity_enabled, max_sticky_load_ratio, enabled, created_at, updated_at)
VALUES ('00000000-0000-0000-0000-000000000203', 'default-client', '$api_key_hash', 'openai_chat', 'openai_chat', 'gpt-4o', '{}', 'soft', 1800, true, 0.85, true, now(), now())
ON CONFLICT (id) DO UPDATE SET api_key_hash = EXCLUDED.api_key_hash, enabled = true, default_model = 'gpt-4o', updated_at = now();
SQL
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
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
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
  kill "$pid" 2>/dev/null || true
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
  GHCP_PROXY_HOME="$DATA_DIR" \
    ENV_FILE="$ENV_FILE" \
    COMPOSE_FILE="$COMPOSE_FILE" \
    COMPOSE_PROJECT_NAME="$PROJECT_NAME" \
    LOG_DIR="$LOG_DIR" \
    RUN_DIR="$RUN_DIR" \
    LOG_RETENTION_DAYS="$LOG_RETENTION_DAYS" \
    nohup "$SCRIPT_PATH" __collect-logs >> "$LOG_DIR/log-collector.log" 2>&1 &
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
  prepare_directories
  write_env_file_if_missing
  load_environment
  prepare_directories
  pull_runtime_images
  start_data_services
  apply_migrations_if_needed
  load_runtime_environment
  seed_default_data
  start_app_services
  run_start_checks
  start_log_collector

  cat <<EOF

VM stack is ready.
  Gateway:       $GATEWAY_URL
  Admin UI:      $ADMIN_URL/
  Data dir:      $DATA_DIR
  Log dir:       $LOG_DIR
  Log retention: ${LOG_RETENTION_DAYS} days
  Env file:      $ENV_FILE

Useful commands:
  $SCRIPT_PATH --logs
  $SCRIPT_PATH --stop
EOF
}

stop_stack() {
  require_common_cmds
  if [[ ! -f "$ENV_FILE" ]]; then
    warn "environment file not found: $ENV_FILE"
    return 0
  fi
  load_environment
  prepare_directories
  stop_log_collector
  log "Stopping VM stack"
  compose down
  printf '\nVM stack stopped. Persistent data was preserved in %s.\n' "$DATA_DIR"
}

show_logs() {
  require_common_cmds
  [[ -f "$ENV_FILE" ]] || die "environment file not found: $ENV_FILE"
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