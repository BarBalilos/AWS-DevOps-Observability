# AWS DevOps — Observability as Code

Monitoring and observability for the `devops-k8s` cluster (Prometheus, Alertmanager, Grafana) deployed via `kube-prometheus-stack`, entirely defined as code in this repository. See [`architecture/observability-architecture.md`](architecture/observability-architecture.md) for the full component diagram, storage/retention/recovery details, and data flow.

This repo is one of three that make up the project:

| Repo | Contents |
|---|---|
| `AWS-DevOps-Observability` (this repo) | Helm values, ServiceMonitors/PodMonitors, PrometheusRules, Grafana dashboards, runbooks, install/verify scripts, all failure-exercise and reinstall evidence |
| `AWS-DevOps-Kubernetes` | Application manifests (`k8s/`), app source + instrumentation (`docker/backend`, `docker/worker`), NetworkPolicy |
| `AWS-DevOps-Jenkins-CICD` | Jenkins Helm values, CI/CD pipelines (`pipelines/`), job configs, Jenkins monitoring exposure |

## Reproducing the stack

```bash
bash scripts/install.sh     # namespace, Helm release, monitors, rules, dashboards — idempotent
bash scripts/verify.sh      # confirms every expected resource is present and healthy
bash scripts/uninstall.sh   # tear down (add --with-namespace to also delete the namespace)
```

`evidence/05-reinstall-from-scratch/00-findings.md` documents a full teardown-including-namespace-deletion followed by reinstall and verification, proving the entire stack reproduces from Git alone with no manual cluster-side steps.

## Access

| Service | Command | URL |
|---|---|---|
| Prometheus | `kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090` | http://localhost:9090 |
| Alertmanager | `kubectl port-forward -n observability svc/kube-prometheus-stack-alertmanager 9093:9093` | http://localhost:9093 |
| Grafana | `kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80` | http://localhost:3000 |
| Jenkins | `kubectl port-forward -n jenkins svc/jenkins 8081:8080` | http://localhost:8081 |

Grafana logs in as `admin`; retrieve the password with:
```bash
kubectl get secret --namespace observability kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d; echo
```
Jenkins credentials: `kubectl get secret -n jenkins <secret-name> -o jsonpath="{.data.password}" | base64 -d; echo` (see `AWS-DevOps-Jenkins-CICD/README.md` for the exact secret name). Neither should ever be pasted into chat, a commit, or a screenshot.

## Requirements coverage

| Requirement | Implementation | Evidence |
|---|---|---|
| kube-prometheus-stack in `observability` namespace, reproducible from code | `helm/kube-prometheus-stack/values.yaml`, `namespace/00-namespace.yaml`, `scripts/install.sh` | `evidence/05-reinstall-from-scratch/` |
| Prometheus Operator + Prometheus instance | `helm/kube-prometheus-stack/values.yaml` | `evidence/01-stack-deployment/` |
| Grafana with automatic datasource + dashboard provisioning from Git | `grafana/dashboards/*.json` loaded as labeled ConfigMaps by `scripts/install.sh` | `evidence/02-dashboards/`, `evidence/05-reinstall-from-scratch/05-grafana-dashboard-post-reinstall-*.png` |
| Alertmanager with a safe, non-external demo receiver | `alertmanager/demo-receiver.yaml` | `evidence/04-failure-exercises/*/0*-demo-receiver-*.txt` (all 4 exercises) |
| kube-state-metrics, node-exporter, kubelet/cAdvisor metrics | Bundled and enabled via `helm/kube-prometheus-stack/values.yaml`; kubelet scraping confirmed live | `evidence/01-stack-deployment/` |
| ServiceMonitor/PodMonitor for every app service and Jenkins | `prometheus/monitors/backend-podmonitor.yaml`, `worker-podmonitor.yaml`, `frontend-podmonitor.yaml`, `jenkins-servicemonitor.yaml` | `evidence/01-stack-deployment/` |
| Jenkins Prometheus plugin / metrics exposure | `AWS-DevOps-Jenkins-CICD/jenkins/monitoring/jenkins-metrics-service.yaml`, `jenkins/helm/values-jcasc.yaml` | `grafana/dashboards/jenkins-delivery.json` rendering live data, including controller JVM panels |
| 3 required Grafana dashboards | `grafana/dashboards/application-overview.json`, `kubernetes-cluster.json`, `jenkins-delivery.json` | `evidence/02-dashboards/` |
| Application instrumentation (counters/gauges/histograms, `app_info`, business metric) | `AWS-DevOps-Kubernetes/docker/backend/app.py`, `docker/worker/worker.py` | Application Overview dashboard panels |
| SLI/SLO — Availability (99%) and Latency (95%) | `prometheus/rules/slo-recording-rules.yaml` | Application Overview dashboard, "Availability SLO" / "Latency SLO" panels |
| 6 active alerting rules, each with severity/summary/description/runbook | `prometheus/rules/app-alerts.yaml`, `jenkins-alerts.yaml`, `kubernetes-alerts.yaml`, `monitoring-alerts.yaml` → `runbooks/*.md` | `evidence/03-alerts-firing-resolved/`, all 4 failure exercises |
| CI validates PrometheusRule/ServiceMonitor/dashboard files | `AWS-DevOps-Jenkins-CICD/pipelines/Jenkinsfile-observability-ci` | `AWS-DevOps-Jenkins-CICD/evidence/02-pipeline-ci/` |
| CD runs post-deploy smoke test + monitoring gate | `AWS-DevOps-Jenkins-CICD/pipelines/Jenkinsfile-cd` (Smoke Test + Monitoring Gate stages) | `AWS-DevOps-Jenkins-CICD/evidence/03-pipeline-cd/`, `evidence/04-failure-exercises/d-broken-release-rollback/` |
| 4 controlled failure exercises with full evidence | See table below | `evidence/04-failure-exercises/` |
| RBAC minimal, no cluster-admin for monitoring components | Confirmed live: only `system:masters` and k3d's built-in Traefik ServiceAccounts hold `cluster-admin`; nothing observability-related | — |
| NetworkPolicies restrict metrics scrape to the `observability` namespace only | `AWS-DevOps-Kubernetes/k8s/13-networkpolicy.yaml` | — |
| No unbounded-cardinality labels (route pattern, not raw URL) | `AWS-DevOps-Kubernetes/docker/backend/app.py` (`request.url_rule.rule`) | — |
| Documented retention, storage consumption, and PVC-deletion recovery | `architecture/observability-architecture.md` § Storage, Retention & Recovery | `evidence/05-reinstall-from-scratch/` |
| Full reproducibility proof (Observability as Code) | `scripts/install.sh`, `uninstall.sh`, `verify.sh` | `evidence/05-reinstall-from-scratch/00-findings.md` |

