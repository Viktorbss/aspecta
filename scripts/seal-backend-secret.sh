#!/usr/bin/env bash
# Seal the backend's API_KEY for the kind cluster and write it to gitops/secrets/aspecta/.
#
# The SealedSecret is encrypted with the public key of the Sealed Secrets controller in the cluster,
# so only that controller can decrypt it and the file is safe to commit. A new cluster generates a new
# key pair: re-run this script and commit the result.
#
# Usage: API_KEY=<value> scripts/seal-backend-secret.sh   (without API_KEY a random key is generated)
set -euo pipefail

CONTEXT=kind-aspecta
NAMESPACE=aspecta
SECRET_NAME=backend-secret

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/gitops/secrets/aspecta/$SECRET_NAME.yaml"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for tool in kubectl kubeseal openssl; do
  command -v "$tool" >/dev/null || die "$tool not found; run scripts/setup-workstation.sh"
done

API_KEY="${API_KEY:-$(openssl rand -hex 32)}"

mkdir -p "$(dirname "$OUT")"
log "Sealing $NAMESPACE/$SECRET_NAME with the controller key of $CONTEXT"
# The plain Secret exists only in this pipe and is never written to disk. The value goes in through a
# file descriptor, not a command-line argument, so it does not show up in the process list.
kubectl create secret generic "$SECRET_NAME" --namespace "$NAMESPACE" \
  --from-env-file=<(printf 'API_KEY=%s\n' "$API_KEY") --dry-run=client -o yaml |
  kubeseal --context "$CONTEXT" --format yaml >"$OUT"

# ask the controller to decrypt it, without creating anything
kubeseal --context "$CONTEXT" --validate <"$OUT"
log "Wrote ${OUT#"$ROOT"/}. Commit it; Argo CD creates the Secret from it."
