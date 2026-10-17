#!/usr/bin/env bash
# Start minikube, install Istio (demo profile) and deploy Bookinfo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# An amd64 default platform breaks the arm64 minikube node image on Apple Silicon.
unset DOCKER_DEFAULT_PLATFORM

for tool in minikube kubectl istioctl docker; do
  command -v "$tool" >/dev/null || { echo "missing prerequisite: $tool"; exit 1; }
done

minikube start --cpus=4 --memory=4096
kubectl config use-context minikube

istioctl install --set profile=demo -y
kubectl label namespace default istio-injection=enabled --overwrite

kubectl apply -f "$ROOT/manifests/01-bookinfo/"
kubectl rollout status deploy -n default --timeout=300s
kubectl get pods

echo "Next: kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80"
echo "Then open http://localhost:8080/productpage"
