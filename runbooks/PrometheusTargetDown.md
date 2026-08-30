# PrometheusTargetDown

**Severity:** critical
**Category:** monitoring-system
**Fires when:** `up == 0` for any scrape target for 5 minutes

## What this means
Prometheus has been unable to scrape `{{ $labels.instance }}` (job
`{{ $labels.job }}`) for 5+ minutes. This is a meta-monitoring alert: while
this fires, both metrics collection *and* alerting for that target are
blind — a real outage on that target may not be visible or alertable.

## Immediate checks
```bash
kubectl get pods -A -o wide | grep -i <target-name>
kubectl get svc,endpoints -n <target-namespace> <target-service>
kubectl get networkpolicy -n <target-namespace>
```
Also check the Prometheus targets page directly (after port-forwarding
`svc/kube-prometheus-stack-prometheus` on 9090):
`http://localhost:9090/targets` — find the target and read the "Error"
column for the exact scrape failure reason.

## Likely causes
- The target pod crashed or restarted and hasn't come back yet (check for
  `CrashLoopBackOff`/`ImagePullBackOff` — see `ReplicasMismatch` runbook).
- A NetworkPolicy is blocking the scrape (e.g. the `observability` namespace
  is missing its `purpose: monitoring` label, or a policy was edited and no
  longer allows ingress on the metrics port).
- The Service's label selector no longer matches the pod's labels after an
  edit (Service has zero endpoints).
- The target's metrics endpoint changed port or path without updating the
  matching PodMonitor/ServiceMonitor.

## Resolution
- Restore the pod (see `ReplicasMismatch` runbook if it's an app pod).
- Fix the NetworkPolicy or Service selector/label mismatch.
- Fix the PodMonitor/ServiceMonitor port/path if the target itself changed.

Confirm recovery via `/targets` in the Prometheus UI, or:
```promql
up{job="<affected job>"}
```
should return `1`. The alert clears automatically once the target is
successfully scraped for 5 minutes.