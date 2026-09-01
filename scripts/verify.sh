#!/usr/bin/env bash
# scripts/verify.sh
#
# Post-install sanity check for the observability stack. Run after
# install.sh (or after any `helm upgrade`) to confirm everything is
# actually working, not just that `kubectl apply` succeeded.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="observability"
FAIL=0

section() { echo; echo "=== $1 ==="; }

check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  [OK]   $desc"
  else
    echo "  [FAIL] $desc"
    FAIL=1
  fi
}

ready_stateful() {
  local ready
  ready="$(kubectl get statefulset -n "$NAMESPACE" "$1" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  [ "$ready" = "1" ]
}

ready_deploy() {
  local ready
  ready="$(kubectl get deployment -n "$NAMESPACE" "$1" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  [ "$ready" = "1" ]
}

section "Pods"
kubectl get pods -n "$NAMESPACE"

section "Core workloads ready"
check "Prometheus StatefulSet ready"         ready_stateful "prometheus-kube-prometheus-stack-prometheus"
check "Alertmanager StatefulSet ready"       ready_stateful "alertmanager-kube-prometheus-stack-alertmanager"
check "Grafana Deployment ready"             ready_deploy "kube-prometheus-stack-grafana"
check "kube-state-metrics Deployment ready"  ready_deploy "kube-prometheus-stack-kube-state-metrics"
check "Prometheus Operator Deployment ready" ready_deploy "kube-prometheus-stack-operator"
check "Alertmanager demo receiver ready"     ready_deploy "alertmanager-demo-receiver"

section "node-exporter DaemonSet present"
check "node-exporter DaemonSet exists" \
  bash -c "kubectl get daemonset -n $NAMESPACE -o name | grep -q node-exporter"

section "PrometheusRule objects present"
for r in app-alerts jenkins-alerts kubernetes-alerts monitoring-alerts slo-recording-rules; do
  check "PrometheusRule/$r exists" kubectl get prometheusrule -n "$NAMESPACE" "$r"
done

section "PodMonitors present"
check "PodMonitor/backend exists (devops-app)"  kubectl get podmonitor -n devops-app backend
check "PodMonitor/frontend exists (devops-app)" kubectl get podmonitor -n devops-app frontend
check "PodMonitor/worker exists (devops-app)"   kubectl get podmonitor -n devops-app worker

section "ServiceMonitors present"
check "ServiceMonitor/jenkins exists (jenkins)" kubectl get servicemonitor -n jenkins jenkins

section "Grafana dashboard ConfigMaps present and labeled"
for f in "$REPO_ROOT"/grafana/dashboards/*.json; do
  name="$(basename "$f" .json)"
  cm="grafana-dashboard-${name}"
  label="$(kubectl get configmap -n "$NAMESPACE" "$cm" -o jsonpath='{.metadata.labels.grafana_dashboard}' 2>/dev/null)"
  if [ "$label" = "1" ]; then
    echo "  [OK]   ConfigMap/$cm labeled grafana_dashboard=1"
  else
    echo "  [FAIL] ConfigMap/$cm missing or unlabeled"
    FAIL=1
  fi
done

echo
if [ "$FAIL" -ne 0 ]; then
  echo "One or more checks FAILED. See output above."
  exit 1
fi
echo "All checks passed."