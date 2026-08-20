#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY_SCRIPT="$SCRIPT_DIR/k8s/apply.sh"
PREREQUISITES_SCRIPT="$SCRIPT_DIR/lib/prerequisites.sh"
AZURE_SCRIPT="$SCRIPT_DIR/lib/azure.sh"
AZURE_TEMPLATE="$SCRIPT_DIR/azure/main.bicep"

[[ -r "$PREREQUISITES_SCRIPT" ]] || {
  printf 'ERROR: prerequisite installer is missing: %s\n' "$PREREQUISITES_SCRIPT" >&2
  exit 1
}
# shellcheck disable=SC1090
source "$PREREQUISITES_SCRIPT"
[[ -r "$AZURE_SCRIPT" ]] || {
  printf 'ERROR: Azure deployment helper is missing: %s\n' "$AZURE_SCRIPT" >&2
  exit 1
}
# shellcheck disable=SC1090
source "$AZURE_SCRIPT"

MODE=""
ENVIRONMENT="${CLUSTER_ENVIRONMENT:-}"
ENVIRONMENT_SET=0
ACTION="apply"
ACTION_SET=0
ASSUME_YES=0
INSTALL_MISSING=0
KUBECTL="${KUBECTL:-kubectl}"
KUSTOMIZE="${KUSTOMIZE:-kustomize}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
RELEASE_MANIFEST="${RELEASE_MANIFEST:-${RELEASE_MANIFEST_FILE:-$SCRIPT_DIR/../release-manifest.env}}"
LOCAL_CLUSTER_NAME="${LOCAL_CLUSTER_NAME:-ghcp-local}"
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
AZURE_ORIGINAL_SUBSCRIPTION_ID=""
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
AZURE_RESOURCE_GROUP_MODE="${AZURE_RESOURCE_GROUP_MODE:-}"
AZURE_LOCATION="${AZURE_LOCATION:-}"
AZURE_DEPLOYMENT_NAME="${AZURE_DEPLOYMENT_NAME:-}"
AZURE_PARAMETERS_FILE=""
AZURE_APP_OVERLAY_DIR=""
WORK_DIR=""
SECRET_DIR=""
NAMESPACE=""

usage() {
  cat <<'EOF'
Usage: deploy/deploy-cluster.sh [local|azure] [apply|render] [options]

Modes:
  local       Deploy the self-contained single-node test profile with in-cluster
              PostgreSQL and Redis. Data is disposable and is not an HA profile.
  azure       Deploy production or staging on Azure Kubernetes with external
              PostgreSQL and Redis PaaS services.

Actions:
  apply       Apply infrastructure/manifests and wait for rollout. Default.
  deploy      Alias for apply, matching deploy/deploy.sh deploy.
  render      Render and validate manifests without changing a cluster.

Options:
  --environment NAME       Azure overlay: production (default) or staging.
  --context NAME           kubectl context. Default: current context.
  --local-cluster-name NAME
                           Kind cluster managed by local mode. Default: ghcp-local.
  --subscription ID        Azure subscription for validation and deployment.
  --resource-group NAME    Azure deployment resource group.
  --location NAME          Azure region used by newly created resources.
  --release-manifest FILE  Immutable release-set manifest.
  --apply                  Explicit alias for the default apply action.
  --render                 Alias for the render action.
  --install-missing        Allow non-interactive installation of missing prerequisites.
  --yes                    Accept deployment/resource confirmations. Does not install tools.
  -h, --help               Show this help.

Shared environment:
  RELEASE_MANIFEST         Immutable release-set manifest.
  RELEASE_MANIFEST_FILE    Legacy alias used only when RELEASE_MANIFEST is unset.

Azure resource choices are prompted as create or reuse. They can also be supplied with:
  AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP, AZURE_RESOURCE_GROUP_MODE
  AZURE_LOCATION, VNET_MODE, AKS_SUBNET_MODE, POSTGRES_SUBNET_MODE
  PRIVATE_ENDPOINT_SUBNET_MODE, AKS_MODE, POSTGRES_MODE, REDIS_MODE
  VNET_RESOURCE_ID, *_SUBNET_RESOURCE_ID, AKS_RESOURCE_ID
  POSTGRES_RESOURCE_ID, REDIS_RESOURCE_ID and corresponding *_NAME values
  POSTGRES_DSN, MIGRATION_POSTGRES_DSN, REDIS_PASSWORD
  ADMIN_TOKEN, CREDENTIAL_MASTER_KEY, CREDENTIAL_KEY_VERSION, GITHUB_TOKEN

Interactive reuse lists visible resources as numbered choices. Enter accepts [1];
select 0 to enter a resource group name or complete ARM resource ID manually.
Sensitive values are read without terminal echo and are never written to generated
manifests. For non-interactive changes, set the variables above and pass --yes;
also pass --install-missing when the script may install prerequisites.
EOF
}

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

