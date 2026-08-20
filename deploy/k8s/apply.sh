#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVIRONMENT="${1:-}"
MODE="${2:-apply}"
KUBECTL="${KUBECTL:-kubectl}"
KUSTOMIZE="${KUSTOMIZE:-kustomize}"
MIGRATION_TIMEOUT="${MIGRATION_TIMEOUT:-15m}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-5m}"
RELEASE_MANIFEST="${RELEASE_MANIFEST:-}"
RELEASE_MANIFEST_TOOL="$SCRIPT_DIR/../../scripts/release_manifest.sh"

case "$ENVIRONMENT" in
  staging)
    NAMESPACE="${NAMESPACE:-ghcp-staging}"
    ;;
  production)
    NAMESPACE="${NAMESPACE:-ghcp-system}"
    ;;
  test)
    NAMESPACE="${NAMESPACE:-ghcp-test}"
    ;;
  *)
    printf 'Usage: %s staging|production|test [--render]\n' "$0" >&2
    exit 2
    ;;
esac

[[ "$MODE" == "apply" || "$MODE" == "--render" ]] || { printf 'unsupported mode: %s\n' "$MODE" >&2; exit 2; }
if [[ "$MODE" == "apply" ]]; then
  command -v "$KUBECTL" >/dev/null 2>&1 || { printf '%s is required\n' "$KUBECTL" >&2; exit 1; }
fi
command -v "$KUSTOMIZE" >/dev/null 2>&1 || { printf '%s is required\n' "$KUSTOMIZE" >&2; exit 1; }
[[ -x "$RELEASE_MANIFEST_TOOL" ]] || { printf 'release manifest tool is missing: %s\n' "$RELEASE_MANIFEST_TOOL" >&2; exit 1; }
[[ -n "$RELEASE_MANIFEST" && -r "$RELEASE_MANIFEST" ]] || { printf 'RELEASE_MANIFEST must reference a readable release-manifest.env\n' >&2; exit 1; }

KUBE_ARGS=()
if [[ -n "${KUBE_CONTEXT:-}" ]]; then
  KUBE_ARGS+=(--context "$KUBE_CONTEXT")
fi

kube() {
  "$KUBECTL" "${KUBE_ARGS[@]}" "$@"
}

