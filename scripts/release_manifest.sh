#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/release_manifest.sh create OUTPUT
  scripts/release_manifest.sh validate MANIFEST [EXPECTED_SCHEMA] [EXPECTED_GIT_SHA]
  scripts/release_manifest.sh validate-source MANIFEST EXPECTED_SCHEMA REPOSITORY
  scripts/release_manifest.sh value MANIFEST KEY
  scripts/release_manifest.sh image-tag MANIFEST ROLE
  scripts/release_manifest.sh image-ref MANIFEST ROLE

The manifest is a non-sensitive dotenv-style release set. It binds all runtime
images to one app version, one Git revision, and one database schema version.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

manifest_value() {
  local manifest="$1"
  local key="$2"
  local value
  value="$(awk -F= -v key="$key" '$1 == key { if (seen++) exit 2; print substr($0, length(key) + 2) }' "$manifest")" || die "manifest contains duplicate key $key"
  [[ -n "$value" ]] || die "manifest is missing $key"
  printf '%s\n' "$value"
}

required_role_tag() {
  case "$1" in
    gateway) printf '%s\n' gateway-latest ;;
    admin) printf '%s\n' admin-latest ;;
    worker) printf '%s\n' worker-latest ;;
    migration) printf '%s\n' migration-latest ;;
    *) die "unsupported release role $1" ;;
  esac
}

validate_manifest() {
  local manifest="$1"
  local expected_schema="${2:-}"
  local expected_git_sha="${3:-}"
  [[ -r "$manifest" ]] || die "release manifest is not readable: $manifest"

  local version git_sha app_version schema repository role tag digest
  version="$(manifest_value "$manifest" RELEASE_MANIFEST_VERSION)"
  git_sha="$(manifest_value "$manifest" RELEASE_GIT_SHA)"
  app_version="$(manifest_value "$manifest" RELEASE_APP_VERSION)"
  schema="$(manifest_value "$manifest" RELEASE_SCHEMA_VERSION)"
  repository="$(manifest_value "$manifest" RELEASE_IMAGE_REPOSITORY)"
  [[ "$version" == "1" ]] || die "unsupported release manifest version $version"
  [[ "$git_sha" =~ ^[0-9a-f]{40}$ ]] || die "release manifest Git SHA is invalid"
  [[ -n "$app_version" && "$app_version" != "dev" && "$app_version" != "unknown" && "$app_version" != *' '* ]] || die "release manifest app version is not immutable"
  [[ "$schema" =~ ^[1-9][0-9]*$ ]] || die "release manifest schema is invalid"
  [[ -n "$repository" && "$repository" != *' '* && "$repository" != *'@'* ]] || die "release manifest repository is invalid"
  if [[ -n "$expected_schema" && "$schema" != "$expected_schema" ]]; then
    die "release manifest schema $schema does not match expected schema $expected_schema"
  fi
  if [[ -n "$expected_git_sha" ]]; then
    [[ "$expected_git_sha" =~ ^[0-9a-f]{40}$ ]] || die "expected release Git SHA is invalid"
    [[ "$git_sha" == "$expected_git_sha" ]] || die "release manifest Git SHA $git_sha does not match expected release source $expected_git_sha"
  fi

  for role in gateway admin worker migration; do
    tag="$(manifest_value "$manifest" "RELEASE_${role^^}_TAG")"
    digest="$(manifest_value "$manifest" "RELEASE_${role^^}_DIGEST")"
    [[ "$tag" == "$(required_role_tag "$role")" ]] || die "release manifest $role tag must be $(required_role_tag "$role")"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "release manifest $role digest is invalid"
  done
}

validate_source() {
  local manifest="$1"
  local expected_schema="$2"
  local repository="$3"
  local repository_root manifest_dir manifest_path manifest_relative git_sha status
  command -v git >/dev/null 2>&1 || die "git is required to validate a release source"
  repository_root="$(git -C "$repository" rev-parse --show-toplevel 2>/dev/null)" || die "release source is not a Git repository: $repository"
  git_sha="$(git -C "$repository_root" rev-parse HEAD)"
  validate_manifest "$manifest" "$expected_schema" "$git_sha"

  manifest_dir="$(cd "$(dirname "$manifest")" && pwd -P)"
  manifest_path="$manifest_dir/$(basename "$manifest")"
  if [[ "$manifest_path" == "$repository_root/"* ]]; then
    manifest_relative="${manifest_path#"$repository_root/"}"
    status="$(git -C "$repository_root" status --porcelain --untracked-files=all -- . ":(top,exclude,literal)$manifest_relative")"
  else
    status="$(git -C "$repository_root" status --porcelain --untracked-files=all)"
  fi
  [[ -z "$status" ]] || die "working tree is not clean; package and publish must use one committed release source"
}

