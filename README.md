# DevOps take-home

A small Python service, a Helm chart, a one-command kind setup, and a debugged lab.

## How to run and verify

Prerequisites: Docker, kind, kubectl, helm.

```bash
./setup.sh                       # safe to run twice
curl -s -H 'Host: demo.local' http://localhost/     # {"app": ..., "version": ..., "pod": ...}
curl -s -H 'Host: demo.local' http://localhost/healthz
kubectl -n demo get pods         # 2 pods, Running 1/1
```

Change the response without a restart:

```bash
kubectl -n demo patch configmap demo-demo --type merge -p '{"data":{"VERSION":"2.0"}}'
# wait up to ~60s for the kubelet to refresh the mounted file, then curl again
```

Lab: see `lab/FINDINGS.md`. Session recording: `lab/part4-session.log`.

## Design notes

- **Service** (`service/`): stdlib Python `http.server`, no dependencies. `GET /` returns
  app, version and pod hostname. `GET /healthz` returns 200.
- **Config lookup:** the app reads `APP_NAME` and `VERSION` from files mounted from the
  ConfigMap at `/etc/app-config` on every request, and falls back to environment variables.
  Env vars from a ConfigMap don't update in running pods, so the mounted file is what
  lets `GET /` follow a ConfigMap patch without a restart.
- **Dockerfile:** multi-stage, pinned `python:3.12.8-slim-bookworm`, numeric non-root user
  (10001), `.dockerignore` included. The build stage only byte-compiles, because there are
  no dependencies yet.
- **Chart:** 2 replicas, liveness and readiness probes on `/healthz`, ConfigMap, Service,
  Ingress for `demo.local`. A `checksum/config` annotation rolls pods on `helm upgrade`.
  Pod runs non-root, read-only root filesystem, all capabilities dropped.

## Resource requests and limits

| | CPU | Memory |
|---|---|---|
| requests | 50m | 64Mi |
| limits | 200m | 128Mi |

These are estimates, **not load-tested**. A stdlib Python server idles at a small memory
footprint, so 64Mi requested leaves headroom and 128Mi limit would catch a leak before it
affects the node. CPU is low because the service does almost no work. TODO: replace with
measured numbers from `kubectl top pods` once you've checked them.

## What I deliberately skipped, and the risk

- **No TLS on the Ingress.** Traffic is plain HTTP; fine locally, unacceptable in production.
- **No PodDisruptionBudget, HPA or anti-affinity.** A node drain could take both replicas
  down at once.
- **No NetworkPolicy.** Any pod in the cluster can reach the service.
- **Image is built locally and loaded into kind.** No registry, no signing, no vulnerability
  scan, so the supply chain isn't covered. TODO: note if you did the Trivy bonus.
- **No tests for the service.** Behaviour was checked by hand with curl.
- **Config propagation delay:** the kubelet can take up to about a minute to refresh the
  mounted ConfigMap, so `GET /` is not instantly consistent after a patch.
- **ingress-nginx is end-of-life** but the task requires it. Pinned to a specific
  version; see ANSWERS.md for the migration approach.
- **`setup.sh` re-run does not restart pods** if only the source changed and the image tag
  stayed the same.

## What I'd change for production

- Push images to a registry with immutable digests, sign them, and scan in CI.
- Add TLS (cert-manager), PDB, HPA, topology spread, NetworkPolicies and a dedicated
  ServiceAccount with no token mounted.
- Structured logging, metrics endpoint and alerts, instead of only stdout access logs.
- Replace the ConfigMap file-read trick with a reload mechanism or a rollout on change.
- Migrate from ingress-nginx to Gateway API.

## How I used AI

- **Tool:** Claude (claude.ai chat).
- **What for:** TODO: adjust this to be true for you. For example: setting up WSL and
  Docker on my Windows machine, a first draft of the Python service and Dockerfile, the
  Helm chart templates and `setup.sh`, and a draft of this README's structure.
- **What I had to correct or work around:** TODO: write your own list. Real examples so far:
  the Docker Desktop and WSL integration kept failing, so I installed Docker Engine inside
  Ubuntu; a copy command used a placeholder folder name that I had to replace with the
  real path.
- **What I did myself:** TODO: for example, running everything from a clean cluster,
  debugging the Part 4 lab and writing up FINDINGS.md from my own terminal output, and
  answering Part 5 in my own words.
- I reviewed everything above and can explain and modify it.
