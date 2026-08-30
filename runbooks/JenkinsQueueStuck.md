# JenkinsQueueStuck

**Severity:** warning
**Category:** jenkins
**Fires when:** `default_jenkins_queue_size_value > 3` for 10 minutes

## What this means
More than 3 builds have been queued in Jenkins for over 10 minutes,
indicating insufficient agent capacity or a stuck/slow build blocking the
queue.

## Immediate checks
- Jenkins UI → **Build Queue**: look for what's queued and why (hover over
  a queued item for the reason, e.g. "Waiting for next available executor").
```bash
kubectl get pods -n jenkins -o wide
kubectl describe pod <jenkins-agent-pod> -n jenkins
```
- Check if any currently running build is hung (stuck on a step, waiting on
  manual input, or making a slow/failing external call).
- Check whether agent pods are failing to start (image pull issues,
  insufficient cluster resources for the ephemeral agent pod template).

## Likely causes
- One build is hung and holding an executor, blocking others behind it.
- The Kubernetes agent pod template can't be scheduled (resource limits,
  image pull failure, JNLP connectivity issue between agent and controller).
- Genuine load spike — more builds triggered than available executor
  capacity.

## Resolution
- Abort the stuck build if one is identified (Jenkins UI → build → Abort).
- Fix the agent pod template or free up cluster resources if agents can't
  schedule.
- If it's a genuine load spike, wait for the queue to drain, or increase
  agent concurrency if this becomes a recurring pattern.

Confirm recovery via the Jenkins UI Build Queue, or:
```promql
default_jenkins_queue_size_value
```
should drop to ≤3 and stay there. The alert clears automatically once this
holds for 10 minutes.