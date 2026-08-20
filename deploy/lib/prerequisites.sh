#!/usr/bin/env bash

PREREQ_OS_RELEASE_FILE="${PREREQ_OS_RELEASE_FILE:-/etc/os-release}"
PREREQ_INSTALL_BIN_DIR="${PREREQ_INSTALL_BIN_DIR:-${HOME:-/tmp}/.local/bin}"
PREREQ_AUTO_INSTALL="${PREREQ_AUTO_INSTALL:-0}"
PREREQ_DRY_RUN="${PREREQ_DRY_RUN:-0}"
PREREQ_APT_UPDATED=0
PREREQ_OS_ID=""
PREREQ_OS_NAME=""
PREREQ_PACKAGE_MANAGER=""

prereq_log() {
  printf '==> %s\n' "$*" >&2
}

prereq_die() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

prereq_read_os() {
  [[ -r "$PREREQ_OS_RELEASE_FILE" ]] || return 0
  PREREQ_OS_ID="$(
    set +u
    # shellcheck disable=SC1090
    source "$PREREQ_OS_RELEASE_FILE"
    printf '%s' "${ID:-linux}"
  )"
  PREREQ_OS_NAME="$(
    set +u
    # shellcheck disable=SC1090
    source "$PREREQ_OS_RELEASE_FILE"
    printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}"
  )"
}

prereq_detect_package_manager() {
  [[ -n "$PREREQ_OS_ID" ]] || prereq_read_os
  if [[ -n "${PREREQ_PACKAGE_MANAGER_OVERRIDE:-}" ]]; then
    PREREQ_PACKAGE_MANAGER="$PREREQ_PACKAGE_MANAGER_OVERRIDE"
    return 0
  fi
  local candidate
  for candidate in apt-get dnf yum zypper pacman apk; do
    if command -v "$candidate" >/dev/null 2>&1; then
      PREREQ_PACKAGE_MANAGER="$candidate"
      return 0
    fi
  done
  prereq_die "未找到受支持的包管理器（apt/dnf/yum/zypper/pacman/apk），系统：${PREREQ_OS_NAME:-unknown}"
}

prereq_run() {
  if [[ "$PREREQ_DRY_RUN" == "1" ]]; then
    printf 'RUN' >> "${PREREQ_DRY_RUN_LOG:?PREREQ_DRY_RUN_LOG is required}"
    printf ' %q' "$@" >> "$PREREQ_DRY_RUN_LOG"
    printf '\n' >> "$PREREQ_DRY_RUN_LOG"
    return 0
  fi
  "$@"
}

prereq_run_privileged() {
  if [[ "$PREREQ_DRY_RUN" == "1" ]]; then
    printf 'SUDO' >> "${PREREQ_DRY_RUN_LOG:?PREREQ_DRY_RUN_LOG is required}"
    printf ' %q' "$@" >> "$PREREQ_DRY_RUN_LOG"
    printf '\n' >> "$PREREQ_DRY_RUN_LOG"
    return 0
  fi
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
    return
  fi
  command -v sudo >/dev/null 2>&1 || prereq_die "安装系统组件需要 root 权限，但未找到 sudo"
  sudo "$@"
}

prereq_confirm_install() {
  local label="$1"
  [[ "$PREREQ_AUTO_INSTALL" == "1" ]] && return 0
  [[ -t 0 ]] || prereq_die "缺少 $label；请先安装，或使用 --install-missing 明确允许自动安装"
  local answer
  printf '缺少 %s。现在安装吗？[y/N]: ' "$label" >&2
  IFS= read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || prereq_die "未安装必需组件：$label"
}

prereq_install_packages() {
  prereq_detect_package_manager
  case "$PREREQ_PACKAGE_MANAGER" in
    apt-get)
      if [[ "$PREREQ_APT_UPDATED" -eq 0 ]]; then
        prereq_run_privileged apt-get update
        PREREQ_APT_UPDATED=1
      fi
      prereq_run_privileged apt-get install -y --no-install-recommends "$@"
      ;;
    dnf)
      prereq_run_privileged dnf install -y "$@"
      ;;
    yum)
      prereq_run_privileged yum install -y "$@"
      ;;
    zypper)
      prereq_run_privileged zypper --non-interactive install "$@"
      ;;
    pacman)
      prereq_run_privileged pacman -Sy --needed --noconfirm "$@"
      ;;
    apk)
      prereq_run_privileged apk add --no-cache "$@"
      ;;
  esac
}

prereq_package_name() {
  local tool="$1"
  prereq_detect_package_manager
  case "$tool:$PREREQ_PACKAGE_MANAGER" in
    docker:apt-get) printf 'docker.io\n' ;;
    docker:*) printf 'docker\n' ;;
    coreutils:*) printf 'coreutils\n' ;;
    *) printf '%s\n' "$tool" ;;
  esac
}

