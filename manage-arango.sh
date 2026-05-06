#!/usr/bin/env bash

# Manage a local single-node ArangoDB-on-Minikube setup.
#
# What this script does:
# - starts/stops Minikube
# - installs the ArangoDB Kubernetes operator if needed
# - deploys/deletes the single-server ArangoDeployment
# - keeps the Minikube import-folder mount alive in the background
# - opens local port-forwards (optional second port for tooling / mental separation)
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
API_PID_FILE="${STATE_DIR}/arango-api.pid"
API_LOG_FILE="${STATE_DIR}/arango-api.log"

PROFILE="${MINIKUBE_PROFILE:-minikube}"
K8S_VERSION="${K8S_VERSION:-v1.30.14}"
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-4}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-8192}"
MINIKUBE_DISK_SIZE="${MINIKUBE_DISK_SIZE:-40g}"

ARANGO_OPERATOR_VERSION="${ARANGO_OPERATOR_VERSION:-1.4.2}"
ARANGO_DEPLOYMENT_NAME="${ARANGO_DEPLOYMENT_NAME:-single-server}"
# Wait / exec only the single-server *data* pod (name contains -sngl-). Do not match -id- (image discovery) pods.
ARANGO_DB_POD_LABEL_SELECTOR="${ARANGO_DB_POD_LABEL_SELECTOR:-arango_deployment=${ARANGO_DEPLOYMENT_NAME},role=single}"
ARANGO_IMPORT_SOURCE="${ARANGO_IMPORT_SOURCE:-${SCRIPT_DIR}/arango-import}"
ARANGO_IMPORT_TARGET="${ARANGO_IMPORT_TARGET:-/mnt/arango-import}"
ARANGO_IMPORT_CONTAINER_PATH="${ARANGO_IMPORT_CONTAINER_PATH:-/imports}"
# Database PVC data lives on the Minikube VM under this path (native disk; see ArangoLocalStorage localPath).
ARANGO_DATA_TARGET="${ARANGO_DATA_TARGET:-/var/lib/arango-local-data}"
ARANGO_LOCAL_STORAGE_CLASS="${ARANGO_LOCAL_STORAGE_CLASS:-arango-minikube-data}"
# metadata.name in ${LOCAL_STORAGE_FILE}; storage operator creates a same-named DaemonSet that must be Ready
# before PVCs are provisioned (otherwise PV local paths are never mkdir'd and kubelet reports "path does not exist").
ARANGO_LOCAL_STORAGE_CR_NAME="${ARANGO_LOCAL_STORAGE_CR_NAME:-arango-minikube-local-data}"
ARANGO_UI_LOCAL_PORT="${ARANGO_UI_LOCAL_PORT:-8529}"
# Second local port for HTTP clients (curl, Flask dev, etc.). Same Arango process as UI:
# Arango serves Web UI and /_api on port 8529; this is not a security boundary.
ARANGO_API_LOCAL_PORT="${ARANGO_API_LOCAL_PORT:-18529}"
ARANGO_PORT_FORWARD_SVC="${ARANGO_PORT_FORWARD_SVC:-${ARANGO_DEPLOYMENT_NAME}-ea}"
ARANGO_JWT_SECRET_NAME="${ARANGO_JWT_SECRET_NAME:-single-server-jwt}"
ARANGO_ROOT_PASSWORD_SECRET_NAME="${ARANGO_ROOT_PASSWORD_SECRET_NAME:-arango-root-pwd}"
ARANGO_ROOT_PASSWORD_FILE="${STATE_DIR}/arango-root-password.txt"
# If 1/true/yes/on, after deploy imports bundled JSONL via HTTPS REST (curl -k + short port-forward).
ARANGO_LOAD_SAMPLE_DATA="${ARANGO_LOAD_SAMPLE_DATA:-}"
ARANGO_SAMPLE_IMPORT_PF_PORT="${ARANGO_SAMPLE_IMPORT_PF_PORT:-18629}"