local_image_digest() {
  local image="$1"
  local repository="$2"
  local repo_digest
  repo_digest="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image" 2>/dev/null | awk -v prefix="$repository@sha256:" 'index($0, prefix) == 1 { print $0; exit }')"
  [[ -n "$repo_digest" ]] || die "no registry digest for $image; push the image before creating a release manifest"
  printf '%s\n' "${repo_digest#*@}"
}

local_image_app_version() {
  local image="$1"
  local app_version
  app_version="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$image" 2>/dev/null)"
  [[ -n "$app_version" && "$app_version" != "dev" && "$app_version" != "unknown" && "$app_version" != '<no value>' ]] || die "image $image has no immutable app version label"
  printf '%s\n' "$app_version"
}

local_image_revision() {
  local image="$1"
  local revision
  revision="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image" 2>/dev/null)"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "image $image has no valid Git revision label"
  printf '%s\n' "$revision"
}

create_manifest() {
  local output="$1"
  command -v docker >/dev/null 2>&1 || die "docker is required to create a release manifest"
  command -v git >/dev/null 2>&1 || die "git is required to create a release manifest"
  [[ -z "$(git status --porcelain --untracked-files=all)" ]] || die "working tree is not clean; release images must come from one committed Git revision"
  git diff --quiet || die "working tree has unstaged changes; release images must come from one committed Git revision"
  git diff --cached --quiet || die "working tree has staged changes; release images must come from one committed Git revision"

  local repository="${IMAGE_REPOSITORY:-pczhao1210/ghcp-pool-proxy}"
  local schema_file="${SCHEMA_VERSION_FILE:-migrations/schema_version}"
  local schema git_sha app_version role tag image digest role_app_version role_revision
  [[ -r "$schema_file" ]] || die "schema version file is not readable: $schema_file"
  schema="$(tr -d '[:space:]' < "$schema_file")"
  [[ "$schema" =~ ^[1-9][0-9]*$ ]] || die "schema version is invalid"
  git_sha="$(git rev-parse HEAD)"
  app_version="$(local_image_app_version "$repository:gateway-latest")"
  role_revision="$(local_image_revision "$repository:gateway-latest")"
  [[ "$role_revision" == "$git_sha" ]] || die "gateway image revision $role_revision does not match release Git SHA $git_sha"
  for role in admin worker migration; do
    role_app_version="$(local_image_app_version "$repository:$(required_role_tag "$role")")"
    [[ "$role_app_version" == "$app_version" ]] || die "release image app versions differ: gateway=$app_version $role=$role_app_version"
    role_revision="$(local_image_revision "$repository:$(required_role_tag "$role")")"
    [[ "$role_revision" == "$git_sha" ]] || die "$role image revision $role_revision does not match release Git SHA $git_sha"
  done

  umask 022
  {
    printf 'RELEASE_MANIFEST_VERSION=1\n'
    printf 'RELEASE_GIT_SHA=%s\n' "$git_sha"
    printf 'RELEASE_APP_VERSION=%s\n' "$app_version"
    printf 'RELEASE_SCHEMA_VERSION=%s\n' "$schema"
    printf 'RELEASE_IMAGE_REPOSITORY=%s\n' "$repository"
    for role in gateway admin worker migration; do
      tag="$(required_role_tag "$role")"
      image="$repository:$tag"
      digest="$(local_image_digest "$image" "$repository")"
      printf 'RELEASE_%s_TAG=%s\n' "${role^^}" "$tag"
      printf 'RELEASE_%s_DIGEST=%s\n' "${role^^}" "$digest"
    done
  } > "$output"
  validate_manifest "$output" "$schema"
}

case "${1:-}" in
  create)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    create_manifest "$2"
    ;;
  validate)
    [[ $# -ge 2 && $# -le 4 ]] || { usage >&2; exit 2; }
    validate_manifest "$2" "${3:-}" "${4:-}"
    ;;
  validate-source)
    [[ $# -eq 4 ]] || { usage >&2; exit 2; }
    validate_source "$2" "$3" "$4"
    ;;
  value)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    validate_manifest "$2"
    manifest_value "$2" "$3"
    ;;
  image-tag)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    validate_manifest "$2"
    role="$3"
    repository="$(manifest_value "$2" RELEASE_IMAGE_REPOSITORY)"
    tag="$(manifest_value "$2" "RELEASE_${role^^}_TAG")"
    printf '%s:%s\n' "$repository" "$tag"
    ;;
  image-ref)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    validate_manifest "$2"
    role="$3"
    repository="$(manifest_value "$2" RELEASE_IMAGE_REPOSITORY)"
    digest="$(manifest_value "$2" "RELEASE_${role^^}_DIGEST")"
    printf '%s@%s\n' "$repository" "$digest"
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac