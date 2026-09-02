# Failure Exercise D — Broken Release / Rollback (PrometheusTargetDown)

## Objective

Simulate a broken release being deployed, confirm that monitoring detects
it, and roll back using the exact recovery procedure `Jenkinsfile-cd`
itself documents on failure — then confirm the alert clears. This is the
one exercise that exercises `prometheus/rules/monitoring-alerts.yaml`,
the only rule file not yet covered by exercises (a)–(c).

Target: the `PrometheusTargetDown` alert:

```yaml
- alert: PrometheusTargetDown
  expr: |
    up == 0
  for: 5m
  labels:
    severity: critical
    category: monitoring-system
```

## Design Rationale

The obvious "break the release" approach — reusing the Postgres-dependency
break from exercise (a) — was deliberately rejected. Looking back at
`app.py`, database errors are caught and re-raised only inside specific
route handlers (e.g. `/api/records`); the Flask process itself still
starts and serves `/api/health` fine even with Postgres down. That means a
DB break leaves the scrape target reachable (`up` stays `1`) and would
only ever re-trigger `HighErrorRate`, which exercise (a) already covers.

To trip `PrometheusTargetDown` specifically, the container's HTTP
server(s) need to be genuinely unreachable — a real crash, not just bad
responses. The chosen method, consistent with the "config-independent,
guaranteed-to-fail" approach used in exercises (b) and (c): override the
backend container's `command` to exit immediately, forcing
`CrashLoopBackOff` regardless of anything inside the image or its config.
This simulates "a release got deployed that won't even start" and ties
directly into `Jenkinsfile-cd`'s own `post { failure { ... } }` block,
which prints exactly this recovery command on CD failure:

```
kubectl rollout undo deployment/backend -n devops-app
kubectl rollout undo deployment/worker -n devops-app
```

## Method

1. **Baseline check.** Confirmed `ALERTS{alertname="PrometheusTargetDown"}`
   was empty, `up{job="devops-app/backend"}` read `1`, and checked
   `kubectl rollout history deployment/backend` showed a healthy chain of
   prior revisions to roll back to.
2. **Break the release.**
```bash
   kubectl patch deployment backend -n devops-app -p \
     '{"spec":{"template":{"spec":{"containers":[{"name":"backend","command":["/bin/sh","-c","echo BROKEN-RELEASE-SIMULATION - exiting immediately; exit 1"]}]}}}}'
```
   This triggered a new ReplicaSet whose pod immediately entered
   `CrashLoopBackOff`.
3. **Rolling-update behavior (same pattern as exercise b).** Because
   `replicas: 1` uses the default rolling-update strategy
   (`maxUnavailable: 0`), the *old* healthy pod
   (`backend-97cc47f98-4jzgk`) kept running as a surge companion, so
   `kubectl get deployment backend` still showed `READY 1/1`. This did
   **not** block the exercise, though, because `up == 0` is evaluated
   per scrape target (per pod instance), not as an aggregate replica
   count: the new broken pod (`backend-56588f64db-ctjx4`) is its own
   distinct Prometheus target and correctly reported `up=0` on its own,
   independent of the old pod's health. Confirmed via a direct query
   showing both series side by side (old pod `up=1`, new pod `up=0`).
4. **Observe detection.** Watched
   `ALERTS{alertname="PrometheusTargetDown"}` transition
   `(absent) → pending → firing`, matching `for: 5m` almost exactly
   (pending at `19:54:46`, firing confirmed at `19:59:53`,
   `startsAt: 2026-09-02T19:54:48.237Z` in Alertmanager).
5. **Capture firing-state evidence.** Queried the Alertmanager API, the
   Prometheus `ALERTS` and `up{}` queries, `kubectl` pod/deployment state
   (`CrashLoopBackOff` visible), the demo receiver webhook log, and a
   screenshot of Prometheus's own Targets page (Status → Targets),
   showing `1/2 up` with the broken target's scrape error:
   `dial tcp 10.42.0.87:9000: connect: connection refused`.
6. **Roll back.** Ran the exact command `Jenkinsfile-cd` documents:
   `kubectl rollout undo deployment/backend -n devops-app`. Kubectl
   warned that the Deployment "was previously managed with `kubectl
   apply`" and that rolling back wouldn't update the
   `last-applied-configuration` annotation — expected and harmless here,
   since the break was applied directly via `kubectl patch` rather than
   through a real CD run, and the source manifest in Git was never
   touched, so a future `kubectl apply -f` from the repo still applies
   cleanly.
7. **Confirm recovery.** `kubectl rollout status` reported success; the
   broken ReplicaSet's pod was torn down entirely, leaving only the
   original healthy pod.
8. **Capture resolved-state evidence.** Confirmed the alert cleared
   (the broken target's series disappeared outright, since that pod no
   longer exists, rather than flipping to a resolved state in place);
   re-queried Prometheus/Alertmanager (both clear); captured the resolved
   webhook and a fresh Targets-page screenshot showing `1/1 up`.

## Recovery Confirmation

- `kubectl get pods -n devops-app -l app=backend` → single pod,
  `1/1 Running`.
- `up{job="devops-app/backend"}` → single series, `value: 1`.
- `ALERTS{alertname="PrometheusTargetDown"}` → empty result set.
- Alertmanager `/api/v2/alerts` filtered to `PrometheusTargetDown` → `[]`.
- Demo receiver log confirmed the resolved webhook delivery:
  - `"status":"resolved"`
  - `"notification_reason":"all alerts resolved"`
  - `startsAt: 2026-09-02T19:54:48.237Z`
  - `endsAt: 2026-09-02T20:00:18.237Z` (fired for ~5.5 minutes)
- Prometheus Targets page showed `1/1 up` for
  `podMonitor/devops-app/backend/0`.

## Evidence Files

| File | Description |
|---|---|
| `01-alertmanager-active-alerts.json` | Alertmanager `/api/v2/alerts` filtered to `PrometheusTargetDown` while firing |
| `02-prometheus-alert-firing.json` | Prometheus `ALERTS{alertname="PrometheusTargetDown"}` showing `alertstate="firing"` |
| `03-kubectl-and-target-state.txt` | `kubectl get pods/deployment` (CrashLoopBackOff visible) plus the `up{}` query showing both the healthy and broken target side by side |
| `04-demo-receiver-log-firing.txt` | Raw webhook POST body confirming `"status":"firing"`, `"notification_reason":"first notification"` |
| `05-prometheus-targets-firing.png` | Prometheus Targets page: `1/2 up`, broken target red with `connection refused` scrape error |
| `06-alertmanager-resolved.json` | Alertmanager query filtered to `PrometheusTargetDown`, confirming `[]` after rollback |
| `07-demo-receiver-resolved.txt` | Raw webhook POST body confirming `"status":"resolved"`, `"notification_reason":"all alerts resolved"` |
| `08-prometheus-targets-resolved.png` | Prometheus Targets page: `1/1 up`, clean recovery |