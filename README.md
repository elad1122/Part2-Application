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

---

# CI/CD pipeline (DevSecOps)

**Tool:** GitHub Actions, in [`.github/workflows/ci-cd.yml`](.github/workflows/ci-cd.yml). It runs on every push and PR to `main` and `dev`, and can also be started manually.

```
 push / PR ─┬─▶ secrets  Gitleaks (full git history)                 ─┐
            ├─▶ sast     SonarQube + strict Quality Gate             ─┤
            ├─▶ sca      npm audit + Trivy (dependencies)            ─┼─▶ image ──────────────────────────────▶ release
            ├─▶ config   Hadolint + Trivy config (Dockerfile, Helm)  ─┤   build (not pushed)                    (main + feat/fix only)
            └─▶ version  SemVer from Conventional Commits            ─┘   → Trivy image gate: HIGH/CRITICAL=STOP bump package.json + chart
                                                                          → SBOM → smoke test                    git tag vX.Y.Z
                                                                          → [release] push GHCR → cosign sign    GitHub Release + changelog
```

**Every security job must pass before the image is even built.** If any gate fails, nothing downstream runs. On `dev` and PRs, everything is built and scanned but **nothing is published**.

## Security checks: what fails the pipeline

| Job | Tool | Fails when | Why it matters |
|---|---|---|---|
| **Secret scan** | [Gitleaks](https://github.com/gitleaks/gitleaks) 8.30.1 (container pinned by digest), full history, `--redact` | Any credential, token or key is committed, now or in any past commit | Leaked secrets are the most common breach cause; history counts because deleted secrets are still readable in git |
| **SAST** | **SonarQube Community 26.10** (official container) | The **Quality Gate** fails (details below) | Finds vulnerabilities, bugs and insecure patterns in the source code |
| **SCA** (dependencies) | `npm audit --audit-level=high` + **Trivy fs** | Any **HIGH/CRITICAL** CVE in a dependency | Most app vulnerabilities come from third-party packages |
| **Misconfiguration** | **Hadolint** (Dockerfile) + **Trivy config** (Dockerfile + rendered Helm chart) | Dockerfile bad practices (warning+), or HIGH/CRITICAL Kubernetes/Docker misconfigurations | Catches root containers, missing limits, privileged pods and so on before they ship |
| **Image scan** | **Trivy image** on the built image | **Any HIGH or CRITICAL CVE, which blocks the push and the deployment** | The assignment's hard requirement: vulnerable images never reach the registry |
| **Smoke test** | `docker run --read-only --cap-drop ALL --init` + curl | The app doesn't start, the probes or `/metrics` fail, it runs as root, or it takes ≥5s to stop on SIGTERM | Proves the hardened image actually works with the settings the chart uses |

All Trivy results are also uploaded as **SARIF** to the repo's *Security → Code scanning* tab, so findings are tracked over time.

### SAST: SonarQube in CI, with a strict gate
- **Self-hosted:** a fresh **SonarQube Community** server starts as a *service container* in every run. No external account or long-lived secret is needed.
  - [`sonarqube-setup.sh`](.github/scripts/sonarqube-setup.sh) **rotates the factory admin password** to a random one, creates a **per-run analysis token**, and installs the gate. Both are masked in logs and die with the job.
- **Quality Gate `CI-Strict`, applied to *all* code:** the built-in "Sonar way" gate only checks *new* code, and on a fresh server every run is a first analysis with no baseline, so it would always pass. These conditions apply to the whole codebase instead:

  | Condition | Fails when |
  |---|---|
  | Security issues (vulnerabilities) | > 0 |
  | Reliability issues (bugs) | > 0 |
  | Security hotspots reviewed | < 100% (any unreviewed hotspot) |
  | Maintainability rating | worse than A |
- **The gate is enforced** with `sonar.qualitygate.wait=true`, so the scanner step fails when the gate is red.
- **Results:** [`sonarqube-report.sh`](.github/scripts/sonarqube-report.sh) publishes the gate status, metrics, issues and hotspots as **annotations on the run** and in the job summary. The server is thrown away after the job, so these are the durable record.

## Version bumping (SemVer + Conventional Commits)

**Commit messages decide the next version.** [`next-version.sh`](.github/scripts/next-version.sh) reads the commits since the last `vX.Y.Z` tag:

| Commit message | Bump | Example |
|---|---|---|
| `feat!: …` or `BREAKING CHANGE:` in the body | **major** | 1.4.2 → 2.0.0 |
| `feat: …` | **minor** | 1.4.2 → 1.5.0 |
| `fix: …` / `perf: …` | **patch** | 1.4.2 → 1.4.3 |
| `docs:`, `chore:`, `ci:`, `test:` … | no release | — |
| *(no tag yet)* | first release = `package.json` version | 1.0.0 |

**On `main`,** after every gate passes:
1. The image is pushed as **`ghcr.io/elad1122/sample-nodejs:X.Y.Z`** plus `sha-<commit>`. **There is no `latest` tag**, so every tag means exactly one image.
2. The release job bumps `package.json` and the Helm chart's `version` / `appVersion` (the chart's default image tag). It commits `chore(release): vX.Y.Z [skip ci]`, so `[skip ci]` and the `GITHUB_TOKEN` push don't start a loop.
3. It creates an **annotated tag `vX.Y.Z`** and a **GitHub Release** with a changelog built from the commit messages, with the SBOM attached.

