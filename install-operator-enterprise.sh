#!/usr/bin/env bash
# Install kube-arangodb ENTERPRISE via Helm with storage, webhooks, and gateway feature flags
# required for the Arango Contextual Data Platform (Agentic AI Suite).
#
# Docs: https://docs.arango.ai/contextual-data-platform/install-and-upgrade/online-setup/
#
# Before running: remove the community operator Deployments from raw YAML (if any), e.g.
#   kubectl delete deployment arango-deployment-operator arango-storage-operator -n arango --ignore-not-found
#
# Usage:
#   ./install-operator-enterprise.sh
#   ARANGO_HELM_RELEASE=myrel KUBE_NAMESPACE=myns ./install-operator-enterprise.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${ARANGO_OPERATOR_VERSION:-1.4.2}"
RELEASE="${ARANGO_HELM_RELEASE:-operator}"
NS="${KUBE_NAMESPACE:-arango}"
CHART_URL="https://github.com/arangodb/kube-arangodb/releases/download/${VERSION}/kube-arangodb-enterprise-${VERSION}.tgz"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd kubectl
require_cmd helm

echo "[install-operator-enterprise] Chart: ${CHART_URL}"
echo "[install-operator-enterprise] Namespace: ${NS}  Helm release: ${RELEASE}"

kubectl get namespace "${NS}" >/dev/null 2>&1 || kubectl create namespace "${NS}"

helm upgrade --install "${RELEASE}" "${CHART_URL}" \
  --namespace "${NS}" \
  --set "webhooks.enabled=true" \
  --set "operator.features.storage=true" \
  --set "operator.args[0]=--deployment.feature.gateway=true" \
  --set "operator.architectures={amd64}"

echo
echo "Operator Deployment name follows pattern: arango-${RELEASE}-operator"
echo "Example wait: kubectl wait --for=condition=Available deployment/arango-${RELEASE}-operator -n ${NS} --timeout=300s"
echo "Pods label: app.kubernetes.io/name=kube-arangodb-enterprise"