cleanup() {
  if [[ -n "$AZURE_ORIGINAL_SUBSCRIPTION_ID" ]] && command -v az >/dev/null 2>&1; then
    az account set --subscription "$AZURE_ORIGINAL_SUBSCRIPTION_ID" >/dev/null 2>&1 || true
  fi
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
  [[ -z "$SECRET_DIR" ]] || rm -rf "$SECRET_DIR"
  [[ -z "$AZURE_PARAMETERS_FILE" ]] || rm -f "$AZURE_PARAMETERS_FILE"
}
trap cleanup EXIT

expand_path() {
  local path="$1"
  case "$path" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${path#~/}" ;;
    /*) printf '%s\n' "$path" ;;
    *) printf '%s/%s\n' "$PWD" "$path" ;;
  esac
}

set_mode() {
  [[ -z "$MODE" || "$MODE" == "$1" ]] || die "only one cluster mode can be selected"
  MODE="$1"
}

set_cluster_action() {
  local next_action="$1"
  if [[ "$ACTION_SET" -eq 1 && "$ACTION" != "$next_action" ]]; then
    die "only one cluster action can be selected"
  fi
  ACTION="$next_action"
  ACTION_SET=1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    local|azure)
      set_mode "$1"
      ;;
    apply|deploy|--apply)
      set_cluster_action apply
      ;;
    render|--render)
      set_cluster_action --render
      ;;
    --environment)
      [[ $# -ge 2 ]] || die "--environment requires a value"
      ENVIRONMENT="$2"
      ENVIRONMENT_SET=1
      shift
      ;;
    --context)
      [[ $# -ge 2 ]] || die "--context requires a value"
      KUBE_CONTEXT="$2"
      shift
      ;;
    --local-cluster-name)
      [[ $# -ge 2 ]] || die "--local-cluster-name requires a value"
      LOCAL_CLUSTER_NAME="$2"
      shift
      ;;
    --subscription)
      [[ $# -ge 2 ]] || die "--subscription requires a value"
      AZURE_SUBSCRIPTION_ID="$2"
      shift
      ;;
    --resource-group)
      [[ $# -ge 2 ]] || die "--resource-group requires a value"
      AZURE_RESOURCE_GROUP="$2"
      shift
      ;;
    --location)
      [[ $# -ge 2 ]] || die "--location requires a value"
      AZURE_LOCATION="$2"
      shift
      ;;
    --release-manifest)
      [[ $# -ge 2 ]] || die "--release-manifest requires a value"
      RELEASE_MANIFEST="$2"
      shift
      ;;
    --install-missing)
      INSTALL_MISSING=1
      ;;
    --yes)
      ASSUME_YES=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option or mode: $1"
      ;;
  esac
  shift
done

prompt_mode() {
  [[ -t 0 ]] || die "select local or azure when running non-interactively"
  printf 'Cluster deployment mode:\n  1) local - single-node, in-cluster disposable PostgreSQL/Redis\n  2) azure - AKS with PostgreSQL/Redis PaaS\nSelect [1]: ' >&2
  local answer
  IFS= read -r answer
  case "${answer:-1}" in
    1|local) MODE="local" ;;
    2|azure) MODE="azure" ;;
    *) die "invalid deployment mode: $answer" ;;
  esac
}

prompt_default() {
  local variable_name="$1"
  local label="$2"
  local default_value="$3"
  local current_value="${!variable_name:-}"
  local answer
  [[ -n "$current_value" ]] && return 0
  if [[ ! -t 0 ]]; then
    printf -v "$variable_name" '%s' "$default_value"
    return 0
  fi
  printf '%s [%s]: ' "$label" "$default_value" >&2
  IFS= read -r answer
  printf -v "$variable_name" '%s' "${answer:-$default_value}"
}

prompt_secret() {
  local variable_name="$1"
  local label="$2"
  local current_value="${!variable_name:-}"
  [[ -n "$current_value" ]] && return 0
  [[ -t 0 ]] || die "$variable_name is required in non-interactive mode"
  printf '%s: ' "$label" >&2
  IFS= read -r -s current_value
  printf '\n' >&2
  [[ -n "$current_value" ]] || die "$variable_name cannot be empty"
  printf -v "$variable_name" '%s' "$current_value"
}

prompt_migration_dsn() {
  [[ -n "${MIGRATION_POSTGRES_DSN:-}" ]] && return 0
  local default_value="${1:-$POSTGRES_DSN}"
  if [[ ! -t 0 ]]; then
    [[ -n "$default_value" ]] || die "MIGRATION_POSTGRES_DSN is required in non-interactive mode"
    MIGRATION_POSTGRES_DSN="$default_value"
    return 0
  fi
  printf 'Migration PostgreSQL DSN [Enter to use the prepared default]: ' >&2
  IFS= read -r -s MIGRATION_POSTGRES_DSN
  printf '\n' >&2
  MIGRATION_POSTGRES_DSN="${MIGRATION_POSTGRES_DSN:-$default_value}"
}

select_azure_environment() {
  if [[ "$ENVIRONMENT_SET" -eq 0 && -t 0 ]]; then
    printf 'Azure overlay:\n  1) production - one Gateway\n  2) staging - two Gateways (requires two schedulable nodes)\nSelect [1]: ' >&2
    local answer
    IFS= read -r answer
    case "${answer:-1}" in
      1|production) ENVIRONMENT="production" ;;
      2|staging) ENVIRONMENT="staging" ;;
      *) die "invalid Azure environment: $answer" ;;
    esac
  fi
  ENVIRONMENT="${ENVIRONMENT:-production}"
  [[ "$ENVIRONMENT" == "production" || "$ENVIRONMENT" == "staging" ]] || {
    die "Azure environment must be production or staging"
  }
}

select_kube_context() {
  [[ "$ACTION" == "apply" ]] || return 0
  local current_context=""
  if [[ -z "$KUBE_CONTEXT" ]]; then
    current_context="$($KUBECTL config current-context 2>/dev/null || true)"
    if [[ -t 0 ]]; then
      prompt_default KUBE_CONTEXT "Kubernetes context" "${current_context:-current}"
      [[ "$KUBE_CONTEXT" != "current" ]] || KUBE_CONTEXT=""
    fi
  fi
}

ensure_kubernetes_client_tools() {
  if [[ "$KUBECTL" == "kubectl" && "$KUSTOMIZE" == "kustomize" ]]; then
    prereq_ensure_kubernetes_client_tools
    return
  fi
  require_cmd "$KUBECTL"
  require_cmd "$KUSTOMIZE"
}

ensure_local_tools() {
  if [[ "$KUBECTL" == "kubectl" && "$KUSTOMIZE" == "kustomize" ]]; then
    prereq_ensure_local_cluster_tools
    return
  fi
  require_cmd docker
  require_cmd kind
  ensure_kubernetes_client_tools
  docker info >/dev/null 2>&1 || die "Docker daemon is not available"
}

confirm_kind_creation() {
  [[ "$ASSUME_YES" -eq 0 ]] || return 0
  [[ -t 0 ]] || die "--yes is required to create a Kind cluster non-interactively"
  local answer
  printf 'Kind cluster %s does not exist. Create it now? [y/N]: ' "$LOCAL_CLUSTER_NAME" >&2
  IFS= read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || die "Kind cluster creation cancelled"
}

prepare_local_cluster() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    kube cluster-info >/dev/null || die "Kubernetes context is not reachable: $KUBE_CONTEXT"
    return
  fi

  [[ "$LOCAL_CLUSTER_NAME" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || {
    die "local Kind cluster name contains unsupported characters"
  }
  [[ -n "$WORK_DIR" ]] || WORK_DIR="$(mktemp -d)"
  local kubeconfig="$WORK_DIR/kind-kubeconfig"
  if ! kind get clusters 2>/dev/null | grep -Fqx "$LOCAL_CLUSTER_NAME"; then
    confirm_kind_creation
    log "Creating single-node Kind cluster $LOCAL_CLUSTER_NAME"
    kind create cluster --name "$LOCAL_CLUSTER_NAME" --kubeconfig "$kubeconfig"
  else
    kind get kubeconfig --name "$LOCAL_CLUSTER_NAME" > "$kubeconfig"
  fi
  chmod 600 "$kubeconfig"
  export KUBECONFIG="$kubeconfig"
  KUBE_CONTEXT="kind-$LOCAL_CLUSTER_NAME"
  kube cluster-info >/dev/null || die "Kind cluster API is not reachable"

  local node_count
  node_count="$(kube get nodes --no-headers 2>/dev/null | awk 'NF { count++ } END { print count + 0 }')"
  [[ "$node_count" == "1" ]] || {
    die "local mode requires exactly one Kubernetes node; context has $node_count"
  }
}

confirm_deployment() {
  [[ "$ACTION" == "apply" && "$ASSUME_YES" -eq 0 ]] || return 0
  [[ -t 0 ]] || die "--yes is required for a non-interactive deployment"
  printf 'Deploy mode=%s environment=%s namespace=%s context=%s? [y/N]: ' \
    "$MODE" "$ENVIRONMENT" "$NAMESPACE" "${KUBE_CONTEXT:-current}" >&2
  local answer
  IFS= read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || die "deployment cancelled"
}

kube() {
  local args=()
  [[ -z "$KUBE_CONTEXT" ]] || args+=(--context "$KUBE_CONTEXT")
  "$KUBECTL" "${args[@]}" "$@"
}

validate_azure_values() {
  [[ "$REDIS_ADDR" =~ ^[A-Za-z0-9._-]+:([0-9]+)$ ]] || {
    die "REDIS_ADDR must be one host:port endpoint"
  }
  REDIS_PORT="${BASH_REMATCH[1]}"
  ((REDIS_PORT >= 1 && REDIS_PORT <= 65535)) || die "REDIS_ADDR port is invalid"
  [[ "$POSTGRES_PORT" =~ ^[0-9]+$ ]] || die "POSTGRES_PORT must be numeric"
  ((POSTGRES_PORT >= 1 && POSTGRES_PORT <= 65535)) || die "POSTGRES_PORT is invalid"
  [[ "$REDIS_TLS_SERVER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || {
    die "REDIS_TLS_SERVER_NAME must be a DNS hostname"
  }
  [[ "$CREDENTIAL_KEY_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || {
    die "CREDENTIAL_KEY_VERSION contains unsupported characters"
  }
}

validate_credential_key() {
  if ((${#CREDENTIAL_MASTER_KEY} == 32)); then
    return 0
  fi
  if [[ "$CREDENTIAL_MASTER_KEY" =~ ^[0-9A-Fa-f]{64}$ ]]; then
    return 0
  fi
  die "CREDENTIAL_MASTER_KEY must be 32 characters or 64 hexadecimal characters"
}

prepare_azure_overlay() {
  [[ -n "$WORK_DIR" ]] || WORK_DIR="$(mktemp -d)"
  AZURE_APP_OVERLAY_DIR="$WORK_DIR/application-overlay"
  mkdir -p "$AZURE_APP_OVERLAY_DIR"
  ln -s "$SCRIPT_DIR/k8s/overlays/$ENVIRONMENT" "$AZURE_APP_OVERLAY_DIR/base"
  cat > "$AZURE_APP_OVERLAY_DIR/runtime.env" <<EOF
PROVIDER=copilot
REDIS_CLIENT_MODE=single
REDIS_PROTOCOL_VERSION=2
REDIS_ADDR=$REDIS_ADDR
REDIS_DB=0
REDIS_TLS=true
REDIS_TLS_SERVER_NAME=$REDIS_TLS_SERVER_NAME
CREDENTIAL_KEY_VERSION=$CREDENTIAL_KEY_VERSION
EOF
  cat > "$AZURE_APP_OVERLAY_DIR/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - base
configMapGenerator:
  - name: ghcp-runtime-env
    behavior: merge
    envs:
      - runtime.env
patches:
  - target:
      kind: NetworkPolicy
      name: allow-application-egress
    patch: |-
      - op: replace
        path: /spec/egress/0/ports
        value:
          - protocol: TCP
            port: 443
          - protocol: TCP
            port: $POSTGRES_PORT
          - protocol: TCP
            port: $REDIS_PORT
  - target:
      kind: NetworkPolicy
      name: allow-migration-egress
    patch: |-
      - op: replace
        path: /spec/egress/0/ports
        value:
          - protocol: TCP
            port: $POSTGRES_PORT
EOF
}

write_secret_file() {
  local name="$1"
  local value="$2"
  printf '%s' "$value" > "$SECRET_DIR/$name"
}

apply_azure_secrets() {
  umask 077
  SECRET_DIR="$(mktemp -d)"
  write_secret_file ADMIN_TOKEN "$ADMIN_TOKEN"
  write_secret_file POSTGRES_DSN "$POSTGRES_DSN"
  write_secret_file REDIS_PASSWORD "$REDIS_PASSWORD"
  write_secret_file CREDENTIAL_MASTER_KEY "$CREDENTIAL_MASTER_KEY"
  write_secret_file postgres-dsn "$MIGRATION_POSTGRES_DSN"
  write_secret_file github-token "$GITHUB_TOKEN"

  kube apply -f "$SCRIPT_DIR/k8s/overlays/$ENVIRONMENT/namespace.yaml"
  kube -n "$NAMESPACE" create secret generic ghcp-runtime-secrets \
    --from-file="ADMIN_TOKEN=$SECRET_DIR/ADMIN_TOKEN" \
    --from-file="POSTGRES_DSN=$SECRET_DIR/POSTGRES_DSN" \
    --from-file="REDIS_PASSWORD=$SECRET_DIR/REDIS_PASSWORD" \
    --from-file="CREDENTIAL_MASTER_KEY=$SECRET_DIR/CREDENTIAL_MASTER_KEY" \
    --dry-run=client -o yaml | kube apply -f -
  kube -n "$NAMESPACE" create secret generic ghcp-migration-postgres-dsn \
    --from-file="postgres-dsn=$SECRET_DIR/postgres-dsn" \
    --dry-run=client -o yaml | kube apply -f -
  kube -n "$NAMESPACE" create secret generic ghcp-org-sync-worker-secrets \
    --from-file="github-token=$SECRET_DIR/github-token" \
    --dry-run=client -o yaml | kube apply -f -
}

run_rollout() {
  local app_overlay=""
  local unrestricted="false"
  if [[ "$MODE" == "azure" ]]; then
    app_overlay="$AZURE_APP_OVERLAY_DIR"
    unrestricted="true"
  fi
  APP_OVERLAY_DIR="$app_overlay" \
    KUSTOMIZE_LOAD_RESTRICTOR_NONE="$unrestricted" \
    KUBECTL="$KUBECTL" \
    KUSTOMIZE="$KUSTOMIZE" \
    KUBE_CONTEXT="$KUBE_CONTEXT" \
    RELEASE_MANIFEST="$RELEASE_MANIFEST" \
    "$APPLY_SCRIPT" "$ENVIRONMENT" "$ACTION"
}

[[ -n "$MODE" ]] || prompt_mode
[[ -x "$APPLY_SCRIPT" ]] || die "Kubernetes rollout script is missing: $APPLY_SCRIPT"
RELEASE_MANIFEST="$(expand_path "$RELEASE_MANIFEST")"
[[ -r "$RELEASE_MANIFEST" ]] || die "release manifest is not readable: $RELEASE_MANIFEST"
PREREQ_AUTO_INSTALL="$INSTALL_MISSING"
prereq_read_os

case "$MODE" in
  local)
    [[ "$ENVIRONMENT_SET" -eq 0 ]] || die "--environment is only valid for azure mode"
    ENVIRONMENT="test"
    NAMESPACE="ghcp-test"
    if [[ "$ACTION" == "apply" ]]; then
      if [[ -n "$KUBE_CONTEXT" ]]; then
        ensure_kubernetes_client_tools
      else
        ensure_local_tools
      fi
      prepare_local_cluster
    else
      if [[ "$KUSTOMIZE" == "kustomize" ]]; then
        prereq_ensure_command kustomize Kustomize
      else
        require_cmd "$KUSTOMIZE"
      fi
    fi
    confirm_deployment
    log "Using the disposable single-node Kubernetes profile"
    run_rollout
    ;;
  azure)
    select_azure_environment
    case "$ENVIRONMENT" in
      production) NAMESPACE="ghcp-system" ;;
      staging) NAMESPACE="ghcp-staging" ;;
    esac
    azure_prepare_infrastructure
    prompt_default CREDENTIAL_KEY_VERSION "Credential key version" "$(date -u +%Y-%m)"
    validate_azure_values
    prepare_azure_overlay
    if [[ "$ACTION" == "apply" ]]; then
      azure_prepare_kube_context
      prompt_secret POSTGRES_DSN "Runtime PostgreSQL DSN (use a least-privilege DML role)"
      default_migration_dsn="$(azure_default_migration_dsn)"
      prompt_migration_dsn "$default_migration_dsn"
      azure_load_redis_password
      prompt_secret ADMIN_TOKEN "Admin API token"
      prompt_secret CREDENTIAL_MASTER_KEY "Credential master key (32 characters or 64 hex)"
      validate_credential_key
      prompt_secret GITHUB_TOKEN "GitHub token for organization sync"
    fi
    confirm_deployment
    if [[ "$ACTION" == "apply" ]]; then
      log "Applying namespace-scoped cluster secrets"
      apply_azure_secrets
    fi
    log "Using Azure PaaS endpoints with the $ENVIRONMENT overlay"
    run_rollout
    ;;
esac