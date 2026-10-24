#!/usr/bin/env bash
# Create or delete a developer with the read-only Role "aspecta-viewer" in the kind cluster.
#
# The user authenticates with a client certificate signed by the cluster: CN is the user name and
# O is the group "aspecta-developers", which the chart's RoleBinding grants the Role to.
# Files (private key, certificate, kubeconfig) go to ~/.kube/aspecta-users/<name>/, outside the repository.
#
# Limits of client certificates (production uses OIDC/SSO instead):
#   - a certificate cannot be revoked; "delete" removes the CSR and the local files, but a copied
#     kubeconfig keeps working until the certificate expires, hence the short default validity
#   - here the admin generates the private key; normally the user generates key and CSR and sends only the CSR
#
# Usage: scripts/dev-user.sh create <name> [hours]   (validity, default 24)
#        scripts/dev-user.sh delete <name>
#        scripts/dev-user.sh list
set -euo pipefail

CONTEXT=kind-aspecta
NAMESPACE=aspecta
GROUP=aspecta-developers
USERS_DIR="${USERS_DIR:-$HOME/.kube/aspecta-users}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n 's/^# Usage: //p; s/^#        //p' "$0" | sed -n '1,3p'; exit 1; }

k() { kubectl --context "$CONTEXT" "$@"; }

# the CSR object in the cluster is prefixed, so it does not clash with other CSRs
csr_name() { echo "aspecta-user-$1"; }

check_name() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] ||
    die "invalid name '$1': lowercase letters, digits and '-', max 32 characters"
}

expiry() { openssl x509 -in "$1" -noout -enddate | cut -d= -f2; }

create() {
  local name="$1" hours="${2:-24}" dir="$USERS_DIR/$1" csr
  check_name "$name"
  [[ "$hours" =~ ^[0-9]+$ ]] && ((hours >= 1)) || die "hours must be a positive number"
  csr="$(csr_name "$name")"
  [[ ! -e "$dir" ]] || die "$dir already exists; run: $0 delete $name"
  k get csr "$csr" >/dev/null 2>&1 && die "CSR $csr already exists in the cluster; run: $0 delete $name"

  umask 077 # private key and kubeconfig readable only by the owner
  mkdir -p "$dir"

  log "Generating private key and certificate request for $name (group $GROUP)"
  openssl genrsa -out "$dir/$name.key" 2048 2>/dev/null
  openssl req -new -key "$dir/$name.key" -out "$dir/$name.csr" -subj "/CN=$name/O=$GROUP"

  log "Submitting and approving CertificateSigningRequest $csr (valid ${hours} h)"
  k apply -f - >/dev/null <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $csr
spec:
  request: $(base64 -w0 <"$dir/$name.csr")
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: $((hours * 3600))
  usages: [client auth]
EOF
  k certificate approve "$csr" >/dev/null

  # the signer issues the certificate asynchronously, usually within a second
  local cert=""
  for _ in $(seq 1 20); do
    cert="$(k get csr "$csr" -o jsonpath='{.status.certificate}')"
    [[ -n "$cert" ]] && break
    sleep 0.5
  done
  [[ -n "$cert" ]] || die "certificate for $csr was not issued"
  base64 -d <<<"$cert" >"$dir/$name.crt"

  log "Writing kubeconfig"
  local kubeconfig="$dir/kubeconfig" server
  server="$(k config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')"
  k config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' |
    base64 -d >"$dir/ca.crt"
  kubectl config set-cluster aspecta --server="$server" --certificate-authority="$dir/ca.crt" \
    --embed-certs --kubeconfig="$kubeconfig" >/dev/null
  kubectl config set-credentials "$name" --client-certificate="$dir/$name.crt" \
    --client-key="$dir/$name.key" --embed-certs --kubeconfig="$kubeconfig" >/dev/null
  kubectl config set-context "$name@aspecta" --cluster=aspecta --user="$name" \
    --namespace="$NAMESPACE" --kubeconfig="$kubeconfig" >/dev/null
  kubectl config use-context "$name@aspecta" --kubeconfig="$kubeconfig" >/dev/null

  log "Checking permissions as $name"
  for check in "list pods" "get pods --subresource=log" "get secrets" "create pods --subresource=exec" "delete pods"; do
    # shellcheck disable=SC2086 # $check holds several words on purpose
    printf '  %-36s %s\n' "$check" "$(kubectl --kubeconfig="$kubeconfig" auth can-i $check -n "$NAMESPACE" 2>/dev/null || true)"
  done

  log "Done. Certificate valid until $(expiry "$dir/$name.crt")"
  echo "  export KUBECONFIG=$kubeconfig"
}

delete() {
  local name="$1" dir="$USERS_DIR/$1"
  check_name "$name"
  k delete csr "$(csr_name "$name")" --ignore-not-found
  if [[ -f "$dir/$name.crt" ]]; then
    warn "a certificate cannot be revoked: copies of this kubeconfig work until $(expiry "$dir/$name.crt")"
  fi
  if [[ -d "$dir" ]]; then
    rm -rf -- "$dir"
    log "Removed $dir"
  fi
}

list() {
  [[ -d "$USERS_DIR" ]] || { echo "no users"; return; }
  local crt
  for crt in "$USERS_DIR"/*/*.crt; do
    [[ -f "$crt" ]] || { echo "no users"; return; }
    printf '%-20s valid until %s\n' "$(basename "$crt" .crt)" "$(expiry "$crt")"
  done
}

case "${1:-}" in
  create) [[ $# -ge 2 ]] || usage; create "$2" "${3:-24}" ;;
  delete) [[ $# -eq 2 ]] || usage; delete "$2" ;;
  list) list ;;
  *) usage ;;
esac
