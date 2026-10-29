# DevOps Sample Node.js App

## Overview

A lightweight Node.js application. It has basic web endpoints and Prometheus metrics integration, and is designed for Kubernetes deployment and CI/CD pipeline demonstrations.

## Features

- Express.js web server
- Prometheus metrics integration
- Readiness and liveness probe endpoints
- Customizable port via environment variable

## Prerequisites

- Node.js 24 (Active LTS, the same version as the runtime image)

## Endpoints

| Path | Purpose | Exposed outside the cluster? |
|---|---|---|
| `/my-app` | "Hello, World!" (increments `root_access_total`) | ✅ Ingress |
| `/about` | App description | ✅ Ingress |
| `/ready` | Readiness probe | ❌ kubelet only |
| `/live` | Liveness probe | ❌ kubelet only |
| `/metrics` | Prometheus metrics | ❌ in-cluster scraping only |
| `/classified` | Internal endpoint ("You should not be here!!!") | ❌ **deliberately not routed** |

---

# Helm chart

The chart is in [`helm/sample-nodejs`](helm/sample-nodejs). It deploys the app to the RKE2 cluster from Part 1.

```
helm/sample-nodejs/
├── Chart.yaml                  # chart 0.1.0, appVersion 1.0.0 (default image tag)
├── values.yaml                 # every setting, with comments
└── templates/
    ├── deployment.yaml         # the app (Deployment)
    ├── service.yaml            # ClusterIP Service
    ├── ingress.yaml            # Traefik Ingress, public paths only
    ├── middleware.yaml         # Traefik Middleware: strip X-Powered-By/Server, add security headers
    ├── configmap.yaml          # non-secret config -> env vars
    ├── secret.yaml             # optional secret config -> env vars
    ├── serviceaccount.yaml     # dedicated SA, no API token
    ├── hpa.yaml                # optional HorizontalPodAutoscaler
    ├── pdb.yaml                # PodDisruptionBudget
    ├── networkpolicy.yaml      # optional NetworkPolicy
    ├── NOTES.txt               # post-install hints
    └── tests/test-connection.yaml   # `helm test`
```

## Deployment vs StatefulSet: **Deployment**

The app is **stateless**:
- It keeps no data on disk.
- It has no sessions and no database.
- It has no leader election or per-instance identity.
- The only in-memory state is the Prometheus counters, which are per-process by design. Prometheus aggregates them across pods.

A **StatefulSet** is meant for workloads that need **stable identity**: fixed pod names (`app-0`, `app-1`), a stable network identity through a headless Service, and **their own persistent volume per replica**, with ordered start/stop. Databases, Kafka and ZooKeeper are typical examples. This app needs none of that, and a StatefulSet would only make it slower to roll out (pods replaced one by one, in order).

A **Deployment** treats pods as interchangeable, which fits:
- **rolling updates** with surge (`maxSurge: 1, maxUnavailable: 0`), so there's no downtime
- **fast horizontal scaling** (manually or with the HPA)
- **simple rollbacks** (`helm rollback` / ReplicaSet history)

## Kubernetes features used

### Probes: liveness, readiness, startup

| Probe | Endpoint | Settings | What happens on failure |
|---|---|---|---|
| **startup** | `/live` | every 2s, up to 15 failures (30s) | Liveness and readiness don't run until it succeeds, so a slow start isn't mistaken for a hang |
| **readiness** | `/ready` | every 5s, 2s timeout, 3 failures | The pod is **removed from the Service endpoints** (gets no traffic) but **not restarted**. Used during startup and rolling updates |
| **liveness** | `/live` | every 10s, 2s timeout, 3 failures | The container is **restarted**. This catches a hung event loop |

- **Why a startup probe instead of `initialDelaySeconds`:** a fixed delay is either too short (restart loops on a slow node) or too long (slow rollouts). The startup probe adapts.
- **Why readiness and liveness are separate:** being temporarily not ready shouldn't trigger a restart.

### Exposure: Service + Ingress

```
client ──▶ app.34.56.31.129.nip.io (DNS → node IP) ──▶ Traefik (hostPort 80/443 on every node)
       ──▶ Ingress rule (host + path) ──▶ Service sample-nodejs:80 (ClusterIP) ──▶ pods :8080
```