**Everywhere else** (dev, PRs), the version is a pre-release label such as `1.0.0-dev.g1e3502c`, used for the image labels only.

**Dependabot** ([`.github/dependabot.yml`](.github/dependabot.yml)) opens weekly PRs for npm packages, base-image digests and the pinned Actions. Its commit prefixes (`fix(deps)`, `fix(docker)`, `ci`) mean security updates turn into patch releases automatically.

The logic was tested for every case: first release, docs-only (no release), fix → patch, feat → minor, breaking → major, and PRs (never release).

## Building and publishing the Docker image

- **Builder: Docker** with its BuildKit engine (`docker/setup-buildx-action` + `docker/build-push-action`). Kaniko isn't needed: GitHub-hosted runners provide a Docker daemon, and Kaniko's main advantage is building inside a cluster without one. Layers are cached between runs (`type=gha`).
- **Registry: GitHub Container Registry (public)**, `ghcr.io/elad1122/sample-nodejs`. It's integrated with the repo and authenticates with the run's short-lived `GITHUB_TOKEN`, so no registry password is stored. The cluster can pull the image without credentials.
- **Order:** build locally → scan → smoke test → `docker tag` + `docker push`, only on a release from `main`.

Published `1.0.0` image, as read from the registry:

| Property | Value |
|---|---|
| Platform | `linux/amd64` |
| User | `nonroot` |
| Entrypoint / command | `/nodejs/bin/node app.js` |
| Port | `8080/tcp` |
| Labels | OCI `title`, `version` (`1.0.0`), `source` (this repo), `revision` (the commit it was built from) |

## Secure image (Dockerfile)

| Practice | How |
|---|---|
| Minimal runtime | **Multi-stage**: `node:24-trixie-slim` installs the dependencies, and the runtime is **`gcr.io/distroless/nodejs24-debian13:nonroot`**, with no shell, package manager or npm |
| Reproducible | Base images **pinned by digest**; `npm ci` from the lockfile |
| No dev or untrusted code | `npm ci --omit=dev --ignore-scripts`: no devDependencies, and no dependency install scripts run during the build |
| Least content | Only `node_modules`, `package.json` and `app.js` are copied, not the whole repo |
| Non-root | `USER nonroot` (uid 65532), matching the chart's `runAsUser` |
| Current runtime | Node **24** (Active LTS); the original `node:21-alpine` reached end-of-life in 2024 |

## Supply-chain security

