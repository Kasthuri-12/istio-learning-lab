# Lab guide

Run every command from the repository root. Open the Bookinfo page at http://localhost:8080/productpage, which needs this running in a separate terminal:

```bash
kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80
```

Reviews versions on the page: v1 shows no stars, v2 black stars, v3 red stars.

## Step 0: Admission controllers

Admission controllers run when the API server receives a request, before the object is stored. Istio's sidecar injection is a mutating webhook.

```bash
kubectl create ns adm-test

# Mutating: the storage class is filled in
kubectl apply -n adm-test -f manifests/00-admission-controllers/01-mutation-pvc.yaml
kubectl get pvc -n adm-test myclaim -o jsonpath='{.spec.storageClassName}{"\n"}'

# Validating: the pod exceeds the quota and is rejected
kubectl apply -n adm-test -f manifests/00-admission-controllers/02-resourcequota.yaml
kubectl apply -n adm-test -f manifests/00-admission-controllers/03-pod-over-quota.yaml

kubectl delete ns adm-test
```

The quota lives in a separate namespace so it doesn't restrict pods in `default`.

## Step 1: Install Istio and Bookinfo

```bash
./scripts/setup.sh
kubectl get pods        # every pod shows 2/2: app container plus sidecar
```

The script runs `istioctl install --set profile=demo`, labels `default` with `istio-injection=enabled`, and applies [manifests/01-bookinfo](../manifests/01-bookinfo).

Useful inspection commands:

```bash
kubectl get pods -l app=reviews --show-labels
kubectl get gateway,virtualservice,destinationrule
```

## Step 2: Request routing

```bash
kubectl apply -f manifests/02-request-routing/01-all-v1.yaml
# reload the page: always v1

kubectl apply -f manifests/02-request-routing/02-route-by-user.yaml
# sign in as user "jason" (any password): v2; everyone else: v1
```

## Step 3: Traffic shifting

```bash
kubectl apply -f manifests/02-request-routing/01-all-v1.yaml
kubectl apply -f manifests/03-traffic-shifting/01-split-50-50.yaml

for i in $(seq 1 20); do curl -s localhost:8080/productpage | grep -c 'glyphicon-star'; done | sort | uniq -c
```

A count of `0` is a v1 response; a non-zero count is a v3 response. Expect roughly half each. Then:

```bash
kubectl apply -f manifests/03-traffic-shifting/02-split-90-10.yaml
```

and repeat the loop.

## Step 4: mTLS

```bash
kubectl create ns legacy
kubectl run curl -n legacy --image=curlimages/curl --restart=Never -- sleep 3600
kubectl wait -n legacy --for=condition=Ready pod/curl --timeout=120s

check() { kubectl exec -n legacy curl -- curl -s -o /dev/null -w '%{http_code}\n' productpage.default:9080/productpage; }

check                                                  # 200, permissive by default

kubectl apply -f manifests/04-mtls/strict.yaml
check                                                  # 000, exit 56: no sidecar, plain traffic refused

kubectl exec deploy/ratings-v1 -c ratings -- curl -s -o /dev/null -w '%{http_code}\n' productpage:9080/productpage   # 200, in-mesh

kubectl apply -f manifests/04-mtls/permissive.yaml
check                                                  # 200 again

kubectl delete -f manifests/04-mtls/ && kubectl delete ns legacy
```

## Step 5: Circuit breaking

```bash
S=https://raw.githubusercontent.com/istio/istio/release-1.31/samples
kubectl apply -f $S/httpbin/httpbin.yaml -f $S/httpbin/sample-client/fortio-deploy.yaml
kubectl apply -f manifests/05-circuit-breaking/httpbin-destination-rule.yaml

FORTIO_POD=$(kubectl get pods -l app=fortio -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio load -c 2 -qps 0 -n 20 -loglevel Warning http://httpbin:8000/get
kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio load -c 3 -qps 0 -n 30 -loglevel Warning http://httpbin:8000/get
kubectl exec "$FORTIO_POD" -c istio-proxy -- pilot-agent request GET stats | grep httpbin | grep pending
```

With 3 connections many requests return `Code 503`; `upstream_rq_pending_overflow` counts the rejected ones.

```bash
kubectl delete -f manifests/05-circuit-breaking/
kubectl delete -f $S/httpbin/httpbin.yaml -f $S/httpbin/sample-client/fortio-deploy.yaml
```

## Step 6: Fault injection and timeouts

Start from the routing in step 2 (jason goes to reviews v2, which calls ratings):

```bash
kubectl apply -f manifests/02-request-routing/01-all-v1.yaml
kubectl apply -f manifests/02-request-routing/02-route-by-user.yaml

kubectl apply -f manifests/06-fault-injection/01-delay.yaml     # 7s delay on ratings for jason
# page as jason: slow, reviews unavailable

kubectl apply -f manifests/06-fault-injection/02-abort.yaml     # HTTP 500 on ratings for jason
# page as jason: instant, ratings unavailable

kubectl apply -f manifests/06-fault-injection/01-delay.yaml     # delay again, then add a timeout
kubectl apply -f manifests/06-fault-injection/03-timeout.yaml   # 0.5s timeout on reviews for jason
# page as jason: reviews call cut off after 0.5s
```

`01-delay.yaml` and `02-abort.yaml` both define the `ratings` VirtualService, so applying one replaces the other.

## Step 7: Gateways

[manifests/01-bookinfo/bookinfo-gateway.yaml](../manifests/01-bookinfo/bookinfo-gateway.yaml) shows the pattern: a Gateway opens the port and a VirtualService attached to it routes `/productpage`, `/login`, `/logout` and `/static`. Any other path returns 404.

## Step 8: Cleanup between experiments

```bash
kubectl delete -f manifests/06-fault-injection/ --ignore-not-found
kubectl delete -f manifests/03-traffic-shifting/ --ignore-not-found
kubectl delete -f manifests/02-request-routing/ --ignore-not-found
```

## Step 9: Observability

```bash
A=https://raw.githubusercontent.com/istio/istio/release-1.31/samples/addons
kubectl apply -f $A/prometheus.yaml -f $A/kiali.yaml -f $A/jaeger.yaml -f $A/grafana.yaml

while true; do curl -s -o /dev/null localhost:8080/productpage; sleep 0.5; done   # keep running in another terminal

istioctl dashboard kiali       # Graph, namespace default
istioctl dashboard jaeger      # service productpage.default
istioctl dashboard grafana     # Istio Service Dashboard
```

Apply the traffic-shifting manifests while watching Kiali to see the edges change.

```bash
kubectl delete -f $A/prometheus.yaml -f $A/kiali.yaml -f $A/jaeger.yaml -f $A/grafana.yaml
```

## Full cleanup

```bash
./scripts/cleanup.sh --stop
```