- **Service `ClusterIP`, port 80 → named target port `http` (8080):** a stable in-cluster address and load balancing across ready pods. It isn't a NodePort or LoadBalancer, because the Ingress is the single public entry point.
- **Ingress (`ingressClassName: traefik`):** Traefik is the ingress controller bundled with RKE2. The host `app.34.56.31.129.nip.io` uses nip.io wildcard DNS, so no domain needs to be registered.
- **Only `/my-app` and `/about` are routed (`pathType: Exact`).** `/classified`, `/metrics`, `/ready` and `/live` aren't reachable from outside the cluster. That's least exposure at the edge: internal and operational endpoints stay internal.
- **TLS:** set `ingress.tls` with a certificate Secret (e.g. from cert-manager). Without it, Traefik serves HTTPS with its default self-signed certificate.

### Resource requests and limits

```yaml
resources:
  requests: { cpu: 50m,  memory: 64Mi }
  limits:   { cpu: 200m, memory: 128Mi }
config:
  NODE_OPTIONS: "--max-old-space-size=96"
```

- **Requests** are what the scheduler *reserves* on a node. They're sized to the app's real baseline (an idle Express process uses about 40–50 MiB RSS and almost no CPU), so the pod fits on the small 2-vCPU nodes, where CPU requests are the scarce resource.
- **CPU limit (200m):** short bursts (4× the request) are allowed. Going over the limit only **throttles** the container; it never kills it. This stops one pod from starving its neighbours.
- **Memory limit (128Mi):** going over the limit gets the container **OOM-killed**, so memory limits must be set realistically.
- **`--max-old-space-size=96`:** V8's heap cap is kept below the container limit, leaving room for buffers and native memory. Node then garbage-collects (or reports out of memory) before the kernel kills the container.
- **The HPA depends on requests:** `targetCPUUtilizationPercentage: 70` means 70% of the **50m request**. Without requests, an HPA can't work.
- **QoS class: Burstable** (requests < limits). Pods are evicted only after BestEffort pods under node pressure.

### Configuration: ConfigMap and Secret

- **ConfigMap** ([`configmap.yaml`](helm/sample-nodejs/templates/configmap.yaml)): `PORT` (from `containerPort`, so the port, probes and app always agree), `NODE_ENV=production` and `NODE_OPTIONS`. It's injected with `envFrom`.
- **Secret** ([`secret.yaml`](helm/sample-nodejs/templates/secret.yaml)): the app needs no secrets today, but the chart supports them two ways:
  - `existingSecret: <name>`: reference a Secret created outside the chart. **Recommended**, e.g. with Sealed Secrets or External Secrets, so real values never go into Git or Helm values.
  - `secret: {KEY: value}`: the chart creates the Secret (convenient for testing).
- **Config changes roll the pods:** `checksum/config` and `checksum/secret` annotations on the pod template change whenever the values change. Kubernetes doesn't restart pods when a ConfigMap changes, so this triggers a rolling restart.

### Security

