# HighErrorRate

**Severity:** critical
**Category:** app
**Fires when:** `slo:http_availability_ratio:rate5m < 0.99` for 5 minutes

## What this means
Less than 99% of requests served by `{{ $labels.job }}` (backend or worker) over
the trailing 5-minute window returned a non-5xx status. This is the app
Availability SLO being breached.

## Immediate checks
```bash
kubectl get pods -n devops-app -o wide
kubectl logs -n devops-app deploy/backend --tail=100
kubectl logs -n devops-app deploy/worker --tail=100
kubectl get events -n devops-app --sort-by=.lastTimestamp | tail -20
```
- Check whether errors correlate with a recent deploy (compare timestamp against the last Jenkins CD run).
- Check Postgres connectivity from the backend logs (connection refused/timeout errors).
- Check pod resource usage (`kubectl top pods -n devops-app`) for OOM/CPU throttling.

## Likely causes
- A bad release introduced a bug (unhandled exception, broken dependency call).
- Database unavailable or connection pool exhausted.
- Downstream dependency (e.g. worker queue) failing.
- Resource exhaustion causing request failures/timeouts.

## Rollback
If a recent deploy is the cause, roll back to the last known-good image digest
(from the Jenkins-archived `image-metadata.json` build artifact):
```bash
kubectl set image deployment/backend backend=<ECR_REPO_URI>@<previous-digest> -n devops-app
kubectl rollout status deployment/backend -n devops-app
```
(Same pattern for `worker` if the worker is the affected job.)

## Resolution
Once the root cause is fixed or rolled back, confirm recovery:
```promql
slo:http_availability_ratio:rate5m
```
should be back above `0.99`. The alert clears automatically once the ratio
stays above threshold for the full 5-minute `for` window.