## Alerting rules

| Alert | Rule file | Runbook |
|---|---|---|
| HighErrorRate | `prometheus/rules/app-alerts.yaml` | `runbooks/HighErrorRate.md` |
| HighLatencyP95 | `prometheus/rules/app-alerts.yaml` | `runbooks/HighLatencyP95.md` |
| ReplicasMismatch | `prometheus/rules/kubernetes-alerts.yaml` | `runbooks/ReplicasMismatch.md` |
| NodeNotReadyOrPressure | `prometheus/rules/kubernetes-alerts.yaml` | `runbooks/NodeNotReadyOrPressure.md` |
| JenkinsQueueStuck | `prometheus/rules/jenkins-alerts.yaml` | `runbooks/JenkinsQueueStuck.md` |
| PrometheusTargetDown | `prometheus/rules/monitoring-alerts.yaml` | `runbooks/PrometheusTargetDown.md` |

## Controlled failure exercises

| Exercise | Alert exercised | Findings |
|---|---|---|
| a — 5xx burst | HighErrorRate | `evidence/04-failure-exercises/a-5xx-burst/00-findings.md` |
| b — pod delete / readiness break | ReplicasMismatch | `evidence/04-failure-exercises/b-pod-delete-readiness/00-findings.md` |
| c — Jenkins agent delay | JenkinsQueueStuck | `evidence/04-failure-exercises/c-jenkins-agent-delay/00-findings.md` |
| d — broken release rollback | PrometheusTargetDown | `evidence/04-failure-exercises/d-broken-release-rollback/00-findings.md` |

Each exercise's findings document covers the objective, method, root cause, recovery, and a full evidence table (Prometheus alert state, Alertmanager routing, demo-receiver webhook delivery, and Grafana/Jenkins/Prometheus UI screenshots for both the firing and resolved states).

## Troubleshooting

**`verify.sh` reports a failure.** It prints exactly which check failed (a workload not ready, a missing PrometheusRule/monitor, or a missing/unlabeled dashboard ConfigMap). Re-run `bash scripts/install.sh` first — it's idempotent and will re-apply anything missing — then `bash scripts/verify.sh` again. If a specific workload is stuck, `kubectl get pods -n observability` and `kubectl describe pod <name> -n observability` show why.

**A Grafana dashboard panel shows "No data."** First check the panel is querying a metric that actually has data right now (e.g., the Error Rate panels are *expected* to show "No data" when there's no error traffic — that's correct behavior, not a bug). If a panel that should have data doesn't: confirm the Prometheus datasource is reachable (top-left dropdown in Grafana), then check the underlying target is `up` in Prometheus (`http://localhost:9090/targets`). If the target is down, check the relevant `ServiceMonitor`/`PodMonitor` in `prometheus/monitors/` and the corresponding NetworkPolicy in the app's repo.

**Can't log into Grafana.** Username is `admin`. Retrieve the password with the command in the Access section above — never guess or reuse a password from elsewhere, it's chart-generated per install.

**An alert isn't firing when you expect it to.** Query the alert's exact `expr` directly in the Prometheus UI (`http://localhost:9090/graph`) to see if the underlying condition is actually true — the alert rule files in `prometheus/rules/` are the source of truth for the exact expression and `for:` duration. If the expression returns no data at all, check the metric name is correct (this project has hit real metric-naming mismatches before — see `docs/incidents-and-lessons-learned.md`).

**Something's badly broken and you want a clean slate.** `bash scripts/uninstall.sh --with-namespace` followed by `bash scripts/install.sh` rebuilds the entire stack from Git in under a minute — this is the same procedure proven in `evidence/05-reinstall-from-scratch/`.

## Known issues and lessons learned

Troubleshooting notes and real incidents encountered while building this stack (metric-naming mismatches, rolling-update mechanics, pipeline gotchas, and infrastructure incidents) are documented separately in [`docs/incidents-and-lessons-learned.md`](docs/incidents-and-lessons-learned.md).