validate_images() {
  local manifest="$1"
  local require_digest="$2"
  local image
  local count=0
  while read -r image; do
    [[ -n "$image" ]] || continue
    count=$((count + 1))
    if [[ "$image" == registry.invalid/* ]]; then
      printf 'Image must be configured before deployment: %s\n' "$image" >&2
      return 1
    fi
    if [[ "$ENVIRONMENT" == "test" && ( "$image" == "postgres:16-alpine" || "$image" == "redis:7-alpine" ) ]]; then
      continue
    fi
    if [[ "$require_digest" == "true" && ! "$image" =~ @sha256:[0-9a-f]{64}$ ]]; then
      printf 'Production images must use immutable digests: %s\n' "$image" >&2
      return 1
    fi
  done < <(awk '$1 == "image:" { print $2 }' "$manifest")
  ((count > 0)) || { printf 'No images found in rendered manifest\n' >&2; return 1; }
}

release_image_ref() {
  "$RELEASE_MANIFEST_TOOL" image-ref "$RELEASE_MANIFEST" "$1"
}

release_image_tag() {
  "$RELEASE_MANIFEST_TOOL" image-tag "$RELEASE_MANIFEST" "$1"
}

rewrite_release_images() {
  local gateway_ref admin_ref worker_ref migration_ref
  local gateway_tag admin_tag worker_tag migration_tag
  gateway_ref="$(release_image_ref gateway)"
  admin_ref="$(release_image_ref admin)"
  worker_ref="$(release_image_ref worker)"
  migration_ref="$(release_image_ref migration)"
  gateway_tag="$(release_image_tag gateway)"
  admin_tag="$(release_image_tag admin)"
  worker_tag="$(release_image_tag worker)"
  migration_tag="$(release_image_tag migration)"

  sed \
    -e "s|registry.invalid/ghcp-pool-proxy/gateway:replace-me|$gateway_ref|g" \
    -e "s|registry.invalid/ghcp-pool-proxy/admin:replace-me|$admin_ref|g" \
    -e "s|registry.invalid/ghcp-pool-proxy/worker:replace-me|$worker_ref|g" \
    -e "s|registry.invalid/ghcp-pool-proxy/migration:replace-me|$migration_ref|g" \
    -e "s|$gateway_tag|$gateway_ref|g" \
    -e "s|$admin_tag|$admin_ref|g" \
    -e "s|$worker_tag|$worker_ref|g" \
    -e "s|$migration_tag|$migration_ref|g"
}

validate_release_schema() {
  local expected_schema actual_schema
  expected_schema="$(tr -d '[:space:]' < "$SCRIPT_DIR/../../migrations/schema_version")"
  "$RELEASE_MANIFEST_TOOL" validate "$RELEASE_MANIFEST" "$expected_schema"
  actual_schema="$(awk '
    $0 ~ /^[[:space:]]*-[[:space:]]name: MIGRATION_TARGET_VERSION$/ { expecting=1; next }
    expecting && $0 ~ /^[[:space:]]*value:/ { gsub(/"/, "", $2); print $2; exit }
  ' "$MIGRATION_MANIFEST")"
  [[ "$actual_schema" == "$expected_schema" ]] || {
    printf 'migration manifest schema %s does not match release schema %s\n' "$actual_schema" "$expected_schema" >&2
    return 1
  }
}

OVERLAY_DIR="$SCRIPT_DIR/overlays/$ENVIRONMENT"
APP_OVERLAY_DIR="${APP_OVERLAY_DIR:-$OVERLAY_DIR}"
APP_MANIFEST="$(mktemp)"
MIGRATION_MANIFEST="$(mktemp)"
TEST_DATA_MANIFEST=""
trap 'rm -f "$APP_MANIFEST" "$MIGRATION_MANIFEST" "$TEST_DATA_MANIFEST"' EXIT

KUSTOMIZE_BUILD_ARGS=()
if [[ "${KUSTOMIZE_LOAD_RESTRICTOR_NONE:-false}" == "true" ]]; then
  KUSTOMIZE_BUILD_ARGS+=(--load-restrictor LoadRestrictionsNone)
fi

"$KUSTOMIZE" build "${KUSTOMIZE_BUILD_ARGS[@]}" "$APP_OVERLAY_DIR" | rewrite_release_images > "$APP_MANIFEST"
"$KUSTOMIZE" build "$OVERLAY_DIR/migration" | rewrite_release_images > "$MIGRATION_MANIFEST"
if [[ "$ENVIRONMENT" == "test" ]]; then
  TEST_DATA_MANIFEST="$(mktemp)"
  "$KUSTOMIZE" build "$OVERLAY_DIR/data" > "$TEST_DATA_MANIFEST"
fi
validate_release_schema
validate_images "$APP_MANIFEST" true
validate_images "$MIGRATION_MANIFEST" true

if [[ "$MODE" == "--render" ]]; then
  if [[ "$ENVIRONMENT" == "test" ]]; then
    cat "$TEST_DATA_MANIFEST"
    printf '%s\n' '---'
  fi
  cat "$MIGRATION_MANIFEST"
  printf '%s\n' '---'
  cat "$APP_MANIFEST"
  exit 0
fi

kube apply -f "$OVERLAY_DIR/namespace.yaml"
if [[ "$ENVIRONMENT" == "test" ]]; then
  kube apply -f "$TEST_DATA_MANIFEST"
  for deployment in ghcp-test-postgres ghcp-test-redis; do
    kube -n "$NAMESPACE" rollout status "deployment/$deployment" --timeout="$ROLLOUT_TIMEOUT"
  done
fi
kube -n "$NAMESPACE" get secret ghcp-runtime-secrets ghcp-migration-postgres-dsn >/dev/null

kube -n "$NAMESPACE" delete job ghcp-migrate --ignore-not-found --wait=true
kube apply -f "$MIGRATION_MANIFEST"
if ! kube -n "$NAMESPACE" wait --for=condition=complete job/ghcp-migrate --timeout="$MIGRATION_TIMEOUT"; then
  kube -n "$NAMESPACE" logs job/ghcp-migrate --all-containers=true || true
  exit 1
fi

if [[ "${APPLY_MONITORING:-auto}" != "false" ]] &&
  kube get customresourcedefinition servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  kube -n "$NAMESPACE" apply -k "$SCRIPT_DIR/components/monitoring"
fi

kube apply -f "$APP_MANIFEST" -l '!app.kubernetes.io/component'
for component in gateway admin worker; do
  kube apply -f "$APP_MANIFEST" -l "app.kubernetes.io/component=$component"
done
for deployment in ghcp-gateway ghcp-admin ghcp-worker ghcp-org-sync-worker; do
  kube -n "$NAMESPACE" rollout status "deployment/$deployment" --timeout="$ROLLOUT_TIMEOUT"
done

printf 'GHCP Pool Proxy %s rollout completed in namespace %s\n' "$ENVIRONMENT" "$NAMESPACE"
