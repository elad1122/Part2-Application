# Part 2 – Helm chart, CI/CD and deployment for the sample Node.js app

This repo is my fork of the sample app. On top of it I:

- wrote a Helm chart so the app can be deployed to the RKE2 cluster from Part 1
- built a GitHub Actions pipeline that scans, builds, signs and releases it
- deployed it with Argo CD

---

## The Helm chart

The chart is in `helm/sample-nodejs`:

```
helm/sample-nodejs/
├── Chart.yaml
├── values.yaml              # all the settings, with comments
└── templates/
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    ├── middleware.yaml      # Traefik: security headers
    ├── configmap.yaml
    ├── serviceaccount.yaml
    ├── pdb.yaml
    ├── NOTES.txt
    └── tests/test-connection.yaml
```

### Deployment or StatefulSet? Deployment

I went through what the app actually keeps. It writes nothing to disk, has no database or user sessions, and no instance needs to be "the leader". The only state in memory is its Prometheus counters, and those are per-process on purpose: Prometheus adds them up across pods. So every pod is interchangeable, and the app is stateless.

A StatefulSet is for the opposite case: pods that need a fixed name (`app-0`, `app-1`), a stable network address, and their own disk that follows them around. Databases like the MongoDB from Part 1 are the typical example. None of that applies here. A StatefulSet would also replace pods one by one in order, which only makes rollouts slower.

A Deployment gives me what this app needs:
- rolling updates with no downtime (`maxSurge: 1`, `maxUnavailable: 0`, so a new pod is ready before an old one goes away)
- quick scaling, by changing the replica count
- easy rollbacks

### Health checks: startup, readiness and liveness probes

The app has two health endpoints, and I used three probes:

| Probe | Endpoint | Settings | What happens when it fails |
|---|---|---|---|
| startup | `/live` | every 2s, up to 15 failures (30s) | Nothing yet. The other two probes wait until this one passes |
| readiness | `/ready` | every 5s, 2s timeout, 3 failures | The pod stops getting traffic, but it isn't restarted |
| liveness | `/live` | every 10s, 2s timeout, 3 failures | The container is restarted |

I used a startup probe instead of `initialDelaySeconds`. A fixed delay is always a guess: too short and a slow start gets the pod killed in a loop, too long and every rollout waits for nothing. The startup probe simply waits until the app is actually up.

I kept readiness and liveness separate on purpose. If a pod is briefly not ready (overloaded, or still starting), I want traffic to go elsewhere for a moment, not a restart. A restart is only for a pod that's really stuck, and that's what liveness catches.

### How it's exposed: Service and Ingress

```
client → app.34.56.31.129.nip.io → Traefik (ports 80/443 on every node)
       → Ingress rule → Service sample-nodejs:80 → pods :8080
```

- **Service:** a `ClusterIP` on port 80, pointing at the container's named `http` port (8080). It gives the pods one stable address inside the cluster and spreads traffic across the ready ones. I didn't use a NodePort here, because I want a single public entry point, and that's the Ingress.
- **Ingress:** uses Traefik, the ingress controller that comes with RKE2. The host is `app.34.56.31.129.nip.io`; nip.io turns any name ending in an IP into that IP, so I didn't need to register a domain.
- **Only two paths are public:** the Ingress routes `/my-app` and `/about` and nothing else. `/classified`, `/metrics`, `/ready` and `/live` are only reachable inside the cluster. There's no reason for the internet to see the metrics or the health checks, and `/classified` sounds like something that shouldn't be public anyway.
- **HTTPS:** Traefik also serves the app over HTTPS, with its default self-signed certificate.

### Requests and limits

```yaml
resources:
  requests: { cpu: 50m,  memory: 64Mi }
  limits:   { cpu: 200m, memory: 128Mi }
config:
  NODE_OPTIONS: "--max-old-space-size=96"
```

- **Requests** are what the scheduler reserves for the pod. An idle Express process uses about 40–50 MiB and almost no CPU, so I sized the requests close to that. On the 2-vCPU nodes, reserved CPU is the thing that runs out first, so I didn't want to reserve more than the app needs.
- **CPU limit (200m):** the app can burst to 4× its request. Going over a CPU limit only slows the container down; it doesn't kill it.
- **Memory limit (128Mi):** going over a memory limit gets the container killed (OOM), so this one has to be realistic.
- **`--max-old-space-size=96`:** by default Node doesn't know about the container's memory limit. This caps its heap at 96 MB, below the 128Mi limit, leaving room for everything outside the heap. Node then cleans up memory, or fails with its own clear error, before the kernel kills the container.

### Configuration: ConfigMap

- **ConfigMap:** `PORT`, `NODE_ENV=production` and `NODE_OPTIONS`, injected as environment variables. `PORT` is taken from the chart's `containerPort` value, so the app, the Service and the probes can never disagree about the port.
- **No Secret:** the app doesn't read any passwords, keys or tokens, so there's nothing to put in a Secret. I didn't add an empty one just to have it. If the app ever needs one, I'd create it outside the chart (for example with Sealed Secrets or External Secrets) and load it with `envFrom`, so secret values never end up in Git.
- **Config changes restart the pods:** Kubernetes doesn't restart pods when a ConfigMap changes, so a new value would just sit there unused. I added a checksum of the ConfigMap as an annotation on the pod. When a value changes, the checksum changes, and the Deployment rolls the pods.

