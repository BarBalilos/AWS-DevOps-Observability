# Failure Exercise B — Pod Delete / Readiness Break (ReplicasMismatch)

## Objective

Trigger a real, sustained mismatch between desired and available replicas
on a Deployment, and confirm that the monitoring stack detects, alerts on,
notifies, and later confirms recovery from the incident — end to end,
using only evidence pulled from live systems.

This exercise targets the `ReplicasMismatch` alert, defined in
`prometheus/rules/kubernetes-alerts.yaml`:

```yaml
- alert: ReplicasMismatch
  expr: |
    kube_deployment_status_replicas_available{namespace="devops-app"}
    != kube_deployment_spec_replicas{namespace="devops-app"}
  for: 10m
  labels:
    severity: critical
    category: k8s
```

Target: the `frontend` Deployment (`replicas: 1`, `nginxinc/nginx-unprivileged:alpine`
+ `nginx-exporter` sidecar, readiness probe `httpGet: path=/, port=8080`).

## Method

1. **Baseline check.** Confirmed no `ReplicasMismatch` alert was active:
   `ALERTS{alertname="ReplicasMismatch"}` returned an empty result set.
   Noted the healthy pod (`frontend-657b77bb9b-tjfw2`, `2/2 Ready`) and its
   ReplicaSet.
2. **First break attempt (did not work — documented as a real finding).**
   Patched the readiness probe's `httpGet.path` to a nonexistent path
   (`/this-path-does-not-exist-404`) via `kubectl patch`. The resulting
   rollout produced a new pod that came up **2/2 Ready** — the probe did
   *not* fail. This revealed that the frontend's nginx config serves a
   catch-all fallback (consistent with a SPA `try_files` pattern) that
   returns HTTP 200 for any unmatched path, so a path-based probe break is
   not a reliable failure trigger for this app without inspecting
   `nginx.conf` directly.
3. **Second break attempt (worked).** Patched the readiness probe's
   `httpGet.port` to `9999` — a port nothing listens on, guaranteed to fail
   with connection-refused regardless of nginx's config content. The
   `livenessProbe` was left pointed at the correct port 8080/`/`, so the
   container stayed `Running`, just permanently `NotReady`.
4. **Rolling-update behavior (a second real finding).** After the patch,
   Kubernetes' default rolling-update strategy (`maxSurge: 25%` → 1,
   `maxUnavailable: 25%` → 0 for a single-replica Deployment) kept the
   *old* healthy pod running alongside the new broken one rather than
   replacing it — so `availableReplicas` stayed at `1`, matching
   `spec.replicas: 1`, and no mismatch occurred yet. Deleting the old pod
   directly would not have helped either, since its ReplicaSet controller
   would simply recreate it to satisfy its own desired count.
5. **Force the mismatch.** Identified the old ReplicaSet
   (`frontend-64df8fb595`) via `kubectl get rs` and scaled it directly to
   zero: `kubectl scale rs frontend-64df8fb595 -n devops-app --replicas=0`.
   This removed the last available replica without triggering recreation,
   leaving only the new broken pod (`frontend-c6c46b5c6-qdlfv`, `1/2
   Ready`). Confirmed via `kubectl get deployment frontend`: `READY 0/1`,
   `AVAILABLE 0`.
6. **Observe detection.** Watched `ALERTS{alertname="ReplicasMismatch"}`
   transition `(absent) → pending → firing`, matching the rule's `for: 10m`
   almost exactly (pending observed at `t+0`, firing confirmed at
   `t+10m14s`).
7. **Capture firing-state evidence.** Queried the Alertmanager API, the
   Prometheus `ALERTS` query, `kubectl` state (`deployment`/`pods`/`rs`),
   the raw webhook delivered to the demo receiver, and Grafana's
   "Kubernetes / Cluster" dashboard.
8. **Revert.** Patched the readiness probe's port back to `8080`. The
   Deployment converged directly back onto the *original* ReplicaSet
   (`frontend-657b77bb9b`) since the reverted pod spec was byte-identical
   to it — a clean full revert with no leftover broken ReplicaSet.
