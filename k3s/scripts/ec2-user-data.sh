#!/bin/bash
# EC2 user-data for Amazon Linux 2023: installs swap, k3s (single-node Kubernetes) and Helm.
set -euxo pipefail

# 2 GB swap so a 1 GB t3.micro survives (not for production!)
if [ ! -f /swapfile ]; then
  dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# k3s: lightweight, CNCF-certified Kubernetes with Traefik ingress built in
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644" sh -

# Helm (used for Prometheus + Grafana)
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' > /etc/profile.d/k3s.sh
