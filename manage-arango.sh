#!/usr/bin/env bash

# Manage a local single-node ArangoDB-on-Minikube setup.
#
# What this script does:
# - starts/stops Minikube
# - installs the ArangoDB Kubernetes operator if needed
# - deploys/deletes the single-server ArangoDeployment
# - keeps a Minikube host mount alive in the background
# - opens a local UI port-forward
#
# Why the mount is handled here:
# - `minikube mount` is a foreground process
# - if the terminal exits, the mount exits too
# - `minikube start --mount` / `--mount-string` are not dependable enough to rely on

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.state"
MOUNT_PID_FILE="${STATE_DIR}/minikube-mount.pid"
MOUNT_LOG_FILE="${STATE_DIR}/minikube-mount.log"
UI_PID_FILE="${STATE_DIR}/arango-ui.pid"
UI_LOG_FILE="${STATE_DIR}/arango-ui.log"

PROFILE="${MINIKUBE_PROFILE:-minikube}"
K8S_VERSION="${K8S_VERSION:-v1.30.14}"
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-4}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-8192}"
MINIKUBE_DISK_SIZE="${MINIKUBE_DISK_SIZE:-40g}"

ARANGO_OPERATOR_VERSION="${ARANGO_OPERATOR_VERSION:-1.4.2}"
ARANGO_DEPLOYMENT_NAME="${ARANGO_DEPLOYMENT_NAME:-single-server}"
ARANGO_IMPORT_SOURCE="${ARANGO_IMPORT_SOURCE:-${SCRIPT_DIR}/arango-import}"
ARANGO_IMPORT_TARGET="${ARANGO_IMPORT_TARGET:-/mnt/arango-import}"
ARANGO_IMPORT_CONTAINER_PATH="${ARANGO_IMPORT_CONTAINER_PATH:-/imports}"
ARANGO_UI_LOCAL_PORT="${ARANGO_UI_LOCAL_PORT:-8529}"
ARANGO_JWT_SECRET_NAME="${ARANGO_JWT_SECRET_NAME:-single-server-jwt}"
ARANGO_ROOT_PASSWORD_SECRET_NAME="${ARANGO_ROOT_PASSWORD_SECRET_NAME:-arango-root-pwd}"
ARANGO_ROOT_PASSWORD_FILE="${STATE_DIR}/arango-root-password.txt"

BUNDLE_DIR="${BUNDLE_DIR:-${SCRIPT_DIR}/kubernetes-${ARANGO_OPERATOR_VERSION}}"
CRD_FILE="${BUNDLE_DIR}/arango-crd.yaml"
OPERATOR_FILE="${BUNDLE_DIR}/arango-deployment.yaml"
STORAGE_FILE="${BUNDLE_DIR}/arango-storage.yaml"
DEPLOYMENT_FILE="${BUNDLE_DIR}/single-server.yaml"

mkdir -p "${STATE_DIR}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  start           Start Minikube
  stop            Stop Minikube
  delete-cluster  Delete Minikube cluster
  mount           Start the import-folder mount in the background
  umount          Stop the backgrounded import-folder mount
  ui-bg           Start the ArangoDB UI port-forward in the background
  ui-stop         Stop the backgrounded ArangoDB UI port-forward
  create-secrets  Create JWT and root password secrets if missing
  install-operator Install ArangoDB operator CRDs/controllers
  deploy          Apply ${DEPLOYMENT_FILE##*/}
  undeploy        Delete the ArangoDB deployment
  status          Show Minikube, mount, pod, and service status
  ui              Port-forward the ArangoDB UI to localhost
  shell           Open a shell in the ArangoDB pod
  import-example  Show example arangoimport commands
  all-up          Start Minikube, mount, install operator, and deploy
  all-down        Remove deployment, stop mount, and stop Minikube

Environment overrides:
  MINIKUBE_PROFILE
  K8S_VERSION
  MINIKUBE_DRIVER
  MINIKUBE_CPUS
  MINIKUBE_MEMORY
  MINIKUBE_DISK_SIZE
  ARANGO_OPERATOR_VERSION
  BUNDLE_DIR
  ARANGO_IMPORT_SOURCE
  ARANGO_IMPORT_TARGET
  ARANGO_UI_LOCAL_PORT
  ARANGO_JWT_SECRET_NAME
  ARANGO_ROOT_PASSWORD_SECRET_NAME
  ARANGO_ROOT_PASSWORD
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

ensure_prereqs() {
  require_cmd minikube
  require_cmd kubectl
}

log_step() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
  fi
}

ensure_bundle_files() {
  local file
  for file in "${CRD_FILE}" "${OPERATOR_FILE}" "${STORAGE_FILE}" "${DEPLOYMENT_FILE}"; do
    [[ -f "${file}" ]] || {
      echo "Required bundle file not found: ${file}" >&2
      exit 1
    }
  done
}

