#!/usr/bin/env bash
# Remove everything the lab installs. Pass --stop to also stop minikube.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Guard against deleting resources on a real cluster.
if [ "$(kubectl config current-context)" != "minikube" ]; then
  echo "kubectl context is not 'minikube'; aborting."
  exit 1
fi

pkill -f 'kubectl port-forward' 2>/dev/null || true

for dir in 06-fault-injection 05-circuit-breaking 04-mtls 03-traffic-shifting 02-request-routing; do
  kubectl delete -f "$ROOT/manifests/$dir/" --ignore-not-found
done

kubectl delete ns legacy adm-test --ignore-not-found
kubectl delete -f "$ROOT/manifests/01-bookinfo/" --ignore-not-found

kubectl label namespace default istio-injection- 2>/dev/null || true
istioctl uninstall --purge -y
kubectl delete namespace istio-system --ignore-not-found

if [ "${1:-}" = "--stop" ]; then
  minikube stop
fi
