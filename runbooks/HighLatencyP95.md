# HighLatencyP95

**Severity:** warning
**Category:** app
**Fires when:** `slo:http_latency_500ms_ratio:rate5m < 0.95` for 5 minutes

## What this means
Fewer than 95% of requests served by `{{ $labels.job }}` (backend or worker)
completed within 500ms over the trailing 5-minute window. This is the app
Latency SLO being breached.

## Immediate checks
```bash
kubectl top pods -n devops-app
kubectl logs -n devops-app deploy/backend --tail=100
kubectl logs -n devops-app deploy/worker --tail=100
```
- Check CPU/memory usage against requests/limits — throttling causes latency spikes.
- Check Postgres query latency (slow queries, missing indexes, lock contention).
- Check for a traffic spike beyond normal load in `http_requests_total` rate.

## Likely causes
- CPU throttling from limits set too low for current load.
- Slow downstream calls (database, worker queue).
- Node under resource pressure (see `NodeNotReadyOrPressure`).
- A regression in a recent release adding expensive work to the request path.

## Rollback
If a recent deploy is the cause, roll back to the last known-good image digest
(from the Jenkins-archived `image-metadata.json` build artifact):
```bash
kubectl set image deployment/backend backend=<ECR_REPO_URI>@<previous-digest> -n devops-app
kubectl rollout status deployment/backend -n devops-app
```

## Resolution
Once the root cause is fixed or rolled back, confirm recovery:
```promql
slo:http_latency_500ms_ratio:rate5m
```
should be back above `0.95`. The alert clears automatically once the ratio
stays above threshold for the full 5-minute `for` window.