wait_for_cluster_ready() {
  ensure_prereqs
  log_step "Waiting for Minikube node to become Ready"
  kubectl wait --for=condition=Ready node --all --timeout=180s
  log_step "Waiting for core Kubernetes pods to recover"
  kubectl wait --for=condition=Ready pod -n kube-system -l k8s-app=kube-dns --timeout=180s || true
  kubectl wait --for=condition=Ready pod -n kube-system -l component=kube-apiserver --timeout=180s || true
  kubectl wait --for=condition=Ready pod -n kube-system -l component=kube-controller-manager --timeout=180s || true
  kubectl wait --for=condition=Ready pod -n kube-system -l component=kube-scheduler --timeout=180s || true
  log_step "Kubernetes control plane is ready"
}

wait_for_operator_ready() {
  ensure_prereqs
  log_step "Waiting for Arango operator deployments to become available"
  kubectl wait --for=condition=Available deployment/arango-deployment-operator --timeout=180s
  kubectl wait --for=condition=Available deployment/arango-storage-operator --timeout=180s || true
  log_step "Waiting for Arango operator pods to become Ready"
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=kube-arangodb --timeout=180s || true
  log_step "Arango operators are ready"
}

wait_for_arango_pod() {
  ensure_prereqs
  local attempts=0
  log_step "Waiting for ArangoDB pod to be created"

  until kubectl get pod -l "arango_deployment=${ARANGO_DEPLOYMENT_NAME}" -o name 2>/dev/null | rg . >/dev/null; do
    attempts=$((attempts + 1))
    if (( attempts > 60 )); then
      echo "Timed out waiting for ArangoDB pod to appear" >&2
      return 1
    fi
    if (( attempts == 1 || attempts % 5 == 0 )); then
      log_step "Still waiting for ArangoDB pod object to appear"
    fi
    sleep 2
  done
  log_step "ArangoDB pod object found"
}

wait_for_arango_deployment_ready() {
  ensure_prereqs
  local attempts=0
  local ready=""
  log_step "Waiting for ArangoDeployment ${ARANGO_DEPLOYMENT_NAME} to report Ready=True"

  until [[ "${ready}" == "True" ]]; do
    ready="$(kubectl get "arangodeployment/${ARANGO_DEPLOYMENT_NAME}" -o jsonpath="{.status.conditions[?(@.type=='Ready')].status}" 2>/dev/null || true)"
    if [[ "${ready}" == "True" ]]; then
      log_step "ArangoDeployment ${ARANGO_DEPLOYMENT_NAME} is Ready=True"
      return 0
    fi

    attempts=$((attempts + 1))
    if (( attempts > 90 )); then
      echo "Timed out waiting for ArangoDeployment ${ARANGO_DEPLOYMENT_NAME} to become Ready=True" >&2
      kubectl get arangodeployments || true
      return 1
    fi
    if (( attempts == 1 || attempts % 5 == 0 )); then
      log_step "Still waiting for ArangoDeployment readiness"
      kubectl get arangodeployments || true
    fi
    sleep 2
  done
}

minikube_started() {
  minikube status -p "${PROFILE}" >/dev/null 2>&1
}

start_minikube() {
  ensure_prereqs
  mkdir -p "${ARANGO_IMPORT_SOURCE}"
  log_step "Starting Minikube profile ${PROFILE}"
  minikube start \
    --profile="${PROFILE}" \
    --driver="${MINIKUBE_DRIVER}" \
    --kubernetes-version="${K8S_VERSION}" \
    --cpus="${MINIKUBE_CPUS}" \
    --memory="${MINIKUBE_MEMORY}" \
    --disk-size="${MINIKUBE_DISK_SIZE}"
  wait_for_cluster_ready
}

stop_minikube() {
  ensure_prereqs
  stop_ui_background || true
  minikube stop --profile="${PROFILE}"
}

delete_cluster() {
  ensure_prereqs
  stop_ui_background || true
  stop_mount || true
  minikube delete --profile="${PROFILE}"
}

mount_running() {
  [[ -f "${MOUNT_PID_FILE}" ]] || return 1
  local pid
  pid="$(<"${MOUNT_PID_FILE}")"
  kill -0 "${pid}" >/dev/null 2>&1
}

ui_running() {
  [[ -f "${UI_PID_FILE}" ]] || return 1
  local pid
  pid="$(<"${UI_PID_FILE}")"
  kill -0 "${pid}" >/dev/null 2>&1
}

