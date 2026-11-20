#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER=demo
NS=demo
RELEASE=demo
IMAGE=demo-service:0.1.0
INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/kind/deploy.yaml"

# 1. kind cluster (create only if missing)
if kind get clusters | grep -qx "$CLUSTER"; then
  echo ">> kind cluster '$CLUSTER' already exists, reusing"
else
  echo ">> creating kind cluster '$CLUSTER'"
  cat <<KINDCFG | kind create cluster --name "$CLUSTER" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
KINDCFG
fi
kubectl config use-context "kind-$CLUSTER"

# 2. ingress-nginx (apply is idempotent)
echo ">> installing ingress-nginx"
kubectl apply -f "$INGRESS_MANIFEST"
kubectl wait --namespace ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s

# 3. build and load image
echo ">> building image"
docker build -t "$IMAGE" service/
kind load docker-image "$IMAGE" --name "$CLUSTER"

# 4. install chart (retry: admission webhook can lag behind pod readiness)
echo ">> installing chart"
for i in 1 2 3 4 5; do
  if helm upgrade --install "$RELEASE" chart/ \
       --namespace "$NS" --create-namespace --wait --timeout 120s; then
    break
  fi
  [ "$i" -eq 5 ] && { echo "helm failed after 5 attempts"; exit 1; }
  echo "retrying in 10s ($i/5)"; sleep 10
done

echo ">> done. Verify with: curl -H 'Host: demo.local' http://localhost/"
