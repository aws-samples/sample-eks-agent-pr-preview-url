#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Stand up the local kind cluster + ingress-nginx for end-to-end testing.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CLUSTER=pr-preview

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "[kind] cluster '$CLUSTER' already exists"
else
  echo "[kind] creating cluster '$CLUSTER'"
  kind create cluster --config "$ROOT/scripts/kind-cluster.yaml"
fi

echo "[kind] installing ingress-nginx"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/kind/deploy.yaml

echo "[kind] waiting for the controller pod to be created"
# `kubectl wait` errors with "no matching resources found" if the pod object
# doesn't exist yet, so poll for it to appear before waiting on readiness.
for _ in $(seq 1 30); do
  if kubectl get pod -n ingress-nginx \
       -l app.kubernetes.io/component=controller \
       -o name 2>/dev/null | grep -q .; then
    break
  fi
  sleep 2
done

echo "[kind] waiting for ingress-nginx to be ready"
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

# metrics-server for demo-grade observability: enables `kubectl top`.
# --kubelet-insecure-tls is needed on kind's self-signed kubelet certs.
echo "[kind] installing metrics-server"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' 2>/dev/null || true

echo "[kind] ready. Previews will be reachable at http://localhost:8080/pr-<n>/"
echo "[kind] observability: 'kubectl top pods -n pr-<n>' once metrics-server is ready."