start_mount() {
  ensure_prereqs
  if ! minikube_started; then
    echo "Minikube is not running. Run: $0 start" >&2
    exit 1
  fi

  mkdir -p "${ARANGO_IMPORT_SOURCE}"

  if mount_running; then
    echo "Mount already running with pid $(<"${MOUNT_PID_FILE}")"
    echo "Log: ${MOUNT_LOG_FILE}"
    return 0
  fi

  echo "Starting background mount:"
  echo "  ${ARANGO_IMPORT_SOURCE}:${ARANGO_IMPORT_TARGET}"

  nohup minikube mount \
    --profile="${PROFILE}" \
    "${ARANGO_IMPORT_SOURCE}:${ARANGO_IMPORT_TARGET}" \
    >"${MOUNT_LOG_FILE}" 2>&1 &

  echo $! > "${MOUNT_PID_FILE}"
  sleep 2

  if mount_running; then
    echo "Mount running with pid $(<"${MOUNT_PID_FILE}")"
    echo "Log: ${MOUNT_LOG_FILE}"
  else
    echo "Mount failed to stay up. Check ${MOUNT_LOG_FILE}" >&2
    exit 1
  fi
}

stop_mount() {
  if ! [[ -f "${MOUNT_PID_FILE}" ]]; then
    echo "Mount pid file not found"
    return 0
  fi

  local pid
  pid="$(<"${MOUNT_PID_FILE}")"

  if kill -0 "${pid}" >/dev/null 2>&1; then
    kill "${pid}"
    for _ in 1 2 3 4 5; do
      if ! kill -0 "${pid}" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  fi

  rm -f "${MOUNT_PID_FILE}"
  echo "Mount stopped"
}

start_ui_background() {
  ensure_prereqs

  if ui_running; then
    log_step "UI port-forward already running with pid $(<"${UI_PID_FILE}")"
    log_step "UI log: ${UI_LOG_FILE}"
    return 0
  fi

  log_step "Starting background UI port-forward on https://127.0.0.1:${ARANGO_UI_LOCAL_PORT}"
  nohup kubectl port-forward "svc/${ARANGO_DEPLOYMENT_NAME}-ea" "${ARANGO_UI_LOCAL_PORT}:8529" \
    >"${UI_LOG_FILE}" 2>&1 &

  echo $! > "${UI_PID_FILE}"
  sleep 2

  if ui_running; then
    log_step "UI port-forward running with pid $(<"${UI_PID_FILE}")"
    log_step "UI log: ${UI_LOG_FILE}"
  else
    echo "UI port-forward failed to stay up. Check ${UI_LOG_FILE}" >&2
    exit 1
  fi
}

stop_ui_background() {
  if ! [[ -f "${UI_PID_FILE}" ]]; then
    echo "UI pid file not found"
    return 0
  fi

  local pid
  pid="$(<"${UI_PID_FILE}")"

  if kill -0 "${pid}" >/dev/null 2>&1; then
    kill "${pid}"
    for _ in 1 2 3 4 5; do
      if ! kill -0 "${pid}" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  fi

  rm -f "${UI_PID_FILE}"
  echo "UI port-forward stopped"
}

install_operator() {
  ensure_prereqs
  ensure_bundle_files
  kubectl get crd arangodeployments.database.arangodb.com >/dev/null 2>&1 && {
    log_step "ArangoDB operator CRD already present"
    return 0
  }

  log_step "Installing ArangoDB CRDs and operator manifests"
  kubectl apply -f "${CRD_FILE}"
  kubectl apply -f "${OPERATOR_FILE}"
  kubectl apply -f "${STORAGE_FILE}"
}

ensure_secrets() {
  ensure_prereqs

  if ! kubectl get secret "${ARANGO_JWT_SECRET_NAME}" >/dev/null 2>&1; then
    local jwt_token
    jwt_token="$(generate_secret)"
    kubectl create secret generic "${ARANGO_JWT_SECRET_NAME}" \
      --from-literal=token="${jwt_token}"
    log_step "Created JWT secret: ${ARANGO_JWT_SECRET_NAME}"
  else
    log_step "JWT secret already exists: ${ARANGO_JWT_SECRET_NAME}"
  fi

  if ! kubectl get secret "${ARANGO_ROOT_PASSWORD_SECRET_NAME}" >/dev/null 2>&1; then
    local root_password
    root_password="${ARANGO_ROOT_PASSWORD:-$(generate_secret)}"

    kubectl create secret generic "${ARANGO_ROOT_PASSWORD_SECRET_NAME}" \
      --from-literal=username=root \
      --from-literal=password="${root_password}"

    printf '%s\n' "${root_password}" > "${ARANGO_ROOT_PASSWORD_FILE}"
    chmod 600 "${ARANGO_ROOT_PASSWORD_FILE}"

    log_step "Created root password secret: ${ARANGO_ROOT_PASSWORD_SECRET_NAME}"
    log_step "Saved generated root password to: ${ARANGO_ROOT_PASSWORD_FILE}"
  else
    log_step "Root password secret already exists: ${ARANGO_ROOT_PASSWORD_SECRET_NAME}"
  fi
}