BUNDLE_DIR="${BUNDLE_DIR:-${SCRIPT_DIR}/kubernetes-${ARANGO_OPERATOR_VERSION}}"
CRD_FILE="${BUNDLE_DIR}/arango-crd.yaml"
OPERATOR_FILE="${BUNDLE_DIR}/arango-deployment.yaml"
STORAGE_FILE="${BUNDLE_DIR}/arango-storage.yaml"
DEPLOYMENT_FILE="${BUNDLE_DIR}/single-server.yaml"
LOCAL_STORAGE_FILE="${BUNDLE_DIR}/arango-local-storage.yaml"

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
  api-bg          Start a second localhost port-forward (same cluster service; for API tooling)
  api-stop        Stop the backgrounded API port-forward
  create-secrets  Create JWT and root password secrets if missing
  install-operator Install ArangoDB operator CRDs/controllers
  deploy          Apply ${DEPLOYMENT_FILE##*/} (optional: --load-sample-data)
  undeploy        Delete the ArangoDB deployment
  status          Show Minikube, mount, pod, and service status
  ui              Port-forward the ArangoDB UI to localhost (foreground)
  api             Port-forward a second localhost port for HTTP clients (foreground)
  shell           Open a shell in the ArangoDB pod
  import-example  Show example arangoimport and REST import (same as load-sample-data)
  load-sample-data Import bundled JSONL (nodes + edges) via HTTPS REST; needs running ArangoDB
  all-up          Start Minikube, import mount, install operator, and deploy (optional: --load-sample-data)
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
  ARANGO_DB_POD_LABEL_SELECTOR  (default: arango_deployment=<name>,role=single — avoids matching -id- pods)
  ARANGO_IMPORT_SOURCE
  ARANGO_IMPORT_TARGET
  ARANGO_DATA_TARGET  (fallback when CR has no localPath yet; should match ArangoLocalStorage spec — default /var/lib/arango-local-data)
  ARANGO_LOCAL_STORAGE_CLASS
  ARANGO_LOCAL_STORAGE_CR_NAME  (must match metadata.name in arango-local-storage.yaml; default arango-minikube-local-data)
  ARANGO_UI_LOCAL_PORT
  ARANGO_API_LOCAL_PORT
  ARANGO_PORT_FORWARD_SVC  (Service name for kubectl port-forward; default is <ARANGO_DEPLOYMENT_NAME>-ea)
  ARANGO_JWT_SECRET_NAME
  ARANGO_ROOT_PASSWORD_SECRET_NAME
  ARANGO_ROOT_PASSWORD
  ARANGO_LOAD_SAMPLE_DATA   If 1/true/yes/on, deploy/all-up imports bundled sample JSONL (REST via port-forward)
  ARANGO_SAMPLE_IMPORT_PF_PORT  Local port for that import (default 18629; avoid 8529 / ARANGO_API_LOCAL_PORT)
  ARANGO_POD_READY_TIMEOUT_SECONDS  Max seconds to wait for Arango pod Ready (default 600)

Sample files: nodes.jsonl and edges.jsonl under ARANGO_IMPORT_SOURCE (default ./arango-import) → collections nodes, edges.
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

truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# minikube mount + operator init containers: host dirs must be writable by non-root UIDs in the node VM.
ensure_host_bind_mount_permissions() {
  mkdir -p "${ARANGO_IMPORT_SOURCE}"
  local import_abs
  import_abs="$(cd "${ARANGO_IMPORT_SOURCE}" && pwd)"
  chmod 0777 "${import_abs}"
  chmod -R a+rwX "${import_abs}" 2>/dev/null || true
  log_step "Host import dir chmod 0777 + recursive a+rwX (local dev only): ${import_abs}"
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
  for file in "${CRD_FILE}" "${OPERATOR_FILE}" "${STORAGE_FILE}" "${DEPLOYMENT_FILE}" "${LOCAL_STORAGE_FILE}"; do
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
  kubectl wait --for=condition=Available deployment/arango-storage-operator --timeout=180s
  log_step "Waiting for Arango operator pods to become Ready"
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=kube-arangodb --timeout=180s || true
  log_step "Arango operators are ready"
}

wait_for_arango_pod() {
  ensure_prereqs
  local attempts=0
  log_step "Waiting for ArangoDB pod to be created"

  until kubectl get pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -o name 2>/dev/null | rg . >/dev/null; do
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

# Single long kubectl wait prints nothing; chunk waits so Init:* progress is visible.
wait_arango_pod_ready_with_progress() {
  ensure_prereqs
  log_step "Waiting for ArangoDB pod Ready (kube-arangodb init steps; first image pull often needs a few minutes)"
  local total=0
  local max="${ARANGO_POD_READY_TIMEOUT_SECONDS:-600}"
  # Short kubectl wait chunks + chmod each iteration so host perms stay open while inits run (9p / root files).
  local chunk=3
  local status_col

  while (( total < max )); do
    normalize_arango_pv_host_tree_if_bound
    if kubectl wait --for=condition=Ready pod \
      -l "${ARANGO_DB_POD_LABEL_SELECTOR}" \
      --timeout="${chunk}s" 2>/dev/null; then
      log_step "ArangoDB pod is Ready"
      return 0
    fi
    total=$((total + chunk))
    log_step "Pod not Ready yet (${total}s / ${max}s); status:"
    kubectl get pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -o wide 2>/dev/null || true
    status_col="$(kubectl get pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -o wide --no-headers 2>/dev/null | awk '{print $3}' | head -1)"
    case "${status_col}" in
      *Error*|*CrashLoopBackOff*|ErrImagePull|ImagePullBackOff|CreateContainerConfigError)
        echo "ArangoDB pod is in a failed state (${status_col}); aborting wait (see init logs below)." >&2
        kubectl describe pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" 2>/dev/null | tail -80 >&2 || true
        dump_arango_db_pod_init_debug
        return 1
        ;;
    esac
  done

  echo "Timed out waiting for ArangoDB pod Ready after ${max}s" >&2
  kubectl describe pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" 2>/dev/null | tail -80 >&2 || true
  dump_arango_db_pod_init_debug
  return 1
}

# On timeout or Init:Error, operator inits are the fastest way to see the real failure (not just "not Ready").
dump_arango_db_pod_init_debug() {
  ensure_prereqs
  local pod c containers
  pod="$(kubectl get pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${pod}" ]] || return 0
  echo "--- ArangoDB pod init debug (pod=${pod}) ---" >&2
  kubectl get pod "${pod}" -o wide 2>/dev/null || kubectl get pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -o wide 2>/dev/null || true
  echo "--- Init container logs (most recent run; empty if never started) ---" >&2
  containers="$(kubectl get pod "${pod}" -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null || true)"
  [[ -n "${containers}" ]] || containers="init-lifecycle uuid version-check"
  for c in ${containers}; do
    echo "### logs -c ${c} ###" >&2
    if kubectl get pod "${pod}" >/dev/null 2>&1; then
      kubectl logs "${pod}" -c "${c}" --tail=80 2>&1 | sed 's/^/  /' >&2 || true
    else
      kubectl logs -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -c "${c}" --tail=80 --prefix=true 2>&1 | sed 's/^/  /' >&2 || true
    fi
  done
}

