# aspecta

Cloud native environment for a simple web application (Python backend + nginx frontend) on Kubernetes:
local [kind](https://kind.sigs.k8s.io/) cluster, Helm chart, GitOps with Argo CD, CI/CD in GitHub Actions,
monitoring with Prometheus and Alertmanager.

## Workstation setup

`scripts/setup-workstation.sh` installs everything needed on the local machine.

**Supported:** Ubuntu 22.04+ (including WSL2), `x86_64` or `arm64`, a user with `sudo`.

| Tool | Version | Purpose |
|---|---|---|
| Docker CE + buildx | latest from `download.docker.com` | runs the kind nodes, builds images |
| kind | v0.33.0 | local Kubernetes cluster in Docker |
| kubectl | v1.37.1 | Kubernetes CLI |
| helm | v4.3.1 | renders and packages the Helm chart |
| kubeseal | 0.40.0 | encrypts Secrets for Sealed Secrets |
| yq | v4.54.1 | edits YAML (CI uses it to bump image tags) |
| kubeconform | v0.8.0 | validates rendered manifests against the Kubernetes schema |

The script also raises the inotify limits (`/etc/sysctl.d/99-kind.conf`), because a multi-node kind
cluster otherwise fails with `too many open files`.

CLI tools are installed to `~/.local/bin` without `sudo`. Every download is verified against the
SHA-256 checksum published with the release. Docker CE replaces Ubuntu's `docker.io` package.
The script is idempotent: re-running it skips tools that are already installed in the pinned version.

### Install

1. Run the script:

   ```bash
   scripts/setup-workstation.sh
   ```

2. **WSL2 only, first run:** the Docker service needs systemd. The script enables it in `/etc/wsl.conf`
   and stops. Restart WSL from Windows PowerShell, open the WSL terminal again and re-run the script:

   ```powershell
   wsl --shutdown
   ```

3. Open a new terminal, so that the new `docker` group membership applies.

### Verify

```bash
docker run --rm hello-world
docker buildx version
kind version && kubectl version --client && helm version --short
kubeseal --version && yq --version && kubeconform -v
```

### Notes

- Members of the `docker` group are effectively root on the machine. This is acceptable on a personal
  workstation, not on a shared host.
- `~/.local/bin` must come before `/usr/local/bin` in `PATH`. The script warns when an older binary
  elsewhere would take precedence.
- `--tools-only` skips the Docker part, e.g. when Docker Desktop is used.
- `INSTALL_DIR=/some/dir scripts/setup-workstation.sh` installs the CLI tools to a different directory.

## Local cluster

`scripts/bootstrap.sh` creates the kind cluster `aspecta` and installs Calico.

| | |
|---|---|
| Nodes | 1 control plane + 2 workers, Kubernetes v1.37.0 (`kindest/node` pinned by digest) |
| CNI | Calico v3.33.0 (tigera-operator Helm chart), pod CIDR `10.244.0.0/16` |
| Host ports | `127.0.0.1:80` → NodePort 30080, `127.0.0.1:443` → NodePort 30443 (used by Traefik) |
| kubectl context | `kind-aspecta` |

Why these choices:

- **Calico instead of kindnet.** NetworkPolicy objects are only enforced by a CNI that implements them.
  Calico enforces them and is common in production clusters.
- **Two workers.** Replicas spread across nodes, so the PodDisruptionBudgets and HPA scaling are realistic.
- **NodePort instead of hostPort for ingress.** Pod Security `baseline` forbids hostPorts, so the ingress
  controller can run without privileged exceptions.
- **Ports bound to `127.0.0.1`.** The cluster is reachable from this machine only, not from the LAN.

Calico is installed by the script, not by GitOps: Argo CD itself needs a working pod network to run.
Since Calico v3.32 its CRDs ship in a separate chart (`crd.projectcalico.org.v1`). The script renders it
and applies it with `kubectl apply --server-side` before installing the operator, because some CRDs are
too large for client-side apply.

```bash
scripts/bootstrap.sh
```

The script is idempotent. Every `kubectl` and `helm` call uses `--context kind-aspecta`, so other clusters
in `~/.kube/config` are never touched. `kind create cluster` switches the current context to `kind-aspecta`.

Verify:

```bash
kubectl get nodes                       # 3 nodes Ready
kubectl get tigerastatus                # calico Available
```

Delete the cluster:

```bash
kind delete cluster --name aspecta
```

## GitOps (Argo CD)

`scripts/bootstrap.sh` installs Argo CD and applies one Application by hand: `gitops/root-app.yaml`.
From then on the cluster follows the `main` branch of this repository.

```
gitops/
├── root-app.yaml         Application "root", syncs gitops/apps/ ("app of apps")
├── apps/
│   ├── projects.yaml     AppProjects "platform" and "aspecta"       wave -3
│   ├── namespaces.yaml   Application → gitops/namespaces/            wave -2
│   ├── traefik.yaml      Application → Traefik Helm chart            wave -1
│   ├── metrics-server.yaml  Application → metrics-server Helm chart  wave -1
│   ├── sealed-secrets.yaml  Application → sealed-secrets Helm chart  wave -1
│   └── aspecta.yaml      Application → charts/aspecta                wave 0
└── namespaces/           Namespaces with Pod Security labels
```

| Application | Project | Namespace | Source |
|---|---|---|---|
| `namespaces` | platform | – | `gitops/namespaces` |
| `traefik` | platform | `traefik` | Traefik chart 42.1.3 (Traefik v3.7.16) |
| `metrics-server` | platform | `kube-system` | metrics-server chart 3.14.0 |
| `sealed-secrets` | platform | `kube-system` | sealed-secrets chart 2.20.0 (controller v0.40.0) |
| `aspecta` | aspecta | `aspecta` | `charts/aspecta` |

Design notes:

- **App of apps.** Adding a manifest to `gitops/apps/` deploys a new component; deleting it removes the
  component (`prune` and the `resources-finalizer`).
- **Self-healing.** Every Application syncs automatically with `prune` and `selfHeal`. A manual change in
  the cluster, such as scaling a Deployment, is reverted to the state in Git.
- **Sync waves** order the first sync: projects, then namespaces, then add-ons, then the application.
  `retry` covers the rest, e.g. a CRD that is not established yet.
- **AppProjects as guardrails.** `platform` may install cluster-scoped resources (CRDs, ClusterRoles,
  IngressClass). `aspecta` may only deploy from this repository into the `aspecta` namespace and cannot
  create any cluster-scoped resource.
- **Namespaces live in Git** with their Pod Security labels: `aspecta` enforces `restricted`, `traefik`
  enforces `baseline` and warns on `restricted`.
- **Ingress.** Traefik's Service is a NodePort (30080/30443), which kind maps to `127.0.0.1:80/443`.
  The application is at http://aspecta.localhost.
- **Bootstrap outside Git.** Calico (Argo CD needs a pod network) and Argo CD itself are installed by the
  script. In production Argo CD would also manage itself.
- **Images.** Until CI publishes images to GHCR, the `aspecta` Application adds `values-local.yaml`, so
  the locally built images must be loaded with `kind load` (see "Install manually" below).

Access the Argo CD UI:

```bash
kubectl -n argocd port-forward svc/argocd-server 8443:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

Open https://localhost:8443 and log in as `admin`.

Verify:

```bash
kubectl -n argocd get applications      # all Synced and Healthy
curl -s http://aspecta.localhost/api/info
kubectl top pods -n aspecta             # metrics-server works
kubectl get hpa -n aspecta              # CPU targets instead of <unknown>
```

## Secrets (Sealed Secrets)

A Kubernetes Secret is only base64-encoded, so it cannot live in a public Git repository.
[Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) solves this:

- The **controller** (Application `sealed-secrets`, namespace `kube-system`) generates a key pair on its
  first start. The private key never leaves the cluster.
- **`kubeseal`** encrypts a Secret with the controller's public key into a `SealedSecret`, which is safe
  to commit.
- Argo CD applies the `SealedSecret`; the controller decrypts it into a regular Secret.

The backend's `API_KEY` is sealed by `scripts/seal-backend-secret.sh` into
`gitops/secrets/aspecta/backend-secret.yaml`:

```bash
API_KEY=<value> scripts/seal-backend-secret.sh   # without API_KEY a random 64-character key is generated
```

The plain Secret only exists in a pipe between `kubectl create secret --dry-run=client` and `kubeseal`;
it is never written to disk and the value is not passed as a command-line argument. The script then asks
the controller to validate that it can decrypt the result.

The default `strict` scope binds the SealedSecret to its name and namespace: the same file copied to
another namespace cannot be decrypted.

**A new cluster has a new key.** After `kind delete cluster` and `scripts/bootstrap.sh`, re-run the
script and commit the new file. In production the sealing key would be backed up, or secrets would come
from an external store (External Secrets Operator with Vault or a cloud secret manager).

**Pods read the Secret at start.** The backend gets `API_KEY` through `envFrom`. When the Secret
appears or changes after the pods started, restart them once:

```bash
kubectl -n aspecta rollout restart deployment/backend
```

On a fresh cluster this is not needed: the secret is synced in an earlier wave than the application.

Verify:

```bash
kubectl -n aspecta get sealedsecret,secret backend-secret
curl -s http://aspecta.localhost/api/info      # "secret_configured": true
```

## Helm chart

`charts/aspecta` deploys both components into one namespace.

| Resource | frontend | backend |
|---|---|---|
| Deployment | `frontend` | `backend` |
| Service (ClusterIP) | `frontend:8080` | `backend:8000` |
| HorizontalPodAutoscaler | 2–4 replicas, 70 % CPU | 2–5 replicas, 50 % CPU |
| PodDisruptionBudget | `minAvailable: 1` | `minAvailable: 1` |
| ServiceAccount | no API permissions, no token mounted | same |
| ConfigMap | – | `backend-config` (from `backend.config`) |
| Secret | – | `backend-secret`, optional (created from a SealedSecret) |
| Ingress | `aspecta.localhost` → `frontend` (class `traefik`) | – |

Design notes:

- **Fixed Service names.** nginx in the frontend proxies to `http://backend:8000`, so the Services are
  named `frontend` and `backend`, not prefixed with the release name. One release per namespace.
- **HPA owns the replica count.** With autoscaling enabled the Deployments omit `spec.replicas`.
  Otherwise every `helm upgrade` or Argo CD sync would reset the count and fight the HPA.
- **HPA behavior** scales up by up to 2 pods every 15 s and scales down by 1 pod every 30 s after
  60 s of low load, so the load demo is easy to follow.
- **Config rollout.** The backend pod template carries a checksum of the ConfigMap. Changing
  `backend.config` changes the checksum and rolls the pods.
- **Optional Secret.** `backend-secret` is referenced with `optional: true`, so the backend also starts
  before the Secret exists. `/api/info` then reports `secret_configured: false`.
- **Pod Security `restricted`.** Every pod runs as non-root with the `RuntimeDefault` seccomp profile,
  a read-only root filesystem, no privilege escalation and all capabilities dropped. `/tmp` is an
  `emptyDir` with a 64 Mi limit.
- **Probes.** Readiness and liveness use `/readyz` and `/healthz`. Probe timeouts are 3 s, because
  under CPU load the probe requests queue behind `/api/work`.
- **Spread.** `topologySpreadConstraints` spread replicas across the nodes.
- **Pod labels.** Pod templates carry only the selector labels, so a chart version bump does not
  restart pods.

### Install manually

Until the CI pipeline publishes images to GHCR, load the locally built images into kind and install the
chart with `values-local.yaml`:

```bash
docker build -t aspecta-backend:dev app/backend
docker build -t aspecta-frontend:dev app/frontend
kind load docker-image aspecta-backend:dev aspecta-frontend:dev --name aspecta

helm lint charts/aspecta -f charts/aspecta/values-local.yaml
helm template aspecta charts/aspecta | kubeconform -strict -summary
helm upgrade --install aspecta charts/aspecta -n aspecta --create-namespace \
  -f charts/aspecta/values-local.yaml --kube-context kind-aspecta --wait

kubectl -n aspecta port-forward svc/frontend 8080:8080
```

Open http://localhost:8080. The Ingress needs Traefik, which Argo CD installs later. The HPAs show
`<unknown>` CPU until metrics-server is installed.

Check that the pods would pass Pod Security `restricted` (no warnings means compliant):

```bash
kubectl label --dry-run=server --overwrite ns aspecta pod-security.kubernetes.io/enforce=restricted
```

## Application

Two containers. The browser talks only to the frontend, which proxies `/api/` to the backend.

| | `app/backend` | `app/frontend` |
|---|---|---|
| Stack | Python 3.14, FastAPI, uvicorn | nginx 1.30 (`nginxinc/nginx-unprivileged`) |
| Port | 8000 | 8080 |
| User | UID 10001 | UID 101 |
| Endpoints | `/api/info`, `/api/work`, `/healthz`, `/readyz`, `/metrics` | `/` (static page), `/healthz`, `/api/` proxied to `http://backend:8000` |

### Backend

- `GET /api/info` returns the message, version and pod hostname. Refreshing the page shows the load
  balancing across replicas. It reports only whether `API_KEY` is set and never returns its value.
- `GET /api/work?ms=100` burns CPU for `ms` milliseconds (1–500) and returns the pod hostname.
  It exists to demonstrate the HorizontalPodAutoscaler. The cap limits what a single request can cost;
  in production a demo endpoint like this would sit behind a feature flag.
- `GET /healthz` (liveness) and `GET /readyz` (readiness) are the Kubernetes probe targets.
- `GET /metrics` exposes Prometheus metrics: `http_requests_total{method,path,status}` and
  `http_request_duration_seconds{method,path}`. The `path` label is the route template, not the raw URL,
  so unknown URLs cannot blow up label cardinality. Probe and scrape requests are not counted.

Configuration comes from environment variables:

| Variable | Source in Kubernetes | Default |
|---|---|---|
| `APP_MESSAGE` | ConfigMap | `Hello from aspecta` |
| `LOG_LEVEL` | ConfigMap | `info` |
| `APP_VERSION` | Helm chart (image tag) | `dev` |
| `API_KEY` | Secret | unset |
| `PORT` | – | `8000` |

### Frontend

A static page that calls `/api/info`. nginx proxies `/api/` to the `backend` Service, so the browser needs
no CORS and the backend is never exposed outside the cluster. `/healthz` is answered by nginx itself, so
frontend probes do not fail when the backend is down.

**Load test:** the *Generate load (60 s)* button runs 6 parallel request loops against `/api/work`
and shows a table of which backend pods answered. The load goes through the Service, so it is spread
across all pods. When the HPA adds replicas, the new pods appear in the table. nginx deliberately uses
no upstream keepalive: every proxied request opens a new connection, so kube-proxy balances per request
instead of pinning a connection to one pod.

### Container images

Both images run as a non-root numeric UID, listen on a port above 1024 and write only to `/tmp`.
They work with `runAsNonRoot`, `readOnlyRootFilesystem` and all capabilities dropped.

The backend Dockerfile has three stages:

- `build` installs runtime dependencies into a virtualenv.
- `test` runs `ruff` and `pytest` on top of `build`.
- `runtime` is the default target and contains only the virtualenv and the app code.

### Test

```bash
docker build --target test app/backend
```

### Run locally

```bash
docker build -t aspecta-backend:dev app/backend
docker build -t aspecta-frontend:dev app/frontend
docker network create aspecta
docker run -d --name backend --network aspecta --read-only --tmpfs /tmp \
  -e APP_MESSAGE="Hello from Docker" -e API_KEY=dummy aspecta-backend:dev
docker run -d --name frontend --network aspecta --read-only --tmpfs /tmp -p 8080:8080 aspecta-frontend:dev
```

Open http://localhost:8080. The backend container must be named `backend` and must start first,
because nginx resolves the upstream at startup.

Clean up:

```bash
docker rm -f frontend backend && docker network rm aspecta
```