- **Every Action is pinned to a full commit SHA** (`uses: actions/checkout@3d3c42e… # v7.0.1`), not a movable tag. A compromised or re-tagged third-party action can't inject code, and Dependabot keeps the pins current.
- **Least-privilege tokens:** workflow-level `permissions: contents: read`. Only the jobs that need more ask for it: `packages: write` for the GHCR push, `id-token: write` for keyless signing, `security-events: write` for SARIF, and `contents: write` for the release job only.
- **No stored registry password:** GHCR uses the run's short-lived `GITHUB_TOKEN`.
- **The scanned image is the pushed image:** the image is built once, loaded locally, scanned, smoke-tested, and then *that same image* is tagged and pushed. Nothing gets rebuilt after scanning.
- **Signing and SBOM:** on release the image is **signed with cosign keyless** (Sigstore, using GitHub's OIDC identity, so there are no keys to manage), and a **CycloneDX SBOM** is attached as a signed attestation and to the GitHub Release. To verify:
  ```bash
  cosign verify ghcr.io/elad1122/sample-nodejs:<version> \
    --certificate-identity-regexp 'https://github.com/elad1122/Part2-Application/.github/workflows/ci-cd.yml@.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
  ```
- **Concurrency:** a newer run cancels older runs on the same branch, except on `main`, where releases are never cancelled halfway.

## Findings the pipeline caught, and how each was handled

The scope of this work is DevOps only; **application code (`app.js`) is unchanged.**

| # | Gate | Finding | Resolution |
|---|---|---|---|
| 1 | SCA | `package-lock.json`: **3 HIGH + 1 CRITICAL** (express ≤4.22.2, body-parser, path-to-regexp, proxy-addr, qs) | `npm audit fix`: lockfile updated to **express 4.22.3** and its patched dependencies. `package.json` is unchanged |
| 2 | SCA (Trivy fs) | An unused **Dagger** CI module (`.dagger/`) with **12 vulnerable Go modules** (grpc, golang.org/x/net, OpenTelemetry) | Removed, since GitHub Actions is the pipeline. It wasn't part of the app or the image |
| 3 | Secret scan | `sonar.projectKey=…` flagged as `generic-api-key` | **False positive** (a public identifier). Allowlisted in [`.gitleaks.toml`](.gitleaks.toml), scoped to that rule, file and key only |
| 4 | Secret scan | `curl -u admin:admin` in an earlier version of the Sonar setup script | SonarQube's documented factory default for the throwaway container (rotated at startup). The script no longer writes it literally, and the allowlist is scoped to that single past commit and rule |
| 5 | **SAST** | **`javascript:S5689` VULNERABILITY:** Express discloses its version through the `X-Powered-By` header. **The Quality Gate failed and blocked the pipeline** | **Mitigated at the platform:** the Helm chart's Traefik Middleware strips `X-Powered-By` and `Server` and adds security headers. The rule is marked accepted for `app.js` in [`sonar-project.properties`](sonar-project.properties) with that reason, so any other finding still fails the gate. The proper long-term fix is one line in the app, `app.disable('x-powered-by')`, for the dev team |
| 6 | Image | Base `node:21-alpine` (end-of-life) | Replaced by distroless Node 24. Trivy finds **0 HIGH/CRITICAL** in the new image |

## Evidence: real pipeline runs

| Run | What it shows |
|---|---|
| [#7](https://github.com/elad1122/Part2-Application/actions/runs/40954665353) | **SAST gate blocks:** SonarQube found S5689 (`vulnerabilities=1`), *Quality Gate ERROR*, the image job was skipped |
| [#9](https://github.com/elad1122/Part2-Application/actions/runs/40955687107) | **All green with the original `app.js`:** every gate passed, *Quality Gate OK*, the image built, Trivy found 0 HIGH/CRITICAL, the smoke test passed, nothing published (dev) |
| [#10](https://github.com/elad1122/Part2-Application/actions/runs/40956224642) | **Trivy gate blocks deployment:** a demo commit used the old `node:21-alpine` base. The *Trivy image gate* failed, and SBOM, smoke test, push and signing were all **skipped**. The demo commit was reverted right after |

## Deployment (GitOps with Argo CD)

Deployment config lives in a **separate infra repo, [Part3-GitOps](https://github.com/elad1122/Part3-GitOps)**. Its README explains why, and how Argo CD is set up.

The last pipeline job, `deploy`, runs only after every gate, the image push and the release have passed. It changes one line in that repo (`targetRevision: vX.Y.Z`) and pushes. **The pipeline never talks to the cluster:** Argo CD sees the commit and syncs. So a build blocked by a gate can't reach the cluster.

It authenticates with `GITOPS_DEPLOY_KEY`, a deploy key with write access to that one repo only.

## How to use it

- **Day-to-day:** work on `dev` and open a PR to `main`. Every push and PR runs all the gates.
- **Release:** merge to `main` with at least one `feat:` / `fix:` commit. The pipeline publishes, signs, bumps the version, tags and releases.
- **Pulling the image:** the GHCR package `sample-nodejs` is public, so the cluster needs no pull secret. If it's ever made private, create an image-pull Secret and set `imagePullSecrets` in the chart.
- **Recommended repo settings:** branch protection on `main` that requires the CI/CD checks to pass, so a PR can't be merged past a failed gate. If you enable it, allow `github-actions[bot]` to push the release commit, or change the release step to open a PR instead.

### Reproduce the checks locally
```bash
npm ci --ignore-scripts && npm audit --omit=dev --audit-level=high
docker build -t sample-nodejs:local .
docker run --rm aquasec/trivy image --severity HIGH,CRITICAL --exit-code 1 sample-nodejs:local
docker run --rm -v "$PWD:/repo" ghcr.io/gitleaks/gitleaks:v8.30.1 git /repo --redact
docker run --rm -i hadolint/hadolint < Dockerfile
```
