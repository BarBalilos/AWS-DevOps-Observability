# Reinstall From Scratch — Observability as Code Proof

## Objective

Prove that the entire monitoring stack — namespace, Prometheus Operator, Prometheus/Alertmanager/Grafana instances, kube-state-metrics, node-exporter, all ServiceMonitors/PodMonitors, all PrometheusRules, the Alertmanager demo receiver, and all Grafana dashboards — is fully reproducible from Git-tracked code alone, with zero manual cluster-side configuration required after a complete teardown.

## Method

1. Captured a baseline snapshot of every resource in the `observability` namespace, plus the PrometheusRule/PodMonitor/ServiceMonitor objects living in `observability`, `devops-app`, and `jenkins`.
2. Ran a full destructive teardown via `bash scripts/uninstall.sh --with-namespace`, which removes the Grafana dashboard ConfigMaps, all PrometheusRules/PodMonitors/ServiceMonitors, the Alertmanager demo receiver, the `kube-prometheus-stack` Helm release, and — because of the explicit `--with-namespace` flag — the `observability` namespace itself.
3. Confirmed the namespace and every resource in it were genuinely gone (`kubectl get namespace observability` → NotFound; `kubectl get all -n observability` → No resources found).
4. Ran a full timed reinstall via `time bash scripts/install.sh`.
5. Ran the repository's own `bash scripts/verify.sh` to confirm every expected resource came back.
6. Performed additional functional double-checks beyond mere resource existence: confirmed real Prometheus scraping resumed for every `devops-app` target and the `jenkins-metrics` job, confirmed the Alertmanager `demo-webhook` receiver configuration reproduced correctly from the Helm values, confirmed only the expected baseline alerts (`InfoInhibitor`, `Watchdog`) were active, and confirmed the "Application Overview" Grafana dashboard rendered with real, live data.

## Findings

**Full teardown and reinstall completed cleanly with zero manual intervention.** Every object recreated by `install.sh` came from files already committed to Git — no `kubectl edit`, no manual Helm value patching, no manually re-created secrets or ConfigMaps.

**Reinstall time: 45.676 seconds** (`real 0m45.676s`, measured by `time bash scripts/install.sh`). All 6 install steps (namespace creation, Helm repo setup, `helm upgrade --install kube-prometheus-stack --wait --timeout 5m`, demo receiver, ServiceMonitors/PodMonitors/PrometheusRules, Grafana dashboard ConfigMaps) completed with zero errors on the first attempt.

**`verify.sh` passed every check** on the first run post-reinstall: all 6 core workloads ready, the node-exporter DaemonSet present, all 5 named PrometheusRules present, all 3 named PodMonitors present in `devops-app`, the named ServiceMonitor present in `jenkins`, and all 3 Grafana dashboard ConfigMaps present and correctly labeled `grafana_dashboard=1`. Script exited 0 with `All checks passed.`

**Functional verification beyond resource existence, all confirmed correct:**
- Prometheus resumed real scraping (not just target registration) for every `devops-app` target — backend, worker, and the frontend's nginx-prometheus-exporter sidecar all reported `up == 1` — and for the `jenkins-metrics` job.
- Alertmanager's live configuration (`/api/v2/status`, `.config.original`) contains the `demo-webhook` receiver exactly as defined in the Helm values in Git, including `send_resolved: true`, proving the alerting route/receiver config is reproduced from code, not from any manual runtime edit.
- `/api/v2/alerts` showed only the expected always-on baseline alerts (`InfoInhibitor`, `Watchdog`) — nothing left over or falsely firing from the teardown/reinstall cycle.
- The "Application Overview" Grafana dashboard rendered with live data immediately after reinstall with no manual datasource or dashboard setup: Availability SLO and Latency SLO gauges both showed 100%, Request Rate and P95 Latency panels showed real time series for `devops-app/backend` and `devops-app/worker`, and the Service Info table was populated from the `app_info` metric. This confirms both the Prometheus datasource provisioning and the dashboard-JSON provisioning (via ConfigMap + `grafana_dashboard` label sidecar) came back correctly from Git alone. The Error Rate, Dependency Errors, Business Metrics, and Active App Alerts panels correctly showed "No data," which is expected — there had been no error traffic, no record/file-upload activity, and no active app-level alerts in the short window since reinstall, so this reflects the true state of the system rather than a provisioning gap.

**Known, expected caveats (not defects):**
- **Postgres data loss.** The `postgres` Deployment has no PersistentVolumeClaim (see `evidence/04-failure-exercises/a-5xx-burst/00-findings.md`), so the teardown/reinstall cycle — like any Postgres pod restart — wipes its data directory. The manually-created `records` table does not persist across this exercise and would need to be recreated again if `/api/records` functionality is needed. This is a known, already-documented gap in the application manifests, out of scope for the observability repo to fix.
- **Brief monitoring blackout during the down window.** Between `uninstall.sh --with-namespace` completing and `install.sh` finishing (under a minute in this run), there is no monitoring coverage at all — no scraping, no alerting, no dashboards. This is inherent to a full namespace-delete-and-recreate cycle and is acceptable for this demonstration; a production reinstall would instead use `uninstall.sh` without `--with-namespace` (namespace retained) combined with a rolling Helm upgrade to avoid any coverage gap.
- **`uninstall.sh` retains the namespace by default.** The `--with-namespace` flag is opt-in by design (see the script's own comment) because other repositories' NetworkPolicies reference the `purpose: monitoring` namespace label; deleting the namespace by default would silently break those policies until the namespace and its label were manually recreated. This exercise deliberately used `--with-namespace` to prove the namespace itself is also fully defined as code (`kubectl create namespace` + label, inside `install.sh`), not just the workloads inside it.

## Conclusion

The observability stack meets the Observability-as-Code requirement: a complete teardown including namespace deletion, followed by a scripted reinstall and the repository's own verification script, reproduces the entire stack — Prometheus, Alertmanager, Grafana with its datasource and all three dashboards, kube-state-metrics, node-exporter, every ServiceMonitor/PodMonitor, every PrometheusRule, and the Alertmanager demo receiver — correctly and completely from Git alone, with no manual cluster-side steps.

## Evidence

| # | File | Description |
|---|------|-------------|
| 01 | `01-before-teardown-all-resources.txt` | Baseline snapshot of all `observability` namespace resources plus PrometheusRule/PodMonitor/ServiceMonitor listings across `observability`, `devops-app`, `jenkins` |
| 02 | `02-after-teardown-confirmed-gone.txt` | Confirms namespace and all resources genuinely gone after `uninstall.sh --with-namespace` |
| 03 | `03-install-output.txt` | Full `time bash scripts/install.sh` output — 45.676s real time, all 6 steps succeeded |
| 04 | `04-verify-output.txt` | Full `bash scripts/verify.sh` output — every check `[OK]`, exit code 0 |
| 05 | `05-grafana-dashboard-post-reinstall-top.png` / `-bottom.png` | "Application Overview" dashboard rendering live data post-reinstall — SLO gauges, request rate, latency, service info all populated from real scrapes |