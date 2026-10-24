#!/usr/bin/env bash
# Create the local kind cluster "aspecta" with Calico as CNI, install Argo CD and hand over to GitOps.
# Calico and Argo CD are the only components installed outside Git: everything else is synced by
# Argo CD from gitops/ in the GitHub repository.
#
# Idempotent: an existing cluster is reused, Calico and Argo CD are upgraded in place.
# Every kubectl/helm call is pinned to the kind context, so other clusters in ~/.kube/config are never touched.
#
# Usage: scripts/bootstrap.sh
set -euo pipefail

CLUSTER_NAME=aspecta
CONTEXT="kind-$CLUSTER_NAME"
CALICO_VERSION=v3.33.0
ARGOCD_CHART_VERSION=10.10.5 # Argo CD v3.5.5

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for tool in docker kind kubectl helm yq; do
  command -v "$tool" >/dev/null || die "$tool not found; run scripts/setup-workstation.sh"
done
docker info >/dev/null 2>&1 || die "cannot reach Docker; is it running and is $USER in the 'docker' group?"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "kind cluster '$CLUSTER_NAME' already exists"
else
  log "Creating kind cluster '$CLUSTER_NAME'"
  kind create cluster --config "$ROOT/cluster/kind-config.yaml"
fi

# Calico is installed once and then left alone. After the install the tigera operator owns fields of
# the Installation resource (e.g. defaults in ipPools); a repeated `helm upgrade` would conflict with
# it under server-side apply. Upgrading Calico is a deliberate step that follows Calico's upgrade guide.
calico_chart="$(helm --kube-context "$CONTEXT" -n tigera-operator history calico --max 1 -o yaml 2>/dev/null |
  yq '.[0].chart // ""' || true)"
calico_status="$(kubectl --context "$CONTEXT" get tigerastatus calico \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
if [[ "$calico_chart" == "tigera-operator-$CALICO_VERSION" && "$calico_status" == True ]]; then
  log "Calico $CALICO_VERSION already installed and available"
else
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
fi

# nodes report Ready only once the CNI is up, so this is the real "Calico works" check
log "Waiting for all nodes to become Ready"
kubectl --context "$CONTEXT" wait --for=condition=Ready nodes --all --timeout=300s

kubectl --context "$CONTEXT" get nodes -o wide

log "Installing Argo CD (chart $ARGOCD_CHART_VERSION)"
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  --values "$ROOT/cluster/argocd-values.yaml" \
  --kube-context "$CONTEXT" --wait

# from here on Argo CD syncs gitops/apps/ from GitHub ("app of apps")
log "Applying the root Application"
kubectl --context "$CONTEXT" apply -f "$ROOT/gitops/root-app.yaml"

log "Cluster ready. kubectl context: $CONTEXT"
cat <<EOF

Argo CD UI:
  kubectl -n argocd port-forward svc/argocd-server 8443:443
  open https://localhost:8443 (user admin, self-signed certificate)
  password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
EOF
