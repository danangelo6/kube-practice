#!/bin/bash
# Run ON the EC2 instance (via SSM session) from the repo's monitoring/ directory.
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install prometheus prometheus-community/prometheus -n monitoring -f prometheus-values.yaml
helm upgrade --install grafana grafana/grafana -n monitoring -f grafana-values.yaml

echo "Done. Check: kubectl get pods -n monitoring"
