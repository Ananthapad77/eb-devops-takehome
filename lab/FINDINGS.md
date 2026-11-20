# Findings — Part 4 debug lab

---

## Defect 1: Invalid `restartPolicy` on `migrate` Job

**Symptom:**
`helm install` / Job creation failed because Kubernetes rejects `restartPolicy: Always` on `batch/v1` Jobs.

**Cause:**
`broken-chart/templates/migrate-job.yaml` had `restartPolicy: Always`, which is invalid for a Job (only `Never` or `OnFailure` is allowed).

**Fix:**
Changed `restartPolicy: Always` to `restartPolicy: Never` in `broken-chart/templates/migrate-job.yaml` so the migration runs once and does not loop on failure.

**How I found it:**
Observed the API validation error during chart installation and inspected `broken-chart/templates/migrate-job.yaml`.

---

## Defect 2: Missing `PORT: "8080"` override and `runAsUser` across workloads

**Symptom:**
Pods failed readiness probes (connection refused on port `8080`) and/or failed to start under `runAsNonRoot: true` without a numeric `runAsUser`. Container logs showed:
`listening on :8081 (image default is 8081; set PORT to override)`

**Cause:**
The `eb-debug-app:1.0.1` image defaults to listening on port `8081`, whereas all Services and readiness probes in the chart target `common.port` (`8080`). Additionally, `securityContext` enforced `runAsNonRoot: true` without specifying a numeric `runAsUser`.

**Fix:**
Added `PORT: "8080"` under `env` for `backend`, `gateway`, `worker`, `reporter`, and `metrics` in `broken-chart/values.yaml`, and added `common.runAsUser: 65532` referenced in all workload templates.

**How I found it:**
Checked pod status/events with `kubectl -n debug-lab describe pod` and container startup logs with `kubectl -n debug-lab logs`.

---

## Defect 3: `gateway` pointing to `backend` in the wrong namespace

**Symptom:**
`gateway` `/status` failed to reach `backend` (`./scenario.sh verify` reported `gateway /status does not report backend=ok`).

**Cause:**
`broken-chart/values.yaml` set `BACKEND_URL: "http://backend.default.svc:8080"`, pointing to the `default` namespace instead of `debug-lab`.

**Fix:**
Updated `BACKEND_URL` in `broken-chart/values.yaml` to `"http://backend:8080"` so DNS resolves within the release namespace (`debug-lab`).

**How I found it:**
Inspected `gateway` environment variables in `values.yaml` and verified in-cluster service DNS.

---

## Defect 4: `worker` failing to write to read-only root filesystem

**Symptom:**
`worker` pod crashed/failed because it could not write to `/var/cache/app`.

**Cause:**
`broken-chart/templates/worker.yaml` sets `readOnlyRootFilesystem: true` without mounting a writable volume at `/var/cache/app`.

**Fix:**
Added an `emptyDir` volume (`cache`) mounted at `/var/cache/app` in `broken-chart/templates/worker.yaml`, preserving `readOnlyRootFilesystem: true` instead of weakening security.

**How I found it:**
Checked `worker` pod logs and `worker.yaml` `securityContext`.

---

## Defect 5: `metrics` CPU requests/limits exceed namespace `LimitRange`

**Symptom:**
`metrics` Deployment failed to create pods because the `debug-lab-guardrails` `LimitRange` rejected the container's CPU request/limit.

**Cause:**
`broken-chart/values.yaml` requested `cpu: "2"` and limited `cpu: "4"` for `metrics`, violating `cluster-state/limits.yaml` (`max.cpu: "1"`).

**Fix:**
Adjusted `metrics.resources` in `broken-chart/values.yaml` to `requests.cpu: "50m"` and `limits.cpu: "200m"` to match the other workloads and stay within the `LimitRange`.

**How I found it:**
Checked ReplicaSet events (`kubectl -n debug-lab describe rs`) and compared against `cluster-state/limits.yaml`.

---

## Defect 6: `reporter` RBAC RoleBinding bound to `default` ServiceAccount (+ upstream image bug)

**Symptom:**
Initially, `ServiceAccount debug-lab/reporter` could not list pods. After fixing RBAC, `deployment/reporter` remained `0/1 Ready` with readiness probe `503 Service Unavailable`, and both `/healthz` and `/report` returned:

    {"error":"parse pod list: unexpected end of JSON input","status":"unhealthy"}

**Cause:**
1. **Chart defect:** `broken-chart/templates/rbac.yaml` bound `Role/reporter-read` to `ServiceAccount/default` instead of `ServiceAccount/reporter`.
2. **Upstream image defect (`eb-debug-app:1.0.1`):** Even with valid RBAC, `eb-debug-app:1.0.1` has a hardcoded response-body read cap below **4,082 bytes** when parsing `GET https://kubernetes.default.svc/api/v1/namespaces/debug-lab/pods?limit=100`. The Kubernetes API returns a valid `HTTP 200` `PodList` of **47,959 bytes**, which the binary truncates mid-JSON.

**Fix:**
1. Updated `broken-chart/templates/rbac.yaml` `RoleBinding` subject from `name: default` to `name: reporter` (`kubectl auth can-i list pods` now passes).
2. Left `image.repository` and `image.tag` untouched per lab rules; fixing the JSON truncation requires an upstream image fix (raising/removing the response read limit or streaming the JSON decode).

**How I found it:**
1. Verified `kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter` and fixed `rbac.yaml`.
2. Tested `https://kubernetes.default.svc/api/v1/namespaces/debug-lab/pods?limit=100` from an in-cluster `curl` pod using `serviceAccountName: reporter` and `-A "Go-http-client/2.0"` — confirmed `HTTP_CODE:200 SIZE:47959` with valid JSON.
3. Ruled out HTTP/2 framing (`GODEBUG=http2client=0`), NetworkPolicies, and Service configuration.
4. Isolated `eb-debug-app:1.0.1` in Docker against a local HTTPS mock `kubernetes.default.svc`: a **37-byte** `PodList` returned `HTTP/1.1 200 OK` (`{"namespace":"debug-lab","pod":"d2f044d14dd2","pods":1}`), while a **4,082-byte** `PodList` immediately reproduced `{"error":"parse pod list: unexpected end of JSON input","status":"unhealthy"}`.

---

## Remaining / Unresolved Notes

`./scenario.sh verify` passes **9/11** checks. The only 2 failing checks (`deployment reporter: 0/1 ready` and `reporter /report does not return a pod count`) are caused by the hardcoded <4 KB response truncation bug in `docker.io/ebinterview/eb-debug-app:1.0.1`, which cannot be resolved without modifying the container image.
