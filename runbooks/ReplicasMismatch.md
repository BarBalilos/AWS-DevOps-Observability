# ReplicasMismatch

**Severity:** critical
**Category:** k8s
**Fires when:** `kube_deployment_status_replicas_available != kube_deployment_spec_replicas`
in `devops-app` for 10 minutes

## What this means
A Deployment in `devops-app` has had fewer (or more) available replicas than
desired for over 10 minutes — long enough that this is not just a normal
rollout in progress.

## Immediate checks
```bash
kubectl get deploy -n devops-app
kubectl get pods -n devops-app -o wide
kubectl describe deploy/<deployment> -n devops-app
kubectl describe pod <failing-pod> -n devops-app
kubectl get events -n devops-app --sort-by=.lastTimestamp | tail -20
```

## Likely causes
- `ImagePullBackOff` — commonly a stale `ecr-pull-secret` (the ECR auth token
  expires ~12h; if the node's local image cache was evicted since the last
  CI/CD run, a fresh pull will 403 against an expired token). This has
  happened before on this cluster — see the incident notes in the README.
- `CrashLoopBackOff` — application error on startup.
- Failing readiness/liveness probe.
- Insufficient node CPU/memory to schedule the pod.
- A NetworkPolicy blocking a dependency the pod needs at startup (e.g. DB).

## Resolution
- If it's a stale ECR token: trigger a fresh Jenkins CI/CD run — the CD
  pipeline's "Refresh ECR Pull Secret" stage regenerates the secret and
  restarts the affected deployments.
- If it's a probe/crash issue: fix the underlying code/config and redeploy,
  or roll back to the last known-good image digest.
- If it's a resource issue: check `kubectl describe node` for allocatable
  capacity, free up resources or reduce replica/resource requests.

Confirm recovery with:
```bash
kubectl get deploy -n devops-app
```
`AVAILABLE` should equal `UP-TO-DATE`/desired replicas. The alert clears
automatically once this holds for 10 minutes.