prereq_ensure_download_support() {
  local packages=()
  command -v curl >/dev/null 2>&1 || packages+=("$(prereq_package_name curl)")
  command -v sha256sum >/dev/null 2>&1 || packages+=("$(prereq_package_name coreutils)")
  command -v tar >/dev/null 2>&1 || packages+=("$(prereq_package_name tar)")
  ((${#packages[@]} == 0)) || prereq_install_packages ca-certificates "${packages[@]}"
}

prereq_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) prereq_die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

prereq_prepare_bin_dir() {
  prereq_run mkdir -p "$PREREQ_INSTALL_BIN_DIR"
  case ":$PATH:" in
    *":$PREREQ_INSTALL_BIN_DIR:"*) ;;
    *) export PATH="$PREREQ_INSTALL_BIN_DIR:$PATH" ;;
  esac
}

prereq_install_kubectl() {
  prereq_ensure_download_support
  prereq_prepare_bin_dir
  local version="${KUBECTL_VERSION:-v1.33.4}"
  local arch temp_dir
  arch="$(prereq_arch)"
  temp_dir="$(mktemp -d)"
  prereq_run curl --fail --location --proto '=https' --tlsv1.2 \
    "https://dl.k8s.io/release/$version/bin/linux/$arch/kubectl" -o "$temp_dir/kubectl"
  prereq_run curl --fail --location --proto '=https' --tlsv1.2 \
    "https://dl.k8s.io/release/$version/bin/linux/$arch/kubectl.sha256" -o "$temp_dir/kubectl.sha256"
  if [[ "$PREREQ_DRY_RUN" != "1" ]]; then
    printf '%s  %s\n' "$(cat "$temp_dir/kubectl.sha256")" "$temp_dir/kubectl" | sha256sum --check --status
  fi
  prereq_run install -m 0755 "$temp_dir/kubectl" "$PREREQ_INSTALL_BIN_DIR/kubectl"
  prereq_run rm -rf "$temp_dir"
}

prereq_install_kind() {
  prereq_ensure_download_support
  prereq_prepare_bin_dir
  local version="${KIND_VERSION:-v0.30.0}"
  local arch temp_dir asset
  arch="$(prereq_arch)"
  asset="kind-linux-$arch"
  temp_dir="$(mktemp -d)"
  prereq_run curl --fail --location --proto '=https' --tlsv1.2 \
    "https://github.com/kubernetes-sigs/kind/releases/download/$version/$asset" -o "$temp_dir/kind"
  prereq_run curl --fail --location --proto '=https' --tlsv1.2 \
    "https://github.com/kubernetes-sigs/kind/releases/download/$version/$asset.sha256sum" -o "$temp_dir/kind.sha256sum"
  if [[ "$PREREQ_DRY_RUN" != "1" ]]; then
    (cd "$temp_dir" && sed "s/$asset/kind/" kind.sha256sum | sha256sum --check --status)
  fi
  prereq_run install -m 0755 "$temp_dir/kind" "$PREREQ_INSTALL_BIN_DIR/kind"
  prereq_run rm -rf "$temp_dir"
}

prereq_install_kustomize() {
  prereq_ensure_download_support
  prereq_prepare_bin_dir
  local version="${KUSTOMIZE_VERSION:-v5.7.1}"
  local arch temp_dir asset checksum
  arch="$(prereq_arch)"
  asset="kustomize_${version}_linux_${arch}.tar.gz"
  temp_dir="$(mktemp -d)"
  prereq_run curl --fail --location --proto '=https' --tlsv1.2 \
    "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F$version/$asset" -o "$temp_dir/$asset"
  prereq_run curl --fail --location --proto '=https' --tlsv1.2 \
    "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F$version/checksums.txt" -o "$temp_dir/checksums.txt"
  if [[ "$PREREQ_DRY_RUN" != "1" ]]; then
    checksum="$(awk -v asset="$asset" '$2 == asset { print $1; exit }' "$temp_dir/checksums.txt")"
    [[ -n "$checksum" ]] || prereq_die "Kustomize 发布校验和中缺少 $asset"
    printf '%s  %s\n' "$checksum" "$temp_dir/$asset" | sha256sum --check --status
    tar -xzf "$temp_dir/$asset" -C "$temp_dir" kustomize
  fi
  prereq_run install -m 0755 "$temp_dir/kustomize" "$PREREQ_INSTALL_BIN_DIR/kustomize"
  prereq_run rm -rf "$temp_dir"
}

