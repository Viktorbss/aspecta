#!/usr/bin/env bash
# Create the local kind cluster "aspecta" with Calico as CNI.
#
# Idempotent: an existing cluster is reused and Calico is upgraded in place.
# Every kubectl/helm call is pinned to the kind context, so other clusters in ~/.kube/config are never touched.
#
# Usage: scripts/bootstrap.sh
set -euo pipefail

CLUSTER_NAME=aspecta
CONTEXT="kind-$CLUSTER_NAME"
CALICO_VERSION=v3.33.0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for tool in docker kind kubectl helm; do
  command -v "$tool" >/dev/null || die "$tool not found; run scripts/setup-workstation.sh"
done
docker info >/dev/null 2>&1 || die "cannot reach Docker; is it running and is $USER in the 'docker' group?"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "kind cluster '$CLUSTER_NAME' already exists"
else
  log "Creating kind cluster '$CLUSTER_NAME'"
  kind create cluster --config "$ROOT/cluster/kind-config.yaml"
fi

# Since Calico v3.32 the CRDs ship in a separate chart. They are applied server-side,
# because some of them exceed the annotation size limit of client-side apply.
log "Installing Calico $CALICO_VERSION CRDs"
helm template calico-crds crd.projectcalico.org.v1 \
  --repo https://docs.tigera.io/calico/charts --version "$CALICO_VERSION" |
  kubectl --context "$CONTEXT" apply --server-side -f - >/dev/null
kubectl --context "$CONTEXT" wait --for=condition=Established crd/installations.operator.tigera.io --timeout=60s

log "Installing Calico $CALICO_VERSION operator"
helm upgrade --install calico tigera-operator \
  --repo https://docs.tigera.io/calico/charts --version "$CALICO_VERSION" \
  --namespace tigera-operator --create-namespace \
  --values "$ROOT/cluster/calico-values.yaml" \
  --kube-context "$CONTEXT" --wait

# nodes report Ready only once the CNI is up, so this is the real "Calico works" check
log "Waiting for all nodes to become Ready"
kubectl --context "$CONTEXT" wait --for=condition=Ready nodes --all --timeout=300s

kubectl --context "$CONTEXT" get nodes -o wide
log "Cluster ready. kubectl context: $CONTEXT"
