#!/usr/bin/env bash
# Phase 0: install local prerequisites for the aspecta environment on Ubuntu (incl. WSL2).
#
# CLI tools (kind, helm, kubeseal, yq, kubeconform, kubectl) go to $INSTALL_DIR without sudo.
# Docker CE is installed from download.docker.com and needs sudo.
# Idempotent: re-running skips everything already installed in the pinned version.
#
# Usage: scripts/setup-workstation.sh [--tools-only]
#   --tools-only   skip Docker (e.g. when Docker Desktop is used)
set -euo pipefail

KIND_VERSION=v0.33.0
HELM_VERSION=v4.3.1
KUBESEAL_VERSION=0.40.0
YQ_VERSION=v4.54.1
KUBECONFORM_VERSION=v0.8.0
KUBECTL_VERSION=v1.37.1

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

# verify <file> <checksum-file>: the file's sha256 must appear on its line in the release checksum file
verify() {
  local sum
  sum="$(sha256sum "$1" | cut -d' ' -f1)"
  grep -F "$(basename "$1")" "$2" | grep -qF "$sum" || die "checksum mismatch for $(basename "$1")"
}

# have <tool> <version-args> <version>: tool is already installed in $INSTALL_DIR in that version
have() {
  [[ -x "$INSTALL_DIR/$1" ]] && "$INSTALL_DIR/$1" $2 2>/dev/null | grep -qF "$3" &&
    log "$1 $3 already installed"
}

install_kind() {
  have kind version "$KIND_VERSION" && return
  local base="https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION" f="kind-linux-$ARCH"
  fetch "$base/$f" "$TMP/$f"
  fetch "$base/$f.sha256sum" "$TMP/$f.sha256sum"
  verify "$TMP/$f" "$TMP/$f.sha256sum"
  install -m 0755 "$TMP/$f" "$INSTALL_DIR/kind"
  log "kind $KIND_VERSION installed"
}

install_helm() {
  have helm "version --short" "$HELM_VERSION" && return
  local f="helm-$HELM_VERSION-linux-$ARCH.tar.gz"
  fetch "https://get.helm.sh/$f" "$TMP/$f"
  fetch "https://get.helm.sh/$f.sha256sum" "$TMP/$f.sha256sum"
  verify "$TMP/$f" "$TMP/$f.sha256sum"
  tar -xzf "$TMP/$f" -C "$TMP" "linux-$ARCH/helm"
  install -m 0755 "$TMP/linux-$ARCH/helm" "$INSTALL_DIR/helm"
  log "helm $HELM_VERSION installed"
}

install_kubeseal() {
  have kubeseal --version "$KUBESEAL_VERSION" && return
  local base="https://github.com/bitnami-labs/sealed-secrets/releases/download/v$KUBESEAL_VERSION"
  local f="kubeseal-$KUBESEAL_VERSION-linux-$ARCH.tar.gz" sums="sealed-secrets_${KUBESEAL_VERSION}_checksums.txt"
  fetch "$base/$f" "$TMP/$f"
  fetch "$base/$sums" "$TMP/$sums"
  verify "$TMP/$f" "$TMP/$sums"
  tar -xzf "$TMP/$f" -C "$TMP" kubeseal
  install -m 0755 "$TMP/kubeseal" "$INSTALL_DIR/kubeseal"
  log "kubeseal $KUBESEAL_VERSION installed"
}

install_yq() {
  have yq --version "$YQ_VERSION" && return
  local base="https://github.com/mikefarah/yq/releases/download/$YQ_VERSION" f="yq_linux_$ARCH"
  fetch "$base/$f" "$TMP/$f"
  fetch "$base/checksums" "$TMP/yq-checksums"
  verify "$TMP/$f" "$TMP/yq-checksums"
  install -m 0755 "$TMP/$f" "$INSTALL_DIR/yq"
  log "yq $YQ_VERSION installed"
}