9. **Capture resolved-state evidence.** Confirmed `READY 1/1`, `AVAILABLE
   1`; re-queried Prometheus/Alertmanager (both empty); captured the
   resolved webhook and fresh Grafana screenshots.

## Additional Findings

- **Rolling-update mechanics matter when designing infra failure tests.**
  For a `replicas: 1` Deployment, a probe break alone does not reduce
  `availableReplicas` below `spec.replicas` — Kubernetes deliberately keeps
  the last healthy pod running until a replacement passes readiness. A
  reduction in available replicas that is genuinely sustained (not a normal
  rollout blip) requires either killing an existing healthy replica outside
  of a rollout, or scaling the outgoing ReplicaSet directly, as done here.
- **The frontend's nginx config has a catch-all fallback route** that
  returns HTTP 200 for arbitrary paths, so path-based readiness breaks are
  not reliable for this service; a connection-level break (wrong port) is.
- **One root cause tripped three alerts.** In addition to our custom
  `ReplicasMismatch`, the stock kube-state-metrics-mixin rules
  `KubePodNotReady` (warning, 15m) and `KubeDeploymentReplicasMismatch`
  (warning, 15m) also fired from the same underlying condition — useful
  independent corroboration that kube-state-metrics and the built-in
  alerting rules are wired correctly, beyond the rule this exercise
  targeted.

## Recovery Confirmation

- `kubectl get deployment frontend -n devops-app` → `READY 1/1`,
  `AVAILABLE 1`.
- `ALERTS{alertname="ReplicasMismatch"}` → empty result set.
- Alertmanager `/api/v2/alerts` filtered to `ReplicasMismatch` → `[]`.
- Demo receiver log confirmed the resolved webhook delivery:
  - `"status":"resolved"`
  - `"notification_reason":"all alerts resolved"`
  - `startsAt: 2026-09-02T18:28:48.772Z`
  - `endsAt: 2026-09-02T18:37:18.772Z` (fired for ~8.5 minutes)
- Grafana's "Kubernetes / Cluster" dashboard showed the Deployment
  Replicas panel back to a full desired/available match and the Active
  Kubernetes Alerts table showing "No data".

## Evidence Files

| File | Description |
|---|---|
| `01-alertmanager-active-alerts.json` | Alertmanager `/api/v2/alerts` response while `ReplicasMismatch` was firing (also shows expected k3s non-issue alerts: `KubeControllerManagerDown`/`KubeProxyDown`/`KubeSchedulerDown`/`Watchdog`) |
| `02-prometheus-alert-firing.json` | Prometheus `ALERTS{alertname="ReplicasMismatch"}` query result showing `alertstate="firing"` |
| `03-kubectl-deployment-state.txt` | `kubectl get deployment/pods/rs` output during the incident: `READY 0/1`, `AVAILABLE 0`, broken pod at `1/2 Ready` |
| `04-demo-receiver-log-firing.txt` | Raw webhook POST body confirming `"status":"firing"`, `"notification_reason":"first notification"` |
| `05-grafana-dashboard-firing-top.png` | Kubernetes / Cluster dashboard (top): Node status, Pod Count, **Deployment Replicas: Desired vs Available** showing the gap |
| `05-grafana-dashboard-firing-bottom.png` | Kubernetes / Cluster dashboard (bottom): **Active Kubernetes Alerts** table showing `ReplicasMismatch` firing |
| `06-alertmanager-resolved.json` | Alertmanager query filtered to `ReplicasMismatch`, confirming `[]` after recovery |
| `07-demo-receiver-resolved.txt` | Raw webhook POST body confirming `"status":"resolved"`, `"notification_reason":"all alerts resolved"` |
| `08-grafana-dashboard-resolved-top.png` | Kubernetes / Cluster dashboard (top): Deployment Replicas panel back to full match |
| `08-grafana-dashboard-resolved-bottom.png` | Kubernetes / Cluster dashboard (bottom): Active Kubernetes Alerts table showing "No data" |