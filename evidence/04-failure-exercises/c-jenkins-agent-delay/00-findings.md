# Failure Exercise C — Jenkins Agent Delay / Queue Backlog (JenkinsQueueStuck)

## Objective

Trigger a real, sustained Jenkins build queue backlog and confirm that the
monitoring stack detects, alerts on, notifies, and later confirms recovery
from the incident — end to end, using only evidence pulled from live
systems. This exercise also surfaced and fixed two real bugs along the way
(documented below), which is itself part of the value of running it.

Target: the `JenkinsQueueStuck` alert, defined in
`prometheus/rules/jenkins-alerts.yaml`:

```yaml
- alert: JenkinsQueueStuck
  expr: |
    jenkins_queue_size_value > 3
  for: 10m
  labels:
    severity: warning
    category: jenkins
```

## Bug Found and Fixed #1: Wrong Metric Name in the Alert Rule

Before running the exercise, a baseline query of
`default_jenkins_queue_size_value` (the metric name originally in the rule)
returned an empty result. Cross-checking the full list of scraped Jenkins
metric names (`/api/v1/label/__name__/values`) showed two separate naming
families are active — `default_jenkins_*` (builds, executors, nodes) and
plain `jenkins_*` (queue, health checks, tasks) — apparently from two
different Jenkins Prometheus exporters/plugins both running. The rule had
mixed the conventions: `queue_size_value` belongs to the un-prefixed
family. As written, `default_jenkins_queue_size_value > 3` could never
fire, since it always evaluated against an absent series.

**Fix:** changed the rule's `expr` to `jenkins_queue_size_value > 3` and
reapplied via `kubectl apply -f prometheus/rules/` (the same mechanism
`scripts/install.sh` uses), confirmed the metric now resolves to a real
value.

## Bug Found and Fixed #2: Same Wrong Metric Name in the Dashboard

The "Jenkins & Delivery" dashboard's **Build Queue Length (alert
threshold: 3)** panel had the identical mistake in
`grafana/dashboards/jenkins-delivery.json`, querying
`default_jenkins_queue_size_value` and showing "No data" even while the
real queue sat at 4 and the alert was actively firing.

**Fix:** changed the panel's `expr` to `jenkins_queue_size_value`,
reapplied via the same ConfigMap-provisioning pattern
`scripts/install.sh` uses:
`kubectl create configmap grafana-dashboard-jenkins-delivery --from-file=... --dry-run=client -o yaml | kubectl apply -f -`.
Confirmed the panel then rendered the real queue spike.

## Secondary Finding (Deferred, Not Fixed)

The **Build Success Rate** panel also showed "No data" throughout this
exercise. Unlike the queue metric, its underlying metric names
(`default_jenkins_builds_success_build_count_total`,
`default_jenkins_builds_total_build_count_total`) are real — they appear in
the scraped metrics list — but direct instant queries for both returned
empty result sets at the time of testing, suggesting these particular
per-job counters currently aren't emitting fresh samples (possibly related
to the multiple Jenkins controller pod restarts performed earlier in this
project, which may reset in-memory metric state). Not fixed as part of
this exercise since it's unrelated to `JenkinsQueueStuck`; flagged for
follow-up investigation during final documentation.

## Method

1. **Baseline check.** Confirmed `jenkins_queue_size_value` (post-fix)
   read `0` and `ALERTS{alertname="JenkinsQueueStuck"}` was empty.
2. **Block all agent capacity.** Cordoned both cluster nodes (`agent-0`
   and `server-0` — confirmed neither carries a taint, so both are
   normally schedulable and both needed cordoning):
   `kubectl cordon k3d-devops-k8s-agent-0` /
   `kubectl cordon k3d-devops-k8s-server-0`.
3. **Queue more than 3 builds.** Jenkins coalesces duplicate queued builds
   of the same job with identical parameters, so simply clicking "Build
   Now" repeatedly on the same job wouldn't stack up separate queue
   entries. Used the parameterized `application-cd` job instead, and
   submitted 4 "Build with Parameters" requests with distinct `IMAGE_TAG`
   values (`queue-test-1` through `queue-test-4`), which Jenkins treats as
   4 distinct, non-coalescing queue items.