prereq_install_azure_cli() {
  prereq_detect_package_manager
  local temp_dir codename arch
  temp_dir="$(mktemp -d)"
  case "$PREREQ_PACKAGE_MANAGER" in
    apt-get)
      prereq_install_packages ca-certificates curl gnupg
      codename="$(
        set +u
        # shellcheck disable=SC1090
        source "$PREREQ_OS_RELEASE_FILE"
        printf '%s' "${AZ_REPO:-${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}}"
      )"
      [[ -n "$codename" ]] || prereq_die "无法从 $PREREQ_OS_RELEASE_FILE 确定 Azure CLI 仓库版本"
      arch="$(dpkg --print-architecture)"
      prereq_run curl --fail --location --proto '=https' --tlsv1.2 \
        https://packages.microsoft.com/keys/microsoft.asc -o "$temp_dir/microsoft.asc"
      if [[ "$PREREQ_DRY_RUN" != "1" ]]; then
        gpg --dearmor --yes --output "$temp_dir/microsoft.gpg" "$temp_dir/microsoft.asc"
        printf '%s\n' \
          "Types: deb" \
          "URIs: https://packages.microsoft.com/repos/azure-cli/" \
          "Suites: $codename" \
          "Components: main" \
          "Architectures: $arch" \
          "Signed-by: /etc/apt/keyrings/microsoft.gpg" > "$temp_dir/azure-cli.sources"
      fi
      prereq_run_privileged install -d -m 0755 /etc/apt/keyrings
      prereq_run_privileged install -m 0644 "$temp_dir/microsoft.gpg" /etc/apt/keyrings/microsoft.gpg
      prereq_run_privileged install -m 0644 "$temp_dir/azure-cli.sources" /etc/apt/sources.list.d/azure-cli.sources
      PREREQ_APT_UPDATED=0
      prereq_install_packages azure-cli
      ;;
    dnf|yum)
      prereq_install_packages ca-certificates curl
      prereq_run curl --fail --location --proto '=https' --tlsv1.2 \
        https://packages.microsoft.com/keys/microsoft.asc -o "$temp_dir/microsoft.asc"
      if [[ "$PREREQ_DRY_RUN" != "1" ]]; then
        cat > "$temp_dir/azure-cli.repo" <<'EOF'
[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
      fi
      prereq_run_privileged rpm --import "$temp_dir/microsoft.asc"
      prereq_run_privileged install -m 0644 "$temp_dir/azure-cli.repo" /etc/yum.repos.d/azure-cli.repo
      prereq_install_packages azure-cli
      ;;
    zypper)
      prereq_install_packages ca-certificates curl
      prereq_run_privileged rpm --import https://packages.microsoft.com/keys/microsoft.asc
      prereq_run_privileged zypper --non-interactive addrepo --check --refresh \
        https://packages.microsoft.com/yumrepos/azure-cli azure-cli
      prereq_install_packages azure-cli
      ;;
    pacman|apk)
      prereq_run rm -rf "$temp_dir"
      prereq_die "Microsoft 未为 ${PREREQ_OS_NAME:-$PREREQ_OS_ID} 提供受支持的 Azure CLI 系统包；请按 https://aka.ms/InstallAzureCli 安装"
      ;;
  esac
  prereq_run rm -rf "$temp_dir"
}

prereq_install_tool() {
  local command_name="$1"
  case "$command_name" in
    kubectl) prereq_install_kubectl ;;
    kind) prereq_install_kind ;;
    kustomize) prereq_install_kustomize ;;
    az) prereq_install_azure_cli ;;
    docker|jq) prereq_install_packages "$(prereq_package_name "$command_name")" ;;
    *) prereq_die "没有 $command_name 的自动安装器" ;;
  esac
}

prereq_ensure_command() {
  local command_name="$1"
  local label="${2:-$1}"
  command -v "$command_name" >/dev/null 2>&1 && return 0
  prereq_confirm_install "$label"
  prereq_log "在 ${PREREQ_OS_NAME:-Linux} 上安装 $label"
  prereq_install_tool "$command_name"
  [[ "$PREREQ_DRY_RUN" == "1" ]] || command -v "$command_name" >/dev/null 2>&1 || {
    prereq_die "$label 安装完成后仍不在 PATH 中"
  }
}

prereq_ensure_bicep() {
  az bicep version >/dev/null 2>&1 && return 0
  prereq_confirm_install "Azure Bicep CLI"
  prereq_log "通过 Azure CLI 安装 Bicep"
  prereq_run az bicep install
}

prereq_ensure_docker_daemon() {
  docker info >/dev/null 2>&1 && return 0
  [[ -t 0 || "$PREREQ_AUTO_INSTALL" == "1" ]] || {
    prereq_die "Docker daemon 不可用；请启动 Docker 并确认当前用户有访问权限"
  }
  prereq_confirm_install "Docker 服务启动"
  if command -v systemctl >/dev/null 2>&1; then
    prereq_run_privileged systemctl enable --now docker
  elif command -v service >/dev/null 2>&1; then
    prereq_run_privileged service docker start
  else
    prereq_die "无法自动启动 Docker；系统没有 systemctl 或 service"
  fi
  [[ "$PREREQ_DRY_RUN" == "1" ]] || docker info >/dev/null 2>&1 || {
    prereq_die "Docker 仍不可用；请检查 daemon，并将当前用户加入 docker 组后重新登录"
  }
}

prereq_ensure_local_cluster_tools() {
  prereq_ensure_command docker Docker
  prereq_ensure_command kind Kind
  prereq_ensure_command kubectl kubectl
  prereq_ensure_command kustomize Kustomize
  prereq_ensure_docker_daemon
}

prereq_ensure_kubernetes_client_tools() {
  prereq_ensure_command kubectl kubectl
  prereq_ensure_command kustomize Kustomize
}

prereq_ensure_azure_tools() {
  prereq_ensure_command az "Azure CLI"
  prereq_ensure_command jq jq
  prereq_ensure_kubernetes_client_tools
  [[ "$PREREQ_DRY_RUN" == "1" ]] || prereq_ensure_bicep
}