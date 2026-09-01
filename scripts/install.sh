#!/usr/bin/env bash
# scripts/install.sh
#
# Reproduces the full observability stack from this repo, from scratch.
# Safe to re-run (idempotent) — every step uses `helm upgrade --install` or
# `kubectl apply`, never a create-only command.
#
# Prerequisite: kubectl context pointed at the target cluster (devops-k8s).
# This script only manages the observability namespace and its resources —
# the app (AWS-DevOps-Kubernetes) and Jenkins (AWS-DevOps-Jenkins-CICD)
# repos are deployed independently.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="observability"
RELEASE="kube-prometheus-stack"
CHART_VERSION="88.5.4"

echo "==> 1/6  Ensuring namespace '$NAMESPACE' exists and is labeled"
kubectl apply -f "$REPO_ROOT/namespace/00-namespace.yaml"

echo "==> 2/6  Adding/updating the prometheus-community Helm repo"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null

echo "==> 3/6  Installing/upgrading $RELEASE (chart v$CHART_VERSION)"
helm upgrade --install "$RELEASE" prometheus-community/kube-prometheus-stack \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  -f "$REPO_ROOT/helm/kube-prometheus-stack/values.yaml" \
  --wait --timeout 5m

echo "==> 4/6  Applying Alertmanager demo receiver"
kubectl apply -f "$REPO_ROOT/alertmanager/demo-receiver.yaml"

echo "==> 5/6  Applying ServiceMonitors/PodMonitors and PrometheusRules"
kubectl apply -f "$REPO_ROOT/prometheus/monitors/"
kubectl apply -f "$REPO_ROOT/prometheus/rules/"

echo "==> 6/6  Provisioning Grafana dashboards from grafana/dashboards/*.json"
for f in "$REPO_ROOT"/grafana/dashboards/*.json; do
  name="$(basename "$f" .json)"
  cm_name="grafana-dashboard-${name}"
  echo "    - ${cm_name}"
  kubectl create configmap "$cm_name" \
    --namespace "$NAMESPACE" \
    --from-file="${name}.json=${f}" \
    --dry-run=client -o yaml \
  | kubectl apply -f -
  kubectl label configmap "$cm_name" \
    --namespace "$NAMESPACE" \
    grafana_dashboard="1" \
    --overwrite
done

echo "==> Done. Verify with: scripts/verify.sh"