| Setting | Why |
|---|---|
| `runAsNonRoot: true`, `runAsUser: 65532` | Runs as the unprivileged `nonroot` user of the distroless image, not root |
| `readOnlyRootFilesystem: true` | The app writes nothing, so an attacker can't drop files or modify code |
| `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` | No setuid tricks, no Linux capabilities |
| `seccompProfile: RuntimeDefault` | Blocks dangerous syscalls |
| Dedicated ServiceAccount, `automountServiceAccountToken: false` | The app never calls the Kubernetes API, so no token is mounted for an attacker to steal |
| Ingress routes only public paths | `/classified` and `/metrics` aren't reachable from the internet |
| Traefik security-headers Middleware | Strips `X-Powered-By` / `Server` (stack disclosure, SonarQube `javascript:S5689`) and adds `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, all at the ingress with no app code change |
| Optional NetworkPolicy | Only the ingress controller's namespace (`kube-system`) can reach the pods |

### Availability and graceful shutdown

- **`replicaCount: 2` and topology spread across nodes** (`maxSkew: 1`, soft): losing a node doesn't take the app down.
- **PodDisruptionBudget `minAvailable: 1`:** node drains and upgrades evict pods one at a time.
- **`preStop` sleep (5s):** Traefik and the endpoints controller stop routing to the pod *before* it exits, so in-flight requests aren't dropped.
- **`shareProcessNamespace: true`:** Node.js has no default SIGTERM handler, and as **PID 1** the kernel ignores signals that have no handler, so pods would hang until SIGKILL at the end of the grace period. With a shared process namespace, the pause container is PID 1, and node gets SIGTERM's default action (exit) right away. This is fixed at the platform level, with no application code change. The CI smoke test does the same with `docker run --init` and checks the container stops in under 5 seconds.
- **`revisionHistoryLimit: 5`:** enough ReplicaSets kept for quick rollbacks.

### Autoscaling (optional)

`autoscaling.enabled: true` creates an HPA (2–4 replicas at 70% CPU) and drops the fixed `replicas` from the Deployment, so Helm/Argo CD and the HPA don't fight over the count. It's off by default because the cluster's 2-vCPU nodes have little spare CPU to reserve. metrics-server is already installed in RKE2.

---

## Steps: deploy the chart

### Prerequisites
- `kubectl` pointing at the cluster (context `rke2-devsecops`) and Helm 3 or 4
- The app image, which the CI/CD pipeline builds, scans, signs and pushes to `ghcr.io/elad1122/sample-nodejs:<version>`. The chart's `appVersion` (bumped by every release) is the default tag. Override it with `--set image.repository=… --set image.tag=…`

### 1. Validate the chart
```bash
helm lint helm/sample-nodejs --strict

# Render locally to review the exact manifests
helm template sample-nodejs helm/sample-nodejs -n default

# Optional: validate against the cluster's API without creating anything
helm template sample-nodejs helm/sample-nodejs -n default | kubectl apply --dry-run=server -f -
```

### 2. Install / upgrade
```bash
helm upgrade --install sample-nodejs helm/sample-nodejs \
  -n default \
  --set image.tag=1.0.0 \
  --wait
```
- `upgrade --install` works for both the first install and later upgrades.
- `--wait` returns only when all pods pass their readiness probes.
- The `default` namespace follows the assignment's requirement.

### 3. Verify
```bash
kubectl -n default get deploy,pods,svc,ingress -l app.kubernetes.io/instance=sample-nodejs
helm test sample-nodejs -n default          # in-cluster: Service -> /ready and /my-app

curl http://app.34.56.31.129.nip.io/my-app     # Hello, World!
curl http://app.34.56.31.129.nip.io/about
curl -o /dev/null -w "%{http_code}\n" http://app.34.56.31.129.nip.io/classified   # 404, not exposed
```
Metrics, in-cluster only:
```bash
kubectl -n default port-forward svc/sample-nodejs 8080:80
curl localhost:8080/metrics | grep root_access_total
```

### 4. Change configuration
Edit `values.yaml`, or pass `--set`, and run step 2 again. For example:
```bash
--set replicaCount=3
--set autoscaling.enabled=true
--set config.LOG_LEVEL=debug          # new env var; pods roll automatically (checksum annotation)
--set existingSecret=sample-nodejs-secrets
```

### 5. Roll back / uninstall
```bash
helm history sample-nodejs -n default
helm rollback sample-nodejs <REVISION> -n default
helm uninstall sample-nodejs -n default
```

## Chart validation results

```
$ helm lint helm/sample-nodejs --strict
1 chart(s) linted, 0 chart(s) failed

$ helm template ... --set autoscaling.enabled=true --set networkPolicy.enabled=true --set secret.API_KEY=x \
    | kubectl apply --dry-run=server -f -
networkpolicy.networking.k8s.io/sample-nodejs created (server dry run)
poddisruptionbudget.policy/sample-nodejs created (server dry run)
serviceaccount/sample-nodejs created (server dry run)
secret/sample-nodejs created (server dry run)
configmap/sample-nodejs created (server dry run)
service/sample-nodejs created (server dry run)
deployment.apps/sample-nodejs created (server dry run)
horizontalpodautoscaler.autoscaling/sample-nodejs created (server dry run)
ingress.networking.k8s.io/sample-nodejs created (server dry run)
pod/sample-nodejs-test created (server dry run)
```