wait_for_arango_deployment_ready() {
  ensure_prereqs
  local attempts=0
  # kubectl's "READY" column for ArangoDeployment is driven by the UpToDate condition
  # (see arango-crd.yaml additionalPrinterColumns), not necessarily type "Ready".
  local up_to_date=""
  log_step "Waiting for ArangoDeployment ${ARANGO_DEPLOYMENT_NAME} to report UpToDate=True (same signal as kubectl READY column)"

  until [[ "${up_to_date}" == "True" ]]; do
    up_to_date="$(kubectl get "arangodeployment/${ARANGO_DEPLOYMENT_NAME}" -o jsonpath="{.status.conditions[?(@.type=='UpToDate')].status}" 2>/dev/null || true)"
    if [[ "${up_to_date}" == "True" ]]; then
      log_step "ArangoDeployment ${ARANGO_DEPLOYMENT_NAME} is UpToDate=True"
      return 0
    fi

    attempts=$((attempts + 1))
    if (( attempts > 90 )); then
      echo "Timed out waiting for ArangoDeployment ${ARANGO_DEPLOYMENT_NAME} UpToDate=True" >&2
      echo "Status conditions:" >&2
      kubectl get "arangodeployment/${ARANGO_DEPLOYMENT_NAME}" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}' 2>/dev/null || true
      echo >&2
      kubectl describe "arangodeployment/${ARANGO_DEPLOYMENT_NAME}" 2>/dev/null | tail -40 >&2 || true
      kubectl get pvc -l "arango_deployment=${ARANGO_DEPLOYMENT_NAME}" -o wide 2>/dev/null || kubectl get pvc || true
      return 1
    fi
    if (( attempts == 1 || attempts % 5 == 0 )); then
      log_step "Still waiting for ArangoDeployment UpToDate=True"
      kubectl get arangodeployments || true
      kubectl get "arangodeployment/${ARANGO_DEPLOYMENT_NAME}" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}' 2>/dev/null || true
      kubectl get pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -o wide 2>/dev/null || true
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
  stop_api_background || true
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