install_kubeconform() {
  have kubeconform -v "$KUBECONFORM_VERSION" && return
  local base="https://github.com/yannh/kubeconform/releases/download/$KUBECONFORM_VERSION"
  local f="kubeconform-linux-$ARCH.tar.gz"
  fetch "$base/$f" "$TMP/$f"
  fetch "$base/CHECKSUMS" "$TMP/kubeconform-CHECKSUMS"
  verify "$TMP/$f" "$TMP/kubeconform-CHECKSUMS"
  tar -xzf "$TMP/$f" -C "$TMP" kubeconform
  install -m 0755 "$TMP/kubeconform" "$INSTALL_DIR/kubeconform"
  log "kubeconform $KUBECONFORM_VERSION installed"
}

# kubectl must stay within one minor version of the cluster, so the pinned one is installed
# even when an older kubectl exists elsewhere (that one is left untouched)
install_kubectl() {
  have kubectl "version --client" "$KUBECTL_VERSION" && return
  local base="https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH"
  fetch "$base/kubectl" "$TMP/kubectl"
  printf '%s  kubectl\n' "$(curl -fsSL "$base/kubectl.sha256")" >"$TMP/kubectl.sha256"
  verify "$TMP/kubectl" "$TMP/kubectl.sha256"
  install -m 0755 "$TMP/kubectl" "$INSTALL_DIR/kubectl"
  log "kubectl $KUBECTL_VERSION installed"
}

install_docker() {
  grep -qs '^ID=ubuntu' /etc/os-release || die "Docker install supports Ubuntu only; use --tools-only"

  # Docker as a service needs systemd; WSL2 has it only when enabled in /etc/wsl.conf
  if [[ "$(ps -p 1 -o comm=)" != systemd ]]; then
    grep -qi microsoft /proc/version || die "systemd is not PID 1; start Docker manually or use --tools-only"
    grep -qs '^\[boot\]' /etc/wsl.conf &&
      die "/etc/wsl.conf already has a [boot] section; add 'systemd=true' there, run 'wsl --shutdown' and re-run"
    log "Enabling systemd in WSL (/etc/wsl.conf)"
    printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
    log "Run 'wsl --shutdown' in Windows PowerShell, reopen the WSL terminal and re-run this script."
    exit 0
  fi

  if dpkg -s docker-ce >/dev/null 2>&1; then
    log "docker-ce already installed"
  else
    log "Installing Docker CE (replaces Ubuntu's docker.io)"
    sudo apt-get remove -y docker.io containerd runc 2>/dev/null || true
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
      sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  fi

  # a docker.socket left running by the removed docker.io package keeps the new daemon from starting
  # ("no sockets found via socket activation"); reload units and restart the socket once
  if ! systemctl is-active --quiet docker; then
    sudo systemctl daemon-reload
    sudo systemctl reset-failed docker.socket docker.service 2>/dev/null || true
    sudo systemctl restart docker.socket
  fi
  sudo systemctl enable --now docker

  if ! id -nG "$USER" | grep -qw docker; then
    sudo usermod -aG docker "$USER"
    log "Added $USER to group 'docker' (root-equivalent). Open a new terminal before using docker without sudo."
  fi
}

# kind runs every node as a container with its own systemd and kubelet; the usual default of
# fs.inotify.max_user_instances=128 then ends in "too many open files" errors in pods
configure_inotify() {
  local conf=/etc/sysctl.d/99-kind.conf
  if (($(sysctl -n fs.inotify.max_user_watches) >= 524288 && $(sysctl -n fs.inotify.max_user_instances) >= 512)); then
    log "inotify limits already sufficient for kind"
    return
  fi
  log "Raising inotify limits for kind ($conf)"
  printf 'fs.inotify.max_user_watches = 524288\nfs.inotify.max_user_instances = 512\n' | sudo tee "$conf" >/dev/null
  sudo sysctl --quiet --load "$conf"
}

mkdir -p "$INSTALL_DIR"
install_kind
install_helm
install_kubeseal
install_yq
install_kubeconform
install_kubectl

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) log "Add $INSTALL_DIR to PATH, e.g.: echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.zshrc" ;;
esac
for t in kind helm kubeseal yq kubeconform kubectl; do
  [[ "$(command -v "$t")" == "$INSTALL_DIR/$t" ]] || log "WARNING: '$t' resolves to $(command -v "$t"), not $INSTALL_DIR/$t"
done

if [[ "${1:-}" != --tools-only ]]; then
  install_docker
  configure_inotify
fi

log "Done. Verify: docker run --rm hello-world && docker buildx version"
