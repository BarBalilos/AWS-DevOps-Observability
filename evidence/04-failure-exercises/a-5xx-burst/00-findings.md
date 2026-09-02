# Failure Exercise A — 5xx Burst (Backend → Postgres Dependency Break)

## Objective

Trigger a real, sustained increase in HTTP 5xx responses from the `backend`
service by deliberately breaking its dependency on Postgres, and confirm
that the monitoring stack detects, alerts on, notifies, and later confirms
recovery from the incident — end to end, using only evidence pulled from
live systems (Prometheus, Alertmanager, the demo receiver, and Grafana).

This exercise targets the `HighErrorRate` alert, defined in
`prometheus/rules/app-alerts.yaml`:

```yaml
- alert: HighErrorRate
  expr: slo:http_availability_ratio:rate5m < 0.99
  for: 5m
  labels:
    severity: critical
    category: app
```

which depends on the recording rule in
`prometheus/rules/slo-recording-rules.yaml`:

```yaml
- record: slo:http_availability_ratio:rate5m
  expr: >
    sum(rate(http_requests_total{status!~"5.."}[5m])) by (job)
    /
    sum(rate(http_requests_total[5m])) by (job)
```

Because this ratio is aggregated `by (job)`, breaking only the backend's
Postgres dependency isolates the impact to `job="devops-app/backend"`
without affecting `devops-app/worker` or `devops-app/frontend`.

## Method

1. **Baseline check.** Confirmed no `HighErrorRate` alert was active:
   `ALERTS{alertname="HighErrorRate"}` returned an empty result set.
2. **Break the dependency.** Scaled Postgres to zero replicas:
   `kubectl scale deployment/postgres --replicas=0 -n devops-app`. Confirmed
   the pod reached `Completed`/terminated via
   `kubectl get pods -n devops-app -l app=postgres`.
3. **Generate load.** Since the `backend`/`worker` containers (built on
   `python:3.11-slim`) have no `curl`/`wget`, load was generated with:
   `kubectl exec <backend-pod> -n devops-app -- python3 -c "..."` running a
   loop of `urllib.request.urlopen(...)` against `GET /api/records` with a
   1-second sleep between requests, for 720 iterations (~12 minutes). Every
   request failed with `HTTP Error 500` once Postgres was unreachable, since
   `list_records()` raises uncaught on any Postgres connection/query error
   (caught generically by Flask's `handle_exception`, which still runs the
   `@app.after_request` metrics hook, so every 500 was correctly counted in
   `http_requests_total`).
4. **Observe detection.** Watched `slo:http_availability_ratio:rate5m` for
   `job="devops-app/backend"` drop from `1.0` to `~0.13` within about two
   minutes (the app's background traffic is sparse, so injected failures
   dominated the 5-minute rate window almost immediately). Watched
   `ALERTS{alertname="HighErrorRate"}` transition `inactive → pending →
   firing`.
5. **Capture firing-state evidence.** Queried the Alertmanager API
   (`GET /api/v2/alerts`), the raw webhook body delivered to the demo
   receiver pod (`kubectl logs -n observability -l
   app=alertmanager-demo-receiver`), Prometheus instant queries for the
   ratio and alert state, and Grafana dashboard screenshots.
6. **Restore the dependency.** Scaled Postgres back to one replica:
   `kubectl scale deployment/postgres --replicas=1 -n devops-app`, confirmed
   `Running` via `kubectl rollout status` / `kubectl get pods`.
7. **Generate recovery load and capture resolved-state evidence.** Re-ran a
   healthy-request burst (360 iterations, 1s sleep) against `/api/records`,
   watched the ratio climb back toward `1.0` and the alert transition
   `firing → resolved`, then re-queried the Alertmanager API, the demo
   receiver log, and Grafana.

## Unexpected Finding: Postgres Has No Persistent Storage