### Security in the pod

- The app runs as the unprivileged `nonroot` user (uid 65532) from the distroless image, never as root.
- The root filesystem is read-only. The app doesn't write anything, so an attacker can't drop files or change the code.
- No privilege escalation, all Linux capabilities dropped, and the default seccomp profile to block risky system calls.
- The pod has its own ServiceAccount with no API token mounted. The app never talks to the Kubernetes API, so there's no token for an attacker to steal.
- A Traefik Middleware removes the `X-Powered-By` and `Server` headers, which reveal the stack, and adds `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY` and `Referrer-Policy: no-referrer`. All of this is done at the ingress, without changing the app.

### Staying up during updates and node failures

- **Two replicas, spread across nodes,** so losing one node doesn't take the app down.
- **A PodDisruptionBudget (`minAvailable: 1`),** so when a node is drained for maintenance, its pods are moved one at a time.
- **A 5-second `preStop` sleep.** When a pod is shutting down, it takes a moment for Traefik to stop sending it traffic. The sleep keeps the pod alive during that moment, so requests that are already on their way don't get dropped.
- **`shareProcessNamespace: true`.** This one took me a while to figure out. The app doesn't handle SIGTERM itself, and when a process runs as PID 1 in a container, Linux ignores signals it has no handler for. So on every shutdown, the pod just hung for the full grace period until it was force-killed. Sharing the process namespace makes the pause container PID 1 instead. Node then gets the normal SIGTERM behaviour and exits right away, again without changing the app code.


---

## The CI/CD pipeline

I used **GitHub Actions**, since the code already lives on GitHub. There's no CI server to run or maintain, and it connects directly to GitHub's container registry and security tab. The whole pipeline is in `.github/workflows/ci-cd.yml`. It runs on every push and pull request to `main` and `dev`, and can also be started by hand.

```
push / PR ─┬─ secrets   Gitleaks                        ─┐
           ├─ sast      SonarQube + strict quality gate  ─┤
           ├─ sca       npm audit + Trivy (dependencies) ─┼─→ image ───────────────→ release
           ├─ config    Hadolint + Trivy (Dockerfile,    ─┤   build                    (main only)
           │            Helm chart)                       │   Trivy scan: HIGH = stop  bump version
           └─ version   next version from commit messages─┘   SBOM, smoke test         tag + GitHub Release
                                                              push + sign (main only)
```

The idea is simple: **the image isn't even built until every security check has passed.** If one of them fails, everything after it is skipped. On `dev` and in pull requests the image is still built and scanned, but nothing is published.

### Security checks and what makes the pipeline fail

| Check | Tool | Fails when |
|---|---|---|
| Secrets | Gitleaks, over the full Git history | Any key, token or password was ever committed, even in an old commit |
| SAST | SonarQube Community | The quality gate fails (see below) |
| Dependencies (SCA) | `npm audit --audit-level=high` and Trivy | Any HIGH or CRITICAL vulnerability in a dependency |
| Misconfiguration | Hadolint (Dockerfile) and Trivy config (Dockerfile + the rendered Helm chart) | Dockerfile bad practices, or HIGH/CRITICAL Kubernetes and Docker misconfigurations |
| Image scan | Trivy, on the built image | **Any HIGH or CRITICAL vulnerability. The image isn't pushed and can't be deployed** |
| Smoke test | `docker run` with a read-only filesystem, no capabilities, then `curl` | The app doesn't start, a health check or `/metrics` fails, it runs as root, or it takes 5 seconds or more to stop |

Why each one is there:

- **History matters for secrets.** A secret deleted in a later commit can still be read from Git.
- **Most vulnerabilities in a Node app come from dependencies**, not from the app's own code.
- **The smoke test runs the image with the same restrictions the chart uses.** That way I know the hardened image really works before it ships.

All Trivy results are also uploaded to the repo's Security → Code scanning tab, so findings can be followed over time.

### SAST with SonarQube

I didn't want to depend on an outside account, so SonarQube runs **inside the pipeline itself**. A fresh SonarQube server starts as a service container in every run and is thrown away when the job ends.

A brand-new SonarQube server needs a bit of preparation before it can be used, and `.github/scripts/sonarqube-setup.sh` does that:

1. **It changes the default `admin/admin` password** to a random one. It's a short-lived server, but I'd rather not run anything on factory credentials.
2. **It creates a stricter quality gate, `CI-Strict`, and makes it the default.** The built-in gate only checks *new* code. On a fresh server every run is a first analysis, with no previous one to compare against, so the built-in gate would always pass. My gate checks the whole codebase and fails if there's:
   - any vulnerability
   - any bug
   - any security hotspot that hasn't been reviewed
   - a maintainability rating worse than A
