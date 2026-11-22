#!/bin/bash
# Installs Prometheus + Grafana into the cluster your current kubectl context points to.
# Run from the monitoring/ directory:  ./install.sh
set -euo pipefail

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install prometheus prometheus-community/prometheus -n monitoring -f prometheus-values.yaml
helm upgrade --install grafana grafana/grafana -n monitoring -f grafana-values.yaml

echo
echo "Grafana admin password:"
kubectl get secret grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d; echo
echo "Open Grafana:  kubectl -n monitoring port-forward svc/grafana 3000:80   then http://localhost:3000 (user: admin)"