After scaling Postgres back up in step 6, `/api/records` continued to fail
— but with a **different** error:
`psycopg2.errors.UndefinedTable: relation "records" does not exist`,
confirmed identically in both the `postgres` pod's own logs
(`ERROR: relation "records" does not exist`) and the `backend` pod's logs
(full Python traceback via `kubectl logs -n devops-app <backend-pod>`).

**Root cause:** `k8s/03-postgres-deployment.yaml` defines no `volumes` or
`volumeMounts` anywhere in the pod spec. Postgres's data directory lives
entirely in the container's ephemeral writable layer. There is also no
init-container, ConfigMap-mounted SQL, or migration tool that recreates the
schema on startup. The `records` table had been created manually/out-of-band
at some earlier point (DB: `appdb`, user: `appadmin`), so scaling the
Deployment to zero replicas and back to one permanently destroyed it — this
is a genuine, previously-undiscovered infrastructure gap, not an artifact of
this exercise.

**Fix applied (for evidence-capture purposes only, root cause left in
place and documented rather than silently worked around):**

```sql
CREATE TABLE IF NOT EXISTS records (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL
);
```

run via `kubectl exec <postgres-pod> -n devops-app -- psql -U appadmin -d
appdb -c "..."`, confirmed present via `\dt`.

**Recommended production fix (out of scope for this assignment):** add a
`PersistentVolumeClaim` + `volumeMounts` to `03-postgres-deployment.yaml`
so `PGDATA` survives pod rescheduling, and introduce a real migration
mechanism (init container or a migration tool such as `flyway`/`alembic`)
so schema state is reproducible from code rather than created manually.

## Recovery Confirmation

After recreating the table and re-running the healthy-request burst:

- `slo:http_availability_ratio:rate5m{job="devops-app/backend"}` climbed
  `0.32 → 0.59 → 1.0`.
- `ALERTS{alertname="HighErrorRate"}` returned to an empty result set.
- Alertmanager's `/api/v2/alerts` returned `[]` — no active alerts.
- The demo receiver's log showed the resolved webhook delivery for
  `HighErrorRate`:
  - `"status":"resolved"`
  - `"notification_reason":"all alerts resolved"`
  - `startsAt: 2026-09-02T17:55:29.531Z`
  - `endsAt: 2026-09-02T18:00:59.531Z`
- The Grafana "Application Overview" dashboard showed both SLO gauges back
  to green at 100%, and the Active App Alerts table showing "No data".

## Evidence Files

| File | Description |
|---|---|
| `01-alertmanager-active-alerts.json` | Alertmanager `/api/v2/alerts` response while `HighErrorRate` was firing |
| `02-demo-receiver-log-highrateerror.txt` | Raw webhook POST body received by the demo receiver, confirming `"status":"firing"`, `"notification_reason":"first notification"` |
| `03-availability-ratio-during-firing.json` | Prometheus instant query result for `slo:http_availability_ratio:rate5m` during the incident |
| `04-prometheus-alert-firing.json` | Prometheus `ALERTS{alertname="HighErrorRate"}` query result showing `state="firing"` |
| `05-grafana-dashboard-firing-top.png` | Application Overview dashboard (top): Service Info, SLO gauges (Availability red, ~13%), Request Rate / Error Rate / P95 Latency |
| `05-grafana-dashboard-firing-bottom.png` | Application Overview dashboard (bottom): Business Metrics, Active App Alerts table showing `HighErrorRate` firing |
| `06-alertmanager-resolved.json` | Alertmanager `/api/v2/alerts` response after recovery, confirming `[]` (no active alerts) |
| `07-demo-receiver-resolved.txt` | Raw webhook POST body confirming `"status":"resolved"`, `"notification_reason":"all alerts resolved"` for `HighErrorRate` |
| `08-grafana-dashboard-resolved-top.png` | Application Overview dashboard (top): both SLO gauges green at 100%, Request Rate / Error Rate / P95 Latency / Dependency Errors showing the full incident-then-recovery shape |
| `08-grafana-dashboard-resolved-bottom.png` | Application Overview dashboard (bottom): Business Metrics, Active App Alerts table showing "No data" (alert cleared) |