deploy_arango() {
  ensure_prereqs
  ensure_bundle_files
  ensure_secrets
  [[ -f "${DEPLOYMENT_FILE}" ]] || {
    echo "Deployment file not found: ${DEPLOYMENT_FILE}" >&2
    exit 1
  }

  log_step "Applying ArangoDB deployment manifest ${DEPLOYMENT_FILE}"
  kubectl apply -f "${DEPLOYMENT_FILE}"
  wait_for_operator_ready
  wait_for_arango_pod
  log_step "Waiting for ArangoDB pod readiness"
  kubectl wait --for=condition=Ready pod \
    -l "arango_deployment=${ARANGO_DEPLOYMENT_NAME}" \
    --timeout=300s
  log_step "ArangoDB pod is Ready"
  wait_for_arango_deployment_ready
}

undeploy_arango() {
  ensure_prereqs
  kubectl delete -f "${DEPLOYMENT_FILE}" --ignore-not-found=true
}

show_status() {
  ensure_prereqs
  echo "== Minikube =="
  minikube status --profile="${PROFILE}" || true
  echo
  echo "== Mount =="
  if mount_running; then
    echo "running (pid $(<"${MOUNT_PID_FILE}"))"
    echo "source: ${ARANGO_IMPORT_SOURCE}"
    echo "target: ${ARANGO_IMPORT_TARGET}"
    echo "log: ${MOUNT_LOG_FILE}"
  else
    echo "not running"
  fi
  echo
  echo "== Kubernetes =="
  kubectl get nodes || true
  echo
  kubectl get pods -A || true
  echo
  kubectl get svc || true
  echo
  echo "== Secrets =="
  kubectl get secret "${ARANGO_JWT_SECRET_NAME}" "${ARANGO_ROOT_PASSWORD_SECRET_NAME}" || true
  echo
  echo "== UI =="
  if ui_running; then
    echo "running (pid $(<"${UI_PID_FILE}"))"
    echo "url: https://127.0.0.1:${ARANGO_UI_LOCAL_PORT}"
    echo "log: ${UI_LOG_FILE}"
  else
    echo "not running"
  fi
}

open_ui() {
  ensure_prereqs
  echo "Forwarding ArangoDB UI to https://127.0.0.1:${ARANGO_UI_LOCAL_PORT}"
  echo "Use root with the current deployment password settings."
  kubectl port-forward "svc/${ARANGO_DEPLOYMENT_NAME}-ea" "${ARANGO_UI_LOCAL_PORT}:8529"
}

open_shell() {
  ensure_prereqs
  local pod
  pod="$(kubectl get pod -l "arango_deployment=${ARANGO_DEPLOYMENT_NAME}" -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "${pod}" ]] || {
    echo "No ArangoDB pod found" >&2
    exit 1
  }
  kubectl exec -it "${pod}" -- /bin/sh
}

show_import_example() {
  cat <<EOF
Example import commands from inside the ArangoDB pod:

  $(basename "$0") shell
  arangoimport --file ${ARANGO_IMPORT_CONTAINER_PATH}/nodes.jsonl --type jsonl --collection vertices
  arangoimport --file ${ARANGO_IMPORT_CONTAINER_PATH}/edges.jsonl --type jsonl --collection edges

Local source directory:
  ${ARANGO_IMPORT_SOURCE}

Mounted inside Minikube node at:
  ${ARANGO_IMPORT_TARGET}

Mounted inside ArangoDB container at:
  ${ARANGO_IMPORT_CONTAINER_PATH}
EOF
}

all_up() {
  start_minikube
  start_mount
  install_operator
  deploy_arango
  start_ui_background
  show_status
}

all_down() {
  stop_ui_background || true
  undeploy_arango || true
  stop_mount || true
  stop_minikube || true
}

case "${1:-}" in
  start) start_minikube ;;
  stop) stop_minikube ;;
  delete-cluster) delete_cluster ;;
  mount) start_mount ;;
  umount) stop_mount ;;
  ui-bg) start_ui_background ;;
  ui-stop) stop_ui_background ;;
  create-secrets) ensure_secrets ;;
  install-operator) install_operator ;;
  deploy) deploy_arango ;;
  undeploy) undeploy_arango ;;
  status) show_status ;;
  ui) open_ui ;;
  shell) open_shell ;;
  import-example) show_import_example ;;
  all-up) all_up ;;
  all-down) all_down ;;
  ""|-h|--help|help) usage ;;
  *)
    echo "Unknown command: $1" >&2
    usage
    exit 1
    ;;
esac
