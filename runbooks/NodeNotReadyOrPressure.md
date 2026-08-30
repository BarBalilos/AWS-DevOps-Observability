# NodeNotReadyOrPressure

**Severity:** critical
**Category:** k8s
**Fires when:** a node reports `Ready=false`, or `MemoryPressure`/`DiskPressure`/`PIDPressure=true`,
for 5 minutes

## What this means
A cluster node is either not Ready, or is reporting resource pressure. New
pods may fail to schedule on this node, and existing pods may be evicted.

## Immediate checks
```bash
kubectl get nodes -o wide
kubectl describe node <node>
kubectl top nodes
```
- Look at the `Conditions` section of `describe node` for the specific
  pressure type and its message.
- On this k3d/Docker Desktop setup specifically: check Docker Desktop's
  allocated CPU/memory/disk (Settings → Resources), and check WSL2 disk
  usage (`wsl --status`, `df -h` inside WSL2).

## Likely causes
- Docker Desktop resource limits (CPU/memory) set too low for the workload.
- Host disk filling up from accumulated container image layers/logs
  (`docker system df`).
- WSL2 VM under memory pressure from other processes on the Windows host.
- Node still booting/rejoining after a Docker Desktop restart (transient —
  usually self-resolves within a minute or two).

## Resolution
- Free disk: `docker system prune` (careful — check with your instructor/
  course policy before pruning shared images), remove old unused images.
- Increase Docker Desktop's CPU/memory/disk allocation if consistently
  under pressure.
- If transient (just restarted Docker Desktop / the cluster), wait — this
  should clear on its own once the node finishes rejoining.

Confirm recovery with:
```bash
kubectl get nodes
```
The node should show `Ready` with no pressure conditions. The alert clears
automatically once conditions are healthy for 5 minutes.