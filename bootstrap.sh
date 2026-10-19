#!/usr/bin/env bash
set -Eeuo pipefail

# Run this script from the repository root.
# Required first: the kind cluster must exist and nodes must have the labels
# expected by the manifests (app=mysql and app=todoapp).

echo "==> Checking Kubernetes cluster"
kubectl cluster-info
kubectl get nodes --show-labels

echo "==> Tainting MySQL nodes (if labeled app=mysql)"
while IFS= read -r node; do
  [[ -z "$node" ]] && continue
  kubectl taint nodes "$node" app=mysql:NoSchedule --overwrite
done < <(kubectl get nodes -l app=mysql -o name)

echo "==> Installing ingress-nginx controller for kind"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

echo "==> Deploying MySQL resources"
kubectl apply -f .infrastructure/mysql/ns.yml
kubectl apply -f .infrastructure/mysql/configMap.yml
kubectl apply -f .infrastructure/mysql/secret.yml
kubectl apply -f .infrastructure/mysql/service.yml
kubectl apply -f .infrastructure/mysql/statefulSet.yml

echo "==> Deploying ToDo app resources"
kubectl apply -f .infrastructure/app/ns.yml
kubectl apply -f .infrastructure/app/pv.yml
kubectl apply -f .infrastructure/app/pvc.yml
kubectl apply -f .infrastructure/app/secret.yml
kubectl apply -f .infrastructure/app/configMap.yml
kubectl apply -f .infrastructure/app/clusterIp.yml
kubectl apply -f .infrastructure/app/nodeport.yml
kubectl apply -f .infrastructure/app/hpa.yml
kubectl apply -f .infrastructure/app/deployment.yml

# Uncomment if the repository contains the ingress manifest and it is configured:
# kubectl apply -f .infrastructure/ingress/ingress.yml

echo "==> Waiting for workloads (these commands may time out if images, storage, or configuration are invalid)"
kubectl -n mysql rollout status statefulset/mysql --timeout=180s
kubectl -n todoapp rollout status deployment/todoapp --timeout=180s

echo "==> Deployment summary"
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get statefulset,deployment,service,pvc -n mysql
kubectl get deployment,service,pvc -n todoapp

echo "==> Done"