4. **Unexpected early build.** One build (`#24`) started running almost
   immediately despite the cordon, because an agent pod from earlier
   testing was still alive under the pod template's `idleMinutes: 5`
   setting and got reused — cordoning blocks *new* pod scheduling, not
   reuse of an already-running pod. Once `#24` finished and its pod was
   torn down (`podRetention: never`), the remaining queued builds could no
   longer acquire any agent, and the backlog became genuine.
5. **Observe detection.** Confirmed `jenkins_queue_size_value` reached `4`
   and watched `ALERTS{alertname="JenkinsQueueStuck"}` transition
   `(absent) → pending → firing`, matching `for: 10m` almost exactly
   (pending at `19:02:05`, firing confirmed at `19:12:39`, corresponding
   to `startsAt: 2026-09-02T19:12:05.971Z` in Alertmanager).
6. **Capture firing-state evidence.** Queried the Alertmanager API, the
   Prometheus `ALERTS` query, queue/node `kubectl` state, the demo
   receiver webhook log, a screenshot of the Jenkins queue page (4 stuck
   items), and the (now-fixed) Grafana dashboard.
7. **Revert.** Uncordoned both nodes:
   `kubectl uncordon k3d-devops-k8s-agent-0` /
   `kubectl uncordon k3d-devops-k8s-server-0`.
8. **Observe drain.** A new `cd-agent` pod's `Pod` object had actually
   been created (and sat `Pending`) during the cordoned window — its
   `AGE` at uncordon time already reflected several minutes, confirming it
   had been waiting the whole time, not freshly created. Once
   unblocked, it scheduled immediately and claimed the first queued
   build; the queue then drained fully to `0` within about a minute
   (`disableConcurrentBuilds()` meant the four `application-cd` builds
   ran one after another, though with dummy `IMAGE_TAG` values they
   likely failed fast at an early validation stage — visible afterward as
   a temporary dip in `application-cd`'s Build Health Score panel, an
   expected side effect of the test data, not a new issue).
9. **Capture resolved-state evidence.** Confirmed the alert cleared
   immediately once queue size dropped ≤3 (resolution has no `for`
   delay); re-queried Prometheus/Alertmanager (both empty); captured the
   resolved webhook and fresh Grafana screenshots.

## Recovery Confirmation

- `jenkins_queue_size_value` → `0`.
- `ALERTS{alertname="JenkinsQueueStuck"}` → empty result set.
- Alertmanager `/api/v2/alerts` filtered to `JenkinsQueueStuck` → `[]`.
- Demo receiver log confirmed the resolved webhook delivery:
  - `"status":"resolved"`
  - `"notification_reason":"all alerts resolved"`
  - `startsAt: 2026-09-02T19:12:05.971Z`
  - `endsAt: 2026-09-02T19:28:05.971Z` (fired for ~16 minutes)
- Grafana's Build Queue Length panel showed the spike returning to 0, and
  the Active Jenkins Alerts table showed "No data".

## Evidence Files

| File | Description |
|---|---|
| `01-alertmanager-active-alerts.json` | Alertmanager `/api/v2/alerts` filtered to `JenkinsQueueStuck` while firing |
| `02-prometheus-alert-firing.json` | Prometheus `ALERTS{alertname="JenkinsQueueStuck"}` showing `alertstate="firing"` |
| `03-queue-and-node-state.txt` | `jenkins_queue_size_value` reading plus `kubectl get nodes` during the incident |
| `04-demo-receiver-log-firing.txt` | Raw webhook POST body confirming `"status":"firing"`, `"notification_reason":"first notification"` |
| `05-jenkins-queue-firing.png` | Jenkins UI "Build Queue (4)" panel showing all four stuck `application-cd` builds |
| `06-grafana-dashboard-firing-top.png` | Jenkins & Delivery dashboard (top), Build Queue Length panel showing the real spike to 4 (post-fix) |
| `06-grafana-dashboard-firing-bottom.png` | Jenkins & Delivery dashboard (bottom), Active Jenkins Alerts table showing `JenkinsQueueStuck` firing |
| `07-alertmanager-resolved.json` | Alertmanager query filtered to `JenkinsQueueStuck`, confirming `[]` after recovery |
| `08-demo-receiver-resolved.txt` | Raw webhook POST body confirming `"status":"resolved"`, `"notification_reason":"all alerts resolved"` |
| `09-grafana-dashboard-resolved-top.png` | Dashboard (top): Build Queue Length back to 0 |
| `09-grafana-dashboard-resolved-bottom.png` | Dashboard (bottom): Active Jenkins Alerts showing "No data" |