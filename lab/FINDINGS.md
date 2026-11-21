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

## Defect 6: reporter (partly fixed, one symptom unresolved)

**Symptom:**
Reporter pod logs (`kubectl logs`):

    pod list failed: parse pod list: unexpected end of JSON input
    GET /healthz -> 503

The pod stays 0/1 Ready with 0 restarts. `./scenario.sh verify`, run twice on 21 Nov with the same result:

      PASS  migrate Job completed
      PASS  deployment backend: 1/1 ready
      PASS  deployment gateway: 1/1 ready
      PASS  deployment worker: 1/1 ready
      FAIL  deployment reporter: 0/1 ready
      PASS  deployment metrics: 1/1 ready
      PASS  no pods in CrashLoopBackOff
      PASS  ServiceAccount debug-lab/reporter can list pods
      PASS  backend answers on http://backend:8080/healthz
      PASS  gateway /status reports backend=ok
      FAIL  reporter /report does not return a pod count
    2 check(s) failing, 9 passing. Keep digging — every failure is a symptom.

**Cause (fixed part):** the RoleBinding subject in `rbac.yaml` was the `default`
ServiceAccount, not `reporter`.

**Fix:** subject `name: reporter`. `kubectl auth can-i list pods` now says yes and that check passes.

**Unresolved:** I did not find why `/report` still fails. I do not know the cause.

Ruled out, each with a test:

| Hypothesis | Test | Result |
|---|---|---|
| RBAC | `can-i`; fetched the pod list as the reporter's ServiceAccount | allowed, full body |
| Crash / OOM | pod restarts | 0 restarts |
| Network path | request from inside the pod network | 200 with a full body |
| CPU / memory limits | raised to 500m / 256Mi, waited 3+ min | same error; reverted |
| Pod-list size | scratch namespace, one reporter pod, 7,329 bytes | same error; also fails at 41 KB and 83 KB |
| Writable volume | emptyDir at /var/cache/app | same error |

Side observation, not evidence: a local mock API returned a 37-byte list (accepted) and
a 4,082-byte list (failed). The real one-pod list is over 7 KB and the mock may differ from the
real API, so I do not conclude the app has a size cap.

**How I found it / what I would try next:** the RBAC fix came from `can-i`. For the rest I
worked down the table above. Next I would capture the app's real request and response with a
logging proxy, test an older kind node image (mine is v1.34.0), and ask the author about
known issues with eb-debug-app:1.0.1 in reporter mode.
