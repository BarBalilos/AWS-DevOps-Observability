#!/usr/bin/env bash
# scripts/uninstall.sh
#
# Tears down everything scripts/install.sh created, in reverse order.
# Does NOT delete the observability namespace itself by default (other
# repos' NetworkPolicies reference its 'purpose: monitoring' label, and
# leaving the empty namespace around is harmless) — pass --with-namespace
# to also remove it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="observability"
RELEASE="kube-prometheus-stack"

echo "==> 1/4  Removing Grafana dashboard ConfigMaps"
for f in "$REPO_ROOT"/grafana/dashboards/*.json; do
  name="$(basename "$f" .json)"
  kubectl delete configmap "grafana-dashboard-${name}" -n "$NAMESPACE" --ignore-not-found
done

echo "==> 2/4  Removing PrometheusRules and Monitors"
kubectl delete -f "$REPO_ROOT/prometheus/rules/" --ignore-not-found
kubectl delete -f "$REPO_ROOT/prometheus/monitors/" --ignore-not-found

echo "==> 3/4  Removing Alertmanager demo receiver"
kubectl delete -f "$REPO_ROOT/alertmanager/demo-receiver.yaml" --ignore-not-found

echo "==> 4/4  Uninstalling Helm release '$RELEASE'"
helm uninstall "$RELEASE" -n "$NAMESPACE" || true

if [ "${1:-}" = "--with-namespace" ]; then
  echo "==> Deleting namespace '$NAMESPACE'"
  kubectl delete -f "$REPO_ROOT/namespace/00-namespace.yaml" --ignore-not-found
else
  echo "==> Namespace '$NAMESPACE' left in place (pass --with-namespace to remove it)"
fi

echo "==> Done."