api_running() {
  [[ -f "${API_PID_FILE}" ]] || return 1
  local pid
  pid="$(<"${API_PID_FILE}")"
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

ensure_local_storage_applied() {
  ensure_prereqs
  [[ -f "${LOCAL_STORAGE_FILE}" ]] || {
    echo "Local storage manifest not found: ${LOCAL_STORAGE_FILE}" >&2
    exit 1
  }

  log_step "Applying ArangoLocalStorage manifest ${LOCAL_STORAGE_FILE##*/}"
  kubectl apply -f "${LOCAL_STORAGE_FILE}"

  log_step "Waiting for StorageClass ${ARANGO_LOCAL_STORAGE_CLASS}"
  local attempts=0
  until kubectl get storageclass "${ARANGO_LOCAL_STORAGE_CLASS}" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if (( attempts > 60 )); then
      echo "Timed out waiting for StorageClass ${ARANGO_LOCAL_STORAGE_CLASS}. Is arango-storage-operator running?" >&2
      kubectl get deployment arango-storage-operator 2>/dev/null || true
      return 1
    fi
    if (( attempts == 1 || attempts % 5 == 0 )); then
      log_step "Still waiting for StorageClass ${ARANGO_LOCAL_STORAGE_CLASS}"
    fi
    sleep 2
  done
  log_step "StorageClass ${ARANGO_LOCAL_STORAGE_CLASS} is available"

  log_step "Waiting for local storage provisioner DaemonSet/${ARANGO_LOCAL_STORAGE_CR_NAME} (creates PV subdirs on the node)"
  attempts=0
  until kubectl get "daemonset/${ARANGO_LOCAL_STORAGE_CR_NAME}" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if (( attempts > 90 )); then
      echo "Timed out waiting for DaemonSet ${ARANGO_LOCAL_STORAGE_CR_NAME}. Is ArangoLocalStorage applied and storage operator healthy?" >&2
      kubectl get arangolocalstorages 2>/dev/null || true
      kubectl get daemonset 2>/dev/null || true
      return 1
    fi
    if (( attempts == 1 || attempts % 5 == 0 )); then
      log_step "Still waiting for DaemonSet ${ARANGO_LOCAL_STORAGE_CR_NAME}"
    fi
    sleep 2
  done
  kubectl rollout status "daemonset/${ARANGO_LOCAL_STORAGE_CR_NAME}" --timeout=300s
  log_step "Local storage provisioner DaemonSet is rolled out"
  ensure_arango_node_pv_root
}

# PV subdirs are created under this path on the Minikube node; it must be real disk inside the VM (not 9p).
ensure_arango_node_pv_root() {
  ensure_prereqs
  if ! minikube_started; then
    return 0
  fi
  local root cr_path
  cr_path="$(kubectl get arangolocalstorage "${ARANGO_LOCAL_STORAGE_CR_NAME}" -o jsonpath='{.spec.localPath[0]}' 2>/dev/null || true)"
  if [[ -n "${cr_path}" ]]; then
    root="${cr_path}"
    log_step "Ensuring PV root directory on Minikube node at ${root} (from ArangoLocalStorage spec.localPath)"
  else
    root="${ARANGO_DATA_TARGET}"
    log_step "Ensuring PV root directory on Minikube node at ${root} (no localPath in CR yet; using ARANGO_DATA_TARGET)"
  fi
  minikube ssh -p "${PROFILE}" -- "sudo mkdir -p '${root}' && sudo chmod 0777 '${root}'" >/dev/null 2>&1 || {
    echo "Failed to mkdir/chmod ${root} on Minikube node" >&2
    return 1
  }
}

# kube-arangodb normally mkdir's via the node provisioner (DaemonSet) before binding the PV.
# On Minikube (provisioner pod restarts / storage races) the PV can bind while the directory is still
# missing, leaving the DB pod stuck in Init with FailedMount on the Local volume.
normalize_arango_pv_host_tree() {
  local local_path="${1:-}"
  local local_root
  [[ -n "${local_path}" ]] || return 0
  local_root="$(kubectl get arangolocalstorage "${ARANGO_LOCAL_STORAGE_CR_NAME}" -o jsonpath='{.spec.localPath[0]}' 2>/dev/null || true)"
  [[ -n "${local_root}" ]] || local_root="${ARANGO_DATA_TARGET}"
  [[ "${local_path}" == "${local_root}"/* ]] || return 0
  minikube ssh -p "${PROFILE}" -- "sudo mkdir -p '${local_path}' && sudo chmod -R 0777 '${local_path}'" >/dev/null 2>&1 || true
}

# Re-apply chmod on the node while waiting for the pod.
normalize_arango_pv_host_tree_if_bound() {
  local pvc_name pv_name local_path
  pvc_name="$(kubectl get pvc -l "arango_deployment=${ARANGO_DEPLOYMENT_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || return 0
  [[ -n "${pvc_name}" ]] || return 0
  [[ "$(kubectl get pvc "${pvc_name}" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Bound" ]] || return 0
  pv_name="$(kubectl get pvc "${pvc_name}" -o jsonpath='{.spec.volumeName}' 2>/dev/null)" || return 0
  [[ -n "${pv_name}" ]] || return 0
  local_path="$(kubectl get pv "${pv_name}" -o jsonpath='{.spec.local.path}' 2>/dev/null)" || return 0
  normalize_arango_pv_host_tree "${local_path}"
}

repair_arango_local_storage_volume_paths() {
  ensure_prereqs
  local waited=0
  local max_wait=120
  local pvc_name phase pv_name local_path local_root

  local_root="$(kubectl get arangolocalstorage "${ARANGO_LOCAL_STORAGE_CR_NAME}" -o jsonpath='{.spec.localPath[0]}' 2>/dev/null || true)"
  [[ -n "${local_root}" ]] || local_root="${ARANGO_DATA_TARGET}"

  log_step "Ensuring PV local directories exist under ${local_root} on the Minikube node (ArangoLocalStorage localPath, else ARANGO_DATA_TARGET)"
  while (( waited < max_wait )); do
    pvc_name="$(kubectl get pvc -l "arango_deployment=${ARANGO_DEPLOYMENT_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${pvc_name}" ]]; then
      phase="$(kubectl get pvc "${pvc_name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      if [[ "${phase}" == "Bound" ]]; then
        pv_name="$(kubectl get pvc "${pvc_name}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
        if [[ -n "${pv_name}" ]]; then
          local_path="$(kubectl get pv "${pv_name}" -o jsonpath='{.spec.local.path}' 2>/dev/null || true)"
          if [[ -n "${local_path}" ]]; then
            if [[ "${local_path}" != "${local_root}"/* ]]; then
              log_step "PV ${pv_name} uses path ${local_path} (not under ${local_root}); skipping mkdir repair"
              return 0
            fi
            if minikube ssh -p "${PROFILE}" -- "test -d '${local_path}'" >/dev/null 2>&1; then
              log_step "PV path already present on node: ${local_path}"
            else
              log_step "Creating missing PV path on node: ${local_path}"
              minikube ssh -p "${PROFILE}" -- "sudo mkdir -p '${local_path}'" >/dev/null 2>&1 || {
                echo "Failed to mkdir ${local_path} inside Minikube VM" >&2
                return 1
              }
            fi
            log_step "Normalizing PV data perms for ${local_path}"
            normalize_arango_pv_host_tree "${local_path}"
            minikube ssh -p "${PROFILE}" -- "sudo chmod -R 0777 '${local_path}'" >/dev/null 2>&1 || true
            minikube ssh -p "${PROFILE}" -- "test -d '${local_path}'" >/dev/null 2>&1 || {
              echo "Path ${local_path} still missing after repair" >&2
              return 1
            }
            log_step "PV path ready: ${local_path}"
            return 0
          fi
        fi
      fi
    fi
    if (( waited == 0 || waited % 20 == 0 )); then
      log_step "Still waiting for PVC/PV to resolve local path (${waited}s / ${max_wait}s)"
    fi
    sleep 2
    waited=$((waited + 2))
  done
  echo "Timed out after ${max_wait}s waiting to repair Arango local PV paths (check PVC and storage operator logs)" >&2
  return 1
}

# With WaitForFirstConsumer, the pod is scheduled (and the kubelet starts mounting Local volumes) before
# repair can mkdir the PV path. The first mount then fails ("path does not exist"); delete the pod once
# so the replacement mounts after the path exists on the node.
recycle_arango_db_pod_after_pv_repair() {
  ensure_prereqs
  kubectl get pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -o name 2>/dev/null | rg . >/dev/null || return 0
  log_step "Recycling ArangoDB data pod so kubelet remounts Local volumes after PV path exists on the node"
  kubectl delete pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" --wait=true --timeout=180s >/dev/null 2>&1 || {
    echo "Warning: pod delete did not complete within 180s; continuing anyway" >&2
  }
  sleep 2
  wait_for_arango_pod
}

start_ui_background() {
  ensure_prereqs

  if ui_running; then
    log_step "UI port-forward already running with pid $(<"${UI_PID_FILE}")"
    log_step "UI log: ${UI_LOG_FILE}"
    return 0
  fi

  log_step "Starting background UI port-forward on https://127.0.0.1:${ARANGO_UI_LOCAL_PORT} (svc/${ARANGO_PORT_FORWARD_SVC})"
  nohup kubectl port-forward "svc/${ARANGO_PORT_FORWARD_SVC}" "${ARANGO_UI_LOCAL_PORT}:8529" \
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

start_api_background() {
  ensure_prereqs

  if [[ "${ARANGO_API_LOCAL_PORT}" == "${ARANGO_UI_LOCAL_PORT}" ]]; then
    echo "ARANGO_API_LOCAL_PORT must differ from ARANGO_UI_LOCAL_PORT" >&2
    exit 1
  fi

  if api_running; then
    log_step "API port-forward already running with pid $(<"${API_PID_FILE}")"
    log_step "API log: ${API_LOG_FILE}"
    return 0
  fi

  log_step "Starting background API port-forward on https://127.0.0.1:${ARANGO_API_LOCAL_PORT} (svc/${ARANGO_PORT_FORWARD_SVC})"
  nohup kubectl port-forward "svc/${ARANGO_PORT_FORWARD_SVC}" "${ARANGO_API_LOCAL_PORT}:8529" \
    >"${API_LOG_FILE}" 2>&1 &

  echo $! > "${API_PID_FILE}"
  sleep 2

  if api_running; then
    log_step "API port-forward running with pid $(<"${API_PID_FILE}")"
    log_step "API log: ${API_LOG_FILE}"
  else
    echo "API port-forward failed to stay up. Check ${API_LOG_FILE}" >&2
    exit 1
  fi
}

stop_api_background() {
  if ! [[ -f "${API_PID_FILE}" ]]; then
    echo "API pid file not found"
    return 0
  fi

  local pid
  pid="$(<"${API_PID_FILE}")"

  if kill -0 "${pid}" >/dev/null 2>&1; then
    kill "${pid}"
    for _ in 1 2 3 4 5; do
      if ! kill -0 "${pid}" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  fi

  rm -f "${API_PID_FILE}"
  echo "API port-forward stopped"
}

install_operator() {
  ensure_prereqs
  ensure_bundle_files
  log_step "Applying ArangoDB CRDs and operator manifests (idempotent)"
  kubectl apply -f "${CRD_FILE}"
  kubectl apply -f "${OPERATOR_FILE}"
  kubectl apply -f "${STORAGE_FILE}"
}

# Writes .state/arango-root-password.txt from the live secret so the UI password is always on disk after deploy/setup.
sync_arango_root_password_file_from_secret() {
  ensure_prereqs
  local pw
  pw="$(kubectl get secret "${ARANGO_ROOT_PASSWORD_SECRET_NAME}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d | tr -d '\n\r')" || true
  if [[ -z "${pw}" ]]; then
    if kubectl get secret "${ARANGO_ROOT_PASSWORD_SECRET_NAME}" >/dev/null 2>&1; then
      echo "Secret ${ARANGO_ROOT_PASSWORD_SECRET_NAME} has no readable .data.password; not updating ${ARANGO_ROOT_PASSWORD_FILE}" >&2
    fi
    return 0
  fi
  mkdir -p "${STATE_DIR}"
  umask 077
  printf '%s\n' "${pw}" > "${ARANGO_ROOT_PASSWORD_FILE}"
  chmod 600 "${ARANGO_ROOT_PASSWORD_FILE}" 2>/dev/null || true
  log_step "Root password copied to ${ARANGO_ROOT_PASSWORD_FILE}"
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

    log_step "Created root password secret: ${ARANGO_ROOT_PASSWORD_SECRET_NAME}"
  else
    log_step "Root password secret already exists: ${ARANGO_ROOT_PASSWORD_SECRET_NAME}"
  fi

  sync_arango_root_password_file_from_secret
}

deploy_arango() {
  ensure_prereqs
  ensure_bundle_files
  ensure_secrets
  ensure_host_bind_mount_permissions
  [[ -f "${DEPLOYMENT_FILE}" ]] || {
    echo "Deployment file not found: ${DEPLOYMENT_FILE}" >&2
    exit 1
  }

  wait_for_operator_ready
  ensure_local_storage_applied

  log_step "Applying ArangoDB deployment manifest ${DEPLOYMENT_FILE}"
  kubectl apply -f "${DEPLOYMENT_FILE}"
  wait_for_arango_pod
  repair_arango_local_storage_volume_paths
  recycle_arango_db_pod_after_pv_repair
  wait_arango_pod_ready_with_progress
  wait_for_arango_deployment_ready

  if truthy "${ARANGO_LOAD_SAMPLE_DATA:-}"; then
    load_sample_data
  fi
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
  echo "== Database PV root (ArangoLocalStorage localPath on Minikube node) =="
  local cr_path
  cr_path="$(kubectl get arangolocalstorage "${ARANGO_LOCAL_STORAGE_CR_NAME}" -o jsonpath='{.spec.localPath[0]}' 2>/dev/null || true)"
  if [[ -n "${cr_path}" ]]; then
    echo "Cluster localPath: ${cr_path}  (authoritative; RocksDB data lives here on the VM)"
  else
    echo "Cluster: no ${ARANGO_LOCAL_STORAGE_CR_NAME} or empty localPath yet"
  fi
  echo "ARANGO_DATA_TARGET=${ARANGO_DATA_TARGET}  (script fallback until the CR exists; optional override for consistency)"
  if [[ -n "${cr_path}" && "${cr_path}" != "${ARANGO_DATA_TARGET}" ]]; then
    echo "Note: env does not match cluster localPath. Data uses the cluster path. Export ARANGO_DATA_TARGET=${cr_path} for matching logs, or tear down Arango + PVCs + ArangoLocalStorage and re-apply arango-local-storage.yaml if you changed localPath in git."
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
  echo
  echo "== API port-forward (optional; same Arango as UI) =="
  if api_running; then
    echo "running (pid $(<"${API_PID_FILE}"))"
    echo "url: https://127.0.0.1:${ARANGO_API_LOCAL_PORT}"
    echo "log: ${API_LOG_FILE}"
  else
    echo "not running"
  fi
}

open_ui() {
  ensure_prereqs
  echo "Forwarding ArangoDB UI to https://127.0.0.1:${ARANGO_UI_LOCAL_PORT}"
  echo "Use root with the current deployment password settings."
  kubectl port-forward "svc/${ARANGO_PORT_FORWARD_SVC}" "${ARANGO_UI_LOCAL_PORT}:8529"
}

open_api() {
  ensure_prereqs
  if [[ "${ARANGO_API_LOCAL_PORT}" == "${ARANGO_UI_LOCAL_PORT}" ]]; then
    echo "ARANGO_API_LOCAL_PORT must differ from ARANGO_UI_LOCAL_PORT" >&2
    exit 1
  fi
  echo "Forwarding ArangoDB HTTP (UI + /_api) to https://127.0.0.1:${ARANGO_API_LOCAL_PORT}"
  kubectl port-forward "svc/${ARANGO_PORT_FORWARD_SVC}" "${ARANGO_API_LOCAL_PORT}:8529"
}

open_shell() {
  ensure_prereqs
  local pod
  pod="$(kubectl get pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "${pod}" ]] || {
    echo "No ArangoDB pod found" >&2
    exit 1
  }
  kubectl exec -it "${pod}" -- /bin/sh
}

load_sample_data() {
  ensure_prereqs
  require_cmd curl

  local nodes_file edges_file root_pw pf_port
  nodes_file="${ARANGO_IMPORT_SOURCE%/}/nodes.jsonl"
  edges_file="${ARANGO_IMPORT_SOURCE%/}/edges.jsonl"
  [[ -f "${nodes_file}" && -f "${edges_file}" ]] || {
    echo "Sample data not found. Expected:" >&2
    echo "  ${nodes_file}" >&2
    echo "  ${edges_file}" >&2
    exit 1
  }

  root_pw="$(kubectl get secret "${ARANGO_ROOT_PASSWORD_SECRET_NAME}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d | tr -d '\n\r')"
  if [[ -z "${root_pw}" && -f "${ARANGO_ROOT_PASSWORD_FILE}" ]]; then
    root_pw="$(tr -d '\n\r' < "${ARANGO_ROOT_PASSWORD_FILE}")"
  fi
  [[ -n "${root_pw}" ]] || {
    echo "Could not read root password from secret ${ARANGO_ROOT_PASSWORD_SECRET_NAME} or ${ARANGO_ROOT_PASSWORD_FILE}" >&2
    exit 1
  }

  pf_port="${ARANGO_SAMPLE_IMPORT_PF_PORT}"
  if [[ "${pf_port}" == "${ARANGO_UI_LOCAL_PORT}" || "${pf_port}" == "${ARANGO_API_LOCAL_PORT}" ]]; then
    echo "ARANGO_SAMPLE_IMPORT_PF_PORT (${pf_port}) must differ from ARANGO_UI_LOCAL_PORT and ARANGO_API_LOCAL_PORT" >&2
    exit 1
  fi

  log_step "Importing sample JSONL via HTTPS REST (kubectl port-forward ${pf_port}→svc/${ARANGO_PORT_FORWARD_SVC}:8529; curl -k)"

  # In-pod arangoimport to 127.0.0.1 often returns 401 with the operator TLS/auth stack; match browser path from host.
  (
    set -euo pipefail
    kubectl port-forward "svc/${ARANGO_PORT_FORWARD_SVC}" "${pf_port}:8529" >/dev/null 2>&1 &
    local pf_pid=$!
    trap 'kill "${pf_pid}" 2>/dev/null; wait "${pf_pid}" 2>/dev/null || true' EXIT

    sleep 2

    local base="https://127.0.0.1:${pf_port}"
    local ver
    ver="$(curl -skS -u "root:${root_pw}" "${base}/_api/version")" || true
    if ! echo "${ver}" | grep -q '"server"'; then
      echo "REST auth/version check failed on ${base}. Response:" >&2
      echo "${ver}" >&2
      echo "If the database on the Minikube node still holds an older dataset but the Kubernetes root secret changed, reset PVC/node data and redeploy." >&2
      exit 1
    fi

    log_step "POST /_api/collection (nodes + edges) if missing"
    curl -skS -u "root:${root_pw}" -X POST "${base}/_db/_system/_api/collection" \
      -H "Content-Type: application/json" \
      -d '{"name":"nodes","type":2}' >/dev/null 2>&1 || true
    curl -skS -u "root:${root_pw}" -X POST "${base}/_db/_system/_api/collection" \
      -H "Content-Type: application/json" \
      -d '{"name":"edges","type":3}' >/dev/null 2>&1 || true

    local resp
    log_step "POST /_api/import (nodes)"
    resp="$(curl -skS -u "root:${root_pw}" -X POST \
      "${base}/_db/_system/_api/import?collection=nodes&type=documents&createCollection=false&onDuplicate=ignore" \
      -H "Content-Type: application/octet-stream" \
      --data-binary "@${nodes_file}")"
    echo "${resp}" | grep -qE '"error"[[:space:]]*:[[:space:]]*false' || {
      echo "nodes import failed:" >&2
      echo "${resp}" >&2
      exit 1
    }

    log_step "POST /_api/import (edges)"
    resp="$(curl -skS -u "root:${root_pw}" -X POST \
      "${base}/_db/_system/_api/import?collection=edges&type=documents&createCollection=false&onDuplicate=ignore" \
      -H "Content-Type: application/octet-stream" \
      --data-binary "@${edges_file}")"
    echo "${resp}" | grep -qE '"error"[[:space:]]*:[[:space:]]*false' || {
      echo "edges import failed:" >&2
      echo "${resp}" >&2
      exit 1
    }

    trap - EXIT
    kill "${pf_pid}" 2>/dev/null
    wait "${pf_pid}" 2>/dev/null || true
  ) || exit 1

  log_step "Sample data loaded (collections nodes, edges)"
}

show_import_example() {
  cat <<EOF
Bundled sample import (same as ./$(basename "$0") load-sample-data or deploy/all-up --load-sample-data):
  HTTPS + curl -k from the host via a short kubectl port-forward to svc/${ARANGO_PORT_FORWARD_SVC} (see load_sample_data).

Recommended one-shot after cluster is up:

  ARANGO_LOAD_SAMPLE_DATA=1 ./$(basename "$0") deploy
  # or: ./$(basename "$0") deploy --load-sample-data
  # or: ./$(basename "$0") all-up --load-sample-data

Manual arangoimport from inside the pod (may 401 depending on operator/TLS; REST above is more reliable):

  $(basename "$0") shell
  arangoimport --file ${ARANGO_IMPORT_CONTAINER_PATH}/nodes.jsonl --type jsonl --collection nodes --create-collection true
  arangoimport --file ${ARANGO_IMPORT_CONTAINER_PATH}/edges.jsonl --type jsonl --collection edges --create-collection true --create-collection-type edge

Bundled sample graph: document collection nodes, edge collection edges (_from/_to like nodes/<_key>).

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
  start_api_background
  show_status
}

all_down() {
  stop_api_background || true
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
  api-bg) start_api_background ;;
  api-stop) stop_api_background ;;
  create-secrets) ensure_secrets ;;
  install-operator) install_operator ;;
  deploy)
    case "${2:-}" in
      "") ;;
      --load-sample-data) ARANGO_LOAD_SAMPLE_DATA=1 ;;
      *) echo "Unknown option for deploy: $2 (use --load-sample-data)" >&2; exit 1 ;;
    esac
    deploy_arango
    ;;
  undeploy) undeploy_arango ;;
  status) show_status ;;
  ui) open_ui ;;
  api) open_api ;;
  shell) open_shell ;;
  import-example) show_import_example ;;
  load-sample-data) load_sample_data ;;
  all-up)
    case "${2:-}" in
      "") ;;
      --load-sample-data) ARANGO_LOAD_SAMPLE_DATA=1 ;;
      *) echo "Unknown option for all-up: $2 (use --load-sample-data)" >&2; exit 1 ;;
    esac
    all_up
    ;;
  all-down) all_down ;;
  ""|-h|--help|help) usage ;;
  *)
    echo "Unknown command: $1" >&2
    usage
    exit 1
    ;;
esac