3. **It creates a token for the scanner** that only lives as long as the run.

The password and the token are masked in the logs. The scanner runs with `sonar.qualitygate.wait=true`, so a failed gate fails the step.

**Keeping the results.** The server disappears after each run, so at the end of the job (even when the gate failed) I pull the results from its API into JSON files:
- the quality gate status
- the issues
- the security hotspots
- the main measures

They're uploaded as the `sonarqube-report` artifact on the run and kept for 30 days.

### Version bumping

I didn't want to bump versions by hand, so **the commit messages decide the next version**, following Conventional Commits and SemVer. `.github/scripts/next-version.sh` looks at the commits since the last `vX.Y.Z` tag:

| Commit message | What it does | Example |
|---|---|---|
| `feat!: …`, or `BREAKING CHANGE` in the body | major bump | 1.4.2 → 2.0.0 |
| `feat: …` | minor bump | 1.4.2 → 1.5.0 |
| `fix: …` or `perf: …` | patch bump | 1.4.2 → 1.4.3 |
| `docs:`, `chore:`, `ci:`, `test:` … | no release | |
| no tag yet | first release, using the version in `package.json` | 1.0.0 |

When something is merged to `main` and every check passes:

1. The image is pushed as `ghcr.io/elad1122/sample-nodejs:X.Y.Z` (and `sha-<commit>`). I deliberately don't push a `latest` tag, so every tag always means exactly one image.
2. The release job updates the version in `package.json` and in the Helm chart (`version` and `appVersion`, which is the chart's default image tag). It commits that as `chore(release): vX.Y.Z [skip ci]`. The `[skip ci]` stops the commit from starting the pipeline again.
3. It creates a `vX.Y.Z` tag and a GitHub Release, with a changelog made from the commit messages and the SBOM attached.

Anywhere else (`dev`, pull requests), nothing is released. The build just gets a label like `1.0.0-dev.g1e3502c`: the version it *would* get, plus the commit.

Dependabot opens weekly PRs for npm packages, the base images and the GitHub Actions. Its commits start with `fix(deps)` or `fix(docker)`, so a security update automatically becomes a patch release.

### Building the image

- **The order matters:** build → scan → smoke test → push. Nothing is pushed until it passed, and only on a release from `main`.

The Dockerfile:

- **Two stages.** `node:24-trixie-slim` installs the dependencies. The final image is `gcr.io/distroless/nodejs24-debian13:nonroot`, which has no shell, no package manager and no npm, so there's very little an attacker could use.
- **Base images pinned by digest,** and `npm ci` installs exactly what's in the lockfile, so the same commit always builds the same image.
- **`npm ci --omit=dev --ignore-scripts`:** no dev dependencies in the image, and no install scripts from dependencies run during the build.
- **Only what the app needs is copied:** `node_modules`, `package.json` and `app.js`.
- **It runs as `nonroot`** (uid 65532), the same user the chart expects.
- **Node 24.** The original `node:21-alpine` image had reached end of life.

### Supply-chain protection

- **Every GitHub Action is pinned to a full commit SHA,** not a tag like `v4`. Tags can be moved, so if a third-party action were ever compromised, a tag could quietly point at bad code. Dependabot keeps the pins up to date.
- **Minimal permissions:** the workflow only gets read access by default, and each job asks for exactly what it needs. Only the push job can write packages, only the signing step gets an OIDC token, and only the release job can write to the repo.
- **The image I scan is the image I push.** It's built once, scanned, tested, and then that same image is tagged and pushed. Nothing is rebuilt after the scan.
- **Signing and SBOM:** released images are signed with cosign in keyless mode, using GitHub's identity, so there are no signing keys to manage or leak. A CycloneDX SBOM is attached to the image and to the GitHub Release. To check a signature:
  ```bash
  cosign verify ghcr.io/elad1122/sample-nodejs:<version> \
    --certificate-identity-regexp 'https://github.com/elad1122/Part2-Application/.github/workflows/ci-cd.yml@.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
  ```
- **A new run cancels older runs on the same branch,** except on `main`, where a release is never cut off halfway.

---

## Deploying with Argo CD (GitOps)

The Argo CD `AppProject` and `Application` live in a separate repo, [Part3-GitOps](https://github.com/elad1122/Part3-GitOps), whose README explains that choice. The Helm chart and its `values.yaml` stay here, next to the code.

The Application follows the newest `vX.Y.Z` tag of this repo. The release job only creates that tag after every check and the image push have succeeded, so a build that failed a check can never reach the cluster.

**The pipeline never touches the cluster and has no cluster credentials at all.** It creates a tag, and Argo CD notices it and syncs within about 3 minutes.

## Day-to-day use

- Work on `dev` and open a pull request to `main`. Every push and every PR runs all the checks.
- To release, merge to `main` with at least one `feat:` or `fix:` commit. The pipeline takes care of the rest: version, image, signature, tag and release.
- I'd also protect `main` so a PR can't be merged unless the pipeline passed. If you do that, allow `github-actions[bot]` to push the release commit, or switch the release step to open a PR instead.


