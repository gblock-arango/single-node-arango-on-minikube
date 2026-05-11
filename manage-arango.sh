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
# Written when OPENAI_API_KEY is set in the environment (same pattern as the root password file).
OPENAI_API_KEY_FILE="${OPENAI_API_KEY_FILE:-${STATE_DIR}/openai-api-key}"
# If 1/true/yes/on, after deploy imports bundled JSONL via HTTPS REST (curl -k + short port-forward).
ARANGO_LOAD_SAMPLE_DATA="${ARANGO_LOAD_SAMPLE_DATA:-}"
ARANGO_SAMPLE_IMPORT_PF_PORT="${ARANGO_SAMPLE_IMPORT_PF_PORT:-18629}"

BUNDLE_DIR="${BUNDLE_DIR:-${SCRIPT_DIR}/kubernetes-${ARANGO_OPERATOR_VERSION}}"
CRD_FILE="${BUNDLE_DIR}/arango-crd.yaml"
OPERATOR_FILE="${BUNDLE_DIR}/arango-deployment.yaml"
STORAGE_FILE="${BUNDLE_DIR}/arango-storage.yaml"
# community = raw YAML operators. enterprise = kube-arangodb-enterprise Helm chart (webhooks + gateway).
ARANGO_OPERATOR_FLAVOR="${ARANGO_OPERATOR_FLAVOR:-enterprise}"
if [[ -n "${ARANGO_DEPLOYMENT_FILE:-}" ]]; then
  DEPLOYMENT_FILE="${ARANGO_DEPLOYMENT_FILE}"
elif [[ "${ARANGO_OPERATOR_FLAVOR}" == "enterprise" ]]; then
  DEPLOYMENT_FILE="${BUNDLE_DIR}/single-server-enterprise-ai.yaml"
else
  DEPLOYMENT_FILE="${BUNDLE_DIR}/single-server.yaml"
fi
LOCAL_STORAGE_FILE="${BUNDLE_DIR}/arango-local-storage.yaml"
ARANGO_HELM_RELEASE="${ARANGO_HELM_RELEASE:-operator}"
ARANGO_LICENSE_IDENTITY_URL="${ARANGO_LICENSE_IDENTITY_URL:-https://license.arango.ai/_api/v1/identity}"
# Namespace for Arango operators, secrets, ArangoDeployment, services, and PVCs (Arango online setup often uses "arango").
ARANGO_K8S_NAMESPACE="${ARANGO_K8S_NAMESPACE:-arango}"
# Optional local S3-compatible store for CDP (MLflow / GraphML, etc.); see online setup step 8 and README.
MINIO_NAMESPACE="${MINIO_NAMESPACE:-minio}"
ARANGO_MINIO_BUCKET="${ARANGO_MINIO_BUCKET:-arango-platform-storage}"
MINIO_STACK_FILE="${BUNDLE_DIR}/minio-stack.yaml"
MINIO_BUCKET_JOB_FILE="${BUNDLE_DIR}/minio-bucket-job.yaml"

mkdir -p "${STATE_DIR}"

# kubectl scoped to ARANGO_K8S_NAMESPACE (do not use for cluster-scoped CRDs, StorageClass, PV, ArangoLocalStorage, or kube-system).
kns() {
  kubectl --namespace "${ARANGO_K8S_NAMESPACE}" "$@"
}

# Community operator YAML uses metadata.namespace: default; rewrite for ARANGO_K8S_NAMESPACE.
kubectl_apply_community_operator_bundle() {
  local f="$1"
  sed "s/namespace: default/namespace: ${ARANGO_K8S_NAMESPACE}/g" "${f}" | kubectl apply -f -
}

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
  install-operator Install kube-arangodb operator(s); enterprise flavor uses Helm (default); community uses raw YAML
  deploy          Apply ${DEPLOYMENT_FILE##*/} (options: --load-sample-data, --with-platform, --with-minio)
  undeploy        Delete the ArangoDB deployment
  status          Show Minikube, mount, pod, and service status
  ui              Port-forward the ArangoDB UI to localhost (foreground)
  api             Port-forward a second localhost port for HTTP clients (foreground)
  shell           Open a shell in the ArangoDB pod
  import-example  Show example arangoimport and REST import (same as load-sample-data)
  load-sample-data Import bundled JSONL (nodes + edges) via HTTPS REST; needs running ArangoDB
  all-up          Start Minikube, import mount, install operator, and deploy (options: --load-sample-data, --with-platform, --with-minio)
  all-down        Remove deployment, stop mount, and stop Minikube
  check-license   Verify enterprise license credentials only (HTTPS to license.arango.ai; env vars and/or secret arango-license-key; no Minikube if both id+secret are in env)
  platform-install Install Contextual Data Platform package (arangodb_operator_platform + platform.yaml) after DB is up
  minio-install   Install MinIO + ArangoPlatformStorage (S3 backend) for platform object storage (enterprise; after deploy)

Further commands (enterprise / Contextual Data Platform only):
  create-license-secret      Create/update arango-license-key from ARANGO_LICENSE_CLIENT_ID / _SECRET
  install-operator-enterprise Install enterprise kube-arangodb via Helm (after removing community operators)
  to-enterprise [--wipe-data] Migrate a running community stack: remove community operators, install enterprise
                  operator, apply single-server-enterprise-ai.yaml. Requires license env vars and Helm.
                  For full CDP suite after DB is up: all-up --with-platform or platform-install (needs platform.yaml from Arango).
                  Object storage (optional): all-up --with-minio or minio-install (MinIO in namespace MINIO_NAMESPACE; see README).

Environment overrides:
  MINIKUBE_PROFILE
  K8S_VERSION
  MINIKUBE_DRIVER
  MINIKUBE_CPUS
  MINIKUBE_MEMORY
  MINIKUBE_DISK_SIZE
  ARANGO_OPERATOR_VERSION
  BUNDLE_DIR
  ARANGO_K8S_NAMESPACE  Namespace for operators, secrets, ArangoDeployment, and related workloads (default: arango)
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
  OPENAI_API_KEY  If set, copied to \${OPENAI_API_KEY_FILE} (default \${STATE_DIR}/openai-api-key, mode 600) during deploy/all-up for local tools
  ARANGO_DEPLOYMENT_FILE  Override path to ArangoDeployment YAML (default: single-server-enterprise-ai.yaml if enterprise, else single-server.yaml)
  ARANGO_OPERATOR_FLAVOR  enterprise (default) or community — enterprise needs Helm + arango-license-key secret
  ARANGO_LICENSE_CLIENT_ID / ARANGO_LICENSE_CLIENT_SECRET  Enterprise license (for create-license-secret / to-enterprise)
  ARANGO_LICENSE_SKIP_PREFLIGHT  If 1/true/yes/on, skip HTTPS check against license.arango.ai (enterprise only)
  ARANGO_LICENSE_PREFER_ENV  If 1/true/yes/on, use env credentials before secret arango-license-key (default: secret first when it exists)
  ARANGO_PLATFORM_YAML  Path to Contextual Data Platform package file from Arango (optional default: ./platform.yaml next to this script)
  ARANGO_PLATFORM_CLI  Path to arangodb_operator_platform binary (default: auto-download to \${STATE_DIR}/arangodb_operator_platform)
  ARANGO_PLATFORM_NAMESPACE  Namespace for arangodb_operator_platform package install (default: same as ARANGO_K8S_NAMESPACE)
  ARANGO_PLATFORM_PACKAGE_INSTALL  If 1/true/yes/on with all-up, same as --with-platform (requires platform.yaml)
  ARANGO_MINIO_INSTALL  If 1/true/yes/on with all-up/deploy, same as --with-minio (local MinIO + ArangoPlatformStorage)
  MINIO_NAMESPACE  Kubernetes namespace for MinIO workloads (default: minio)
  MINIO_ROOT_USER / MINIO_ROOT_PASSWORD  MinIO root credentials (defaults: minioadmin / miniopassword — dev only)
  ARANGO_MINIO_BUCKET  Bucket created in MinIO and referenced by ArangoPlatformStorage (default: arango-platform-storage)
  WIPE_ENTERPRISE_PVC  Set to 1 by: to-enterprise --wipe-data (delete DB PVCs before enterprise deploy)

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

enterprise_operator_deployment() {
  printf 'arango-%s-operator' "${ARANGO_HELM_RELEASE}"
}

wait_for_operator_ready() {
  ensure_prereqs
  log_step "Waiting for Arango operator deployments to become available"
  case "${ARANGO_OPERATOR_FLAVOR}" in
    enterprise)
      kns wait --for=condition=Available "deployment/$(enterprise_operator_deployment)" --timeout=300s
      log_step "Waiting for enterprise operator pod to become Ready"
      kns wait --for=condition=Ready pod \
        -l "app.kubernetes.io/name=kube-arangodb-enterprise,app.kubernetes.io/instance=${ARANGO_HELM_RELEASE}" \
        --timeout=300s || true
      ;;
    *)
      kns wait --for=condition=Available deployment/arango-deployment-operator --timeout=180s
      kns wait --for=condition=Available deployment/arango-storage-operator --timeout=180s
      log_step "Waiting for Arango operator pods to become Ready"
      kns wait --for=condition=Ready pod -l app.kubernetes.io/name=kube-arangodb --timeout=180s || true
      ;;
  esac
  log_step "Arango operators are ready"
}

wait_for_arango_pod() {
  ensure_prereqs
  local attempts=0
  log_step "Waiting for ArangoDB pod to be created"

  until kns get pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -o name 2>/dev/null | rg . >/dev/null; do
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
    if kns wait --for=condition=Ready pod \
      -l "${ARANGO_DB_POD_LABEL_SELECTOR}" \
      --timeout="${chunk}s" 2>/dev/null; then
      log_step "ArangoDB pod is Ready"
      return 0
    fi
    total=$((total + chunk))
    log_step "Pod not Ready yet (${total}s / ${max}s); status:"
    kns get pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -o wide 2>/dev/null || true
    status_col="$(kns get pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -o wide --no-headers 2>/dev/null | awk '{print $3}' | head -1)"
    case "${status_col}" in
      *Error*|*CrashLoopBackOff*|ErrImagePull|ImagePullBackOff|CreateContainerConfigError)
        echo "ArangoDB pod is in a failed state (${status_col}); aborting wait (see init logs below)." >&2
        kns describe pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" 2>/dev/null | tail -80 >&2 || true
        dump_arango_db_pod_init_debug
        return 1
        ;;
    esac
  done

  echo "Timed out waiting for ArangoDB pod Ready after ${max}s" >&2
  kns describe pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" 2>/dev/null | tail -80 >&2 || true
  dump_arango_db_pod_init_debug
  return 1
}

# On timeout or Init:Error, operator inits are the fastest way to see the real failure (not just "not Ready").
dump_arango_db_pod_init_debug() {
  ensure_prereqs
  local pod c containers
  pod="$(kns get pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${pod}" ]] || return 0
  echo "--- ArangoDB pod init debug (pod=${pod}) ---" >&2
  kns get pod "${pod}" -o wide 2>/dev/null || kns get pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -o wide 2>/dev/null || true
  echo "--- Init container logs (most recent run; empty if never started) ---" >&2
  containers="$(kns get pod "${pod}" -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null || true)"
  [[ -n "${containers}" ]] || containers="init-lifecycle uuid version-check"
  for c in ${containers}; do
    echo "### logs -c ${c} ###" >&2
    if kns get pod "${pod}" >/dev/null 2>&1; then
      kns logs "${pod}" -c "${c}" --tail=80 2>&1 | sed 's/^/  /' >&2 || true
    else
      kns logs -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -c "${c}" --tail=80 --prefix=true 2>&1 | sed 's/^/  /' >&2 || true
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
    up_to_date="$(kns get "arangodeployment/${ARANGO_DEPLOYMENT_NAME}" -o jsonpath="{.status.conditions[?(@.type=='UpToDate')].status}" 2>/dev/null || true)"
    if [[ "${up_to_date}" == "True" ]]; then
      log_step "ArangoDeployment ${ARANGO_DEPLOYMENT_NAME} is UpToDate=True"
      return 0
    fi

    attempts=$((attempts + 1))
    if (( attempts > 90 )); then
      echo "Timed out waiting for ArangoDeployment ${ARANGO_DEPLOYMENT_NAME} UpToDate=True" >&2
      echo "Status conditions:" >&2
      kns get "arangodeployment/${ARANGO_DEPLOYMENT_NAME}" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}' 2>/dev/null || true
      echo >&2
      kns describe "arangodeployment/${ARANGO_DEPLOYMENT_NAME}" 2>/dev/null | tail -40 >&2 || true
      kns get pvc -l "arango_deployment=${ARANGO_DEPLOYMENT_NAME}" -o wide 2>/dev/null || kns get pvc || true
      return 1
    fi
    if (( attempts == 1 || attempts % 5 == 0 )); then
      log_step "Still waiting for ArangoDeployment UpToDate=True"
      kns get arangodeployments || true
      kns get "arangodeployment/${ARANGO_DEPLOYMENT_NAME}" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}' 2>/dev/null || true
      kns get pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -o wide 2>/dev/null || true
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
      kns get deployment arango-storage-operator 2>/dev/null || true
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
  until kns get "daemonset/${ARANGO_LOCAL_STORAGE_CR_NAME}" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if (( attempts > 90 )); then
      echo "Timed out waiting for DaemonSet ${ARANGO_LOCAL_STORAGE_CR_NAME}. Is ArangoLocalStorage applied and storage operator healthy?" >&2
      kubectl get arangolocalstorages 2>/dev/null || true
      kns get daemonset 2>/dev/null || true
      return 1
    fi
    if (( attempts == 1 || attempts % 5 == 0 )); then
      log_step "Still waiting for DaemonSet ${ARANGO_LOCAL_STORAGE_CR_NAME}"
    fi
    sleep 2
  done
  kns rollout status "daemonset/${ARANGO_LOCAL_STORAGE_CR_NAME}" --timeout=300s
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
  pvc_name="$(kns get pvc -l "arango_deployment=${ARANGO_DEPLOYMENT_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || return 0
  [[ -n "${pvc_name}" ]] || return 0
  [[ "$(kns get pvc "${pvc_name}" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Bound" ]] || return 0
  pv_name="$(kns get pvc "${pvc_name}" -o jsonpath='{.spec.volumeName}' 2>/dev/null)" || return 0
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
    pvc_name="$(kns get pvc -l "arango_deployment=${ARANGO_DEPLOYMENT_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${pvc_name}" ]]; then
      phase="$(kns get pvc "${pvc_name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      if [[ "${phase}" == "Bound" ]]; then
        pv_name="$(kns get pvc "${pvc_name}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
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
  kns get pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -o name 2>/dev/null | rg . >/dev/null || return 0
  log_step "Recycling ArangoDB data pod so kubelet remounts Local volumes after PV path exists on the node"
  kns delete pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" --wait=true --timeout=180s >/dev/null 2>&1 || {
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
  # nohup executes a real binary; kns is a shell function — use kubectl -n here.
  nohup kubectl --namespace "${ARANGO_K8S_NAMESPACE}" port-forward "svc/${ARANGO_PORT_FORWARD_SVC}" "${ARANGO_UI_LOCAL_PORT}:8529" \
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
  nohup kubectl --namespace "${ARANGO_K8S_NAMESPACE}" port-forward "svc/${ARANGO_PORT_FORWARD_SVC}" "${ARANGO_API_LOCAL_PORT}:8529" \
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
  if [[ "${ARANGO_OPERATOR_FLAVOR}" == "enterprise" ]]; then
    require_cmd helm
    log_step "Applying ArangoDB CRDs (idempotent pre-step for enterprise operator)"
    kubectl apply -f "${CRD_FILE}"
    install_operator_enterprise
    return
  fi
  log_step "Applying ArangoDB CRDs and operator manifests (idempotent)"
  kubectl apply -f "${CRD_FILE}"
  kubectl_apply_community_operator_bundle "${OPERATOR_FILE}"
  kubectl_apply_community_operator_bundle "${STORAGE_FILE}"
}

install_operator_enterprise() {
  ensure_prereqs
  require_cmd helm
  local chart_ver chart_url
  chart_ver="${ARANGO_OPERATOR_VERSION}"
  chart_url="https://github.com/arangodb/kube-arangodb/releases/download/${chart_ver}/kube-arangodb-enterprise-${chart_ver}.tgz"
  log_step "Installing enterprise kube-arangodb via Helm (webhooks + gateway + storage operator)"
  preflight_enterprise_license_api
  log_step "Removing legacy community operator Deployments if present (avoid duplicate controllers with Helm)"
  kubectl delete deployment arango-deployment-operator arango-storage-operator -n default --ignore-not-found=true --wait=true --timeout=180s || true
  kubectl delete deployment arango-deployment-operator arango-storage-operator -n "${ARANGO_K8S_NAMESPACE}" --ignore-not-found=true --wait=true --timeout=180s || true
  prepare_enterprise_helm_storage_crd
  kubectl get namespace "${ARANGO_K8S_NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${ARANGO_K8S_NAMESPACE}"
  helm upgrade --install "${ARANGO_HELM_RELEASE}" "${chart_url}" \
    --namespace "${ARANGO_K8S_NAMESPACE}" \
    --set "webhooks.enabled=true" \
    --set "operator.features.storage=true" \
    --set "operator.args[0]=--deployment.feature.gateway=true" \
    --set "operator.architectures={amd64}"
}

# Strip CR/LF and leading/trailing whitespace (portal / bashrc copy-paste).
trim_license_field() {
  printf '%s' "${1:-}" | tr -d '\r\n' | sed -e 's/^[[:blank:]]*//' -e 's/[[:blank:]]*$//'
}

# HTTP Basic for id:secret. Do not use curl -u id:secret — a ':' inside the secret is parsed as the user/password delimiter.
arango_license_basic_auth_header_line() {
  local id="$1" sec="$2" b64
  if command -v openssl >/dev/null 2>&1; then
    b64="$(printf '%s:%s' "${id}" "${sec}" | openssl base64 -A 2>/dev/null)" || b64=""
    if [[ -n "${b64}" ]]; then
      printf 'Authorization: Basic %s' "${b64}"
      return 0
    fi
  fi
  if b64="$(printf '%s:%s' "${id}" "${sec}" | base64 -w0 2>/dev/null)" && [[ -n "${b64}" ]]; then
    printf 'Authorization: Basic %s' "${b64}"
    return 0
  fi
  b64="$(printf '%s:%s' "${id}" "${sec}" | base64 | tr -d '\n')"
  printf 'Authorization: Basic %s' "${b64}"
}

create_license_secret() {
  ensure_prereqs
  local id sec
  id="$(trim_license_field "${ARANGO_LICENSE_CLIENT_ID:-}")"
  sec="$(trim_license_field "${ARANGO_LICENSE_CLIENT_SECRET:-}")"
  if [[ -z "${id}" || -z "${sec}" ]]; then
    echo "Set ARANGO_LICENSE_CLIENT_ID and ARANGO_LICENSE_CLIENT_SECRET (from Arango license credentials), then re-run." >&2
    exit 1
  fi
  kubectl create secret generic arango-license-key \
    --namespace="${ARANGO_K8S_NAMESPACE}" \
    --from-literal=license-client-id="${id}" \
    --from-literal=license-client-secret="${sec}" \
    --dry-run=client -o yaml | kubectl apply -f -
  log_step "Secret arango-license-key applied (license client id + secret)"
}

# Sets __ARANGO_LIC_ID and __ARANGO_LIC_SECRET (caller-internal globals). Returns 0 if both non-empty.
# Prefer secret arango-license-key when present (same source the operator uses). Otherwise env ARANGO_LICENSE_*.
# If .bashrc exports stale env vars, they previously masked a freshly created secret and caused confusing 401s.
# Set ARANGO_LICENSE_PREFER_ENV=1 to test env credentials even when a secret exists.
load_enterprise_license_credentials_for_preflight() {
  local from_env_id from_env_sec
  from_env_id="$(trim_license_field "${ARANGO_LICENSE_CLIENT_ID:-}")"
  from_env_sec="$(trim_license_field "${ARANGO_LICENSE_CLIENT_SECRET:-}")"

  if truthy "${ARANGO_LICENSE_PREFER_ENV:-}"; then
    __ARANGO_LIC_ID="${from_env_id}"
    __ARANGO_LIC_SECRET="${from_env_sec}"
    if [[ -n "${__ARANGO_LIC_ID}" && -n "${__ARANGO_LIC_SECRET}" ]]; then
      log_step "License credentials: using environment (ARANGO_LICENSE_PREFER_ENV is set)"
      return 0
    fi
  fi

  if kns get secret arango-license-key >/dev/null 2>&1; then
    __ARANGO_LIC_ID="$(trim_license_field "$(kns get secret arango-license-key -o jsonpath='{.data.license-client-id}' 2>/dev/null | base64 -d 2>/dev/null || true)")"
    __ARANGO_LIC_SECRET="$(trim_license_field "$(kns get secret arango-license-key -o jsonpath='{.data.license-client-secret}' 2>/dev/null | base64 -d 2>/dev/null || true)")"
    if [[ -n "${__ARANGO_LIC_ID}" && -n "${__ARANGO_LIC_SECRET}" ]]; then
      if [[ -n "${from_env_id}" || -n "${from_env_sec}" ]]; then
        log_step "License credentials: using Kubernetes secret arango-license-key (env ARANGO_LICENSE_* is ignored while this secret exists — unset or align env)"
      else
        log_step "License credentials: using Kubernetes secret arango-license-key"
      fi
      return 0
    fi
  fi

  __ARANGO_LIC_ID="${from_env_id}"
  __ARANGO_LIC_SECRET="${from_env_sec}"
  if [[ -n "${__ARANGO_LIC_ID}" && -n "${__ARANGO_LIC_SECRET}" ]]; then
    log_step "License credentials: using environment ARANGO_LICENSE_CLIENT_ID / ARANGO_LICENSE_CLIENT_SECRET"
    return 0
  fi
  __ARANGO_LIC_ID=""
  __ARANGO_LIC_SECRET=""
  return 1
}

# Calls Arango license service with client id + secret (HTTP Basic). Fails fast on bad credentials or no route to *.license.arango.ai.
preflight_enterprise_license_api() {
  [[ "${ARANGO_OPERATOR_FLAVOR}" == "enterprise" ]] || return 0
  truthy "${ARANGO_LICENSE_SKIP_PREFLIGHT:-}" && {
    if truthy "${ARANGO_LICENSE_PREFLIGHT_REQUIRE_CREDENTIALS:-}"; then
      echo "ARANGO_LICENSE_SKIP_PREFLIGHT is set; cannot run a dedicated license check (unset it or use deploy without this flag)." >&2
      exit 1
    fi
    log_step "Skipping Arango license preflight (ARANGO_LICENSE_SKIP_PREFLIGHT is set)"
    return 0
  }
  [[ -n "${ARANGO_LICENSE_PREFLIGHT_DONE:-}" ]] && return 0

  local id sec http_code body
  if ! load_enterprise_license_credentials_for_preflight; then
    if truthy "${ARANGO_LICENSE_PREFLIGHT_REQUIRE_CREDENTIALS:-}"; then
      echo "No license credentials found for check-license." >&2
      echo "Set ARANGO_LICENSE_CLIENT_ID and ARANGO_LICENSE_CLIENT_SECRET, or ensure kubectl can read secret arango-license-key in namespace ${ARANGO_K8S_NAMESPACE}." >&2
      exit 1
    fi
    log_step "Skipping Arango license API preflight (no credentials in env and no readable arango-license-key secret)"
    return 0
  fi
  id="${__ARANGO_LIC_ID}"
  sec="${__ARANGO_LIC_SECRET}"
  unset __ARANGO_LIC_ID __ARANGO_LIC_SECRET

  require_cmd curl
  # Do not use curl -f: the host root often returns 404 while TLS + routing to *.license.arango.ai still work.
  log_step "Checking Arango license service reachability (${ARANGO_LICENSE_IDENTITY_URL})"
  if ! curl -sSI --connect-timeout 8 --max-time 15 "https://license.arango.ai/" >/dev/null 2>&1; then
    echo "Cannot open TLS connection to https://license.arango.ai (DNS/TLS/firewall). Enterprise needs access to *.license.arango.ai — see https://docs.arango.ai/contextual-data-platform/license-management/" >&2
    exit 1
  fi

  body="$(mktemp)"
  local auth_line
  auth_line="$(arango_license_basic_auth_header_line "${id}" "${sec}")"
  http_code="$(curl -sS -o "${body}" -w '%{http_code}' --connect-timeout 10 --max-time 30 \
    -H "${auth_line}" "${ARANGO_LICENSE_IDENTITY_URL}" || true)"
  case "${http_code}" in
    200)
      ARANGO_LICENSE_PREFLIGHT_DONE=1
      log_step "License credentials accepted by ${ARANGO_LICENSE_IDENTITY_URL} (HTTP 200)"
      if command -v python3 >/dev/null 2>&1; then
        cust="$(python3 - "${body}" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    name = (d.get("customer") or {}).get("name") or ""
    if name:
        print(name)
except Exception:
    pass
PY
)"
        [[ -n "${cust}" ]] && log_step "License identity customer: ${cust}"
      fi
      rm -f "${body}"
      return 0
      ;;
    401|403)
      rm -f "${body}"
      echo "Arango license credentials rejected (HTTP ${http_code}) at ${ARANGO_LICENSE_IDENTITY_URL}." >&2
      echo "Confirm these are **license** client id + secret for Kubernetes / Contextual Data Platform (see Arango onboarding / online setup), not a different product API key." >&2
      echo "If the secret contains ':', use the updated script (Authorization header); re-export trimmed values and run: ./manage-arango.sh create-license-secret && ./manage-arango.sh check-license" >&2
      exit 1
      ;;
    *)
      echo "Unexpected response from Arango license service: HTTP ${http_code} (URL: ${ARANGO_LICENSE_IDENTITY_URL})." >&2
      echo "Response body (first 800 bytes):" >&2
      head -c 800 "${body}" >&2 || true
      echo >&2
      rm -f "${body}"
      echo "If this is a transient outage, retry later; to skip this check: ARANGO_LICENSE_SKIP_PREFLIGHT=1" >&2
      exit 1
      ;;
  esac
}

# Standalone: same HTTPS identity probe as enterprise preflight; exits 1 if credentials missing/invalid or network fails.
check_license_command() {
  require_cmd curl
  if [[ -z "${ARANGO_LICENSE_CLIENT_ID:-}" || -z "${ARANGO_LICENSE_CLIENT_SECRET:-}" ]]; then
    require_cmd kubectl
  fi
  local saved_flavor saved_done
  saved_flavor="${ARANGO_OPERATOR_FLAVOR:-}"
  saved_done="${ARANGO_LICENSE_PREFLIGHT_DONE:-}"
  ARANGO_OPERATOR_FLAVOR=enterprise
  unset ARANGO_LICENSE_PREFLIGHT_DONE
  ARANGO_LICENSE_PREFLIGHT_REQUIRE_CREDENTIALS=1
  preflight_enterprise_license_api
  ARANGO_OPERATOR_FLAVOR="${saved_flavor}"
  if [[ -n "${saved_done}" ]]; then
    ARANGO_LICENSE_PREFLIGHT_DONE="${saved_done}"
  else
    unset ARANGO_LICENSE_PREFLIGHT_DONE
  fi
  unset ARANGO_LICENSE_PREFLIGHT_REQUIRE_CREDENTIALS
  log_step "check-license: OK"
}

# Path to platform.yaml: explicit ARANGO_PLATFORM_YAML, else ${SCRIPT_DIR}/platform.yaml if present.
resolve_arango_platform_yaml_path() {
  if [[ -n "${ARANGO_PLATFORM_YAML:-}" && -f "${ARANGO_PLATFORM_YAML}" ]]; then
    printf '%s' "${ARANGO_PLATFORM_YAML}"
    return 0
  fi
  if [[ -f "${SCRIPT_DIR}/platform.yaml" ]]; then
    printf '%s' "${SCRIPT_DIR}/platform.yaml"
    return 0
  fi
  return 1
}

# Download arangodb_operator_platform from kube-arangodb GitHub release matching ARANGO_OPERATOR_VERSION.
ensure_arangodb_operator_platform_cli() {
  local dest ver url arch os_suffix
  dest="${ARANGO_PLATFORM_CLI:-${STATE_DIR}/arangodb_operator_platform}"
  if [[ -x "${dest}" ]]; then
    log_step "Using existing arangodb_operator_platform: ${dest}"
    return 0
  fi
  require_cmd curl
  ver="${ARANGO_OPERATOR_VERSION}"
  arch=amd64
  case "$(uname -m)" in
    aarch64|arm64) arch=arm64 ;;
    x86_64|amd64) arch=amd64 ;;
    *)
      echo "Unsupported machine $(uname -m); set ARANGO_PLATFORM_CLI to your arangodb_operator_platform binary path" >&2
      exit 1
      ;;
  esac
  case "$(uname -s)" in
    Linux) os_suffix="linux_${arch}" ;;
    Darwin) os_suffix="darwin_${arch}" ;;
    *)
      echo "Unsupported OS $(uname -s); set ARANGO_PLATFORM_CLI to your arangodb_operator_platform binary path" >&2
      exit 1
      ;;
  esac
  url="https://github.com/arangodb/kube-arangodb/releases/download/${ver}/arangodb_operator_platform_${os_suffix}"
  log_step "Downloading arangodb_operator_platform (${ver}, ${os_suffix}) -> ${dest}"
  mkdir -p "${STATE_DIR}"
  curl -fSL --connect-timeout 25 --max-time 120 --retry 2 -o "${dest}.part" "${url}"
  chmod +x "${dest}.part"
  mv -f "${dest}.part" "${dest}"
}

# Runs: arangodb_operator_platform package install (see https://docs.arango.ai/contextual-data-platform/install-and-upgrade/online-setup/)
install_contextual_data_platform_package() {
  ensure_prereqs
  [[ "${ARANGO_OPERATOR_FLAVOR}" == "enterprise" ]] || {
    echo "Contextual Data Platform package install requires ARANGO_OPERATOR_FLAVOR=enterprise." >&2
    exit 1
  }
  local yaml_path cli ns id sec
  yaml_path="$(resolve_arango_platform_yaml_path)" || {
    echo "Missing platform package YAML. Place Arango's platform.yaml at ${SCRIPT_DIR}/platform.yaml or set ARANGO_PLATFORM_YAML=/path/to/platform.yaml" >&2
    exit 1
  }
  if ! kns get "arangodeployment/${ARANGO_DEPLOYMENT_NAME}" >/dev/null 2>&1; then
    echo "ArangoDeployment ${ARANGO_DEPLOYMENT_NAME} not found; run deploy or all-up first." >&2
    exit 1
  fi
  if ! load_enterprise_license_credentials_for_preflight; then
    echo "License credentials required (Kubernetes secret arango-license-key or ARANGO_LICENSE_CLIENT_ID / _SECRET)." >&2
    exit 1
  fi
  id="${__ARANGO_LIC_ID}"
  sec="${__ARANGO_LIC_SECRET}"
  unset __ARANGO_LIC_ID __ARANGO_LIC_SECRET

  ensure_arangodb_operator_platform_cli
  cli="${ARANGO_PLATFORM_CLI:-${STATE_DIR}/arangodb_operator_platform}"
  ns="${ARANGO_PLATFORM_NAMESPACE:-${ARANGO_K8S_NAMESPACE}}"
  log_step "Contextual Data Platform: ${cli} package install (namespace=${ns}, platform.name=${ARANGO_DEPLOYMENT_NAME})"
  log_step "Package file: ${yaml_path}"
  "${cli}" --namespace "${ns}" package install \
    --license.client.id "${id}" \
    --license.client.secret "${sec}" \
    --platform.name "${ARANGO_DEPLOYMENT_NAME}" \
    "${yaml_path}"
  log_step "arangodb_operator_platform package install exited successfully (inspect cluster: kns get pods,svc -n ${ns})"
}

# Local MinIO + ArangoPlatformStorage (Arango online setup step 8). Optional; for MLflow / GraphML style object storage.
minio_render_file() {
  sed -e "s/@MINIO_NS@/${MINIO_NAMESPACE}/g" \
    -e "s/@MINIO_BUCKET@/${ARANGO_MINIO_BUCKET}/g" \
    -e "s|@MINIO_ENDPOINT@|http://minio.${MINIO_NAMESPACE}.svc.cluster.local:9000|g" \
    "$1"
}

render_arango_platform_storage_yaml() {
  cat <<EOF
apiVersion: platform.arangodb.com/v1beta1
kind: ArangoPlatformStorage
metadata:
  name: ${ARANGO_DEPLOYMENT_NAME}
spec:
  backend:
    s3:
      bucketName: ${ARANGO_MINIO_BUCKET}
      credentialsSecret:
        name: minio-credentials
      endpoint: http://minio.${MINIO_NAMESPACE}.svc.cluster.local:9000
EOF
}

install_minio_object_storage() {
  ensure_prereqs
  [[ "${ARANGO_OPERATOR_FLAVOR}" == "enterprise" ]] || {
    echo "MinIO / ArangoPlatformStorage requires ARANGO_OPERATOR_FLAVOR=enterprise." >&2
    exit 1
  }
  if ! kubectl get crd arangoplatformstorages.platform.arangodb.com >/dev/null 2>&1; then
    echo "CRD arangoplatformstorages.platform.arangodb.com not found; run install-operator (CRDs) first." >&2
    exit 1
  fi
  [[ -f "${MINIO_STACK_FILE}" && -f "${MINIO_BUCKET_JOB_FILE}" ]] || {
    echo "Missing MinIO bundle files (expected ${MINIO_STACK_FILE} and ${MINIO_BUCKET_JOB_FILE})." >&2
    exit 1
  }
  if ! kns get "arangodeployment/${ARANGO_DEPLOYMENT_NAME}" >/dev/null 2>&1; then
    echo "ArangoDeployment ${ARANGO_DEPLOYMENT_NAME} not found; deploy the database first." >&2
    exit 1
  fi

  local user pass
  if [[ -z "${MINIO_ROOT_USER:-}" && -z "${MINIO_ROOT_PASSWORD:-}" ]]; then
    log_step "Using default MinIO credentials (minioadmin/miniopassword) — set MINIO_ROOT_USER / MINIO_ROOT_PASSWORD for anything beyond local dev"
  fi
  user="${MINIO_ROOT_USER:-minioadmin}"
  pass="${MINIO_ROOT_PASSWORD:-miniopassword}"

  log_step "Ensuring Kubernetes namespace ${MINIO_NAMESPACE} for MinIO"
  kubectl get namespace "${MINIO_NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${MINIO_NAMESPACE}"

  log_step "Applying MinIO root secret (${MINIO_NAMESPACE}/minio-root)"
  kubectl create secret generic minio-root \
    --namespace="${MINIO_NAMESPACE}" \
    --from-literal=MINIO_ROOT_USER="${user}" \
    --from-literal=MINIO_ROOT_PASSWORD="${pass}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log_step "Applying minio-credentials in ${ARANGO_K8S_NAMESPACE} (accessKey/secretKey for ArangoPlatformStorage)"
  kns create secret generic minio-credentials \
    --from-literal=accessKey="${user}" \
    --from-literal=secretKey="${pass}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log_step "Applying MinIO stack (PVC, Deployment, Service) from ${MINIO_STACK_FILE##*/}"
  minio_render_file "${MINIO_STACK_FILE}" | kubectl apply -f -

  log_step "Waiting for MinIO Deployment to become Available"
  kubectl wait --namespace="${MINIO_NAMESPACE}" --for=condition=Available "deployment/minio" --timeout=300s

  log_step "Running bucket Job (${ARANGO_MINIO_BUCKET})"
  kubectl delete job minio-create-bucket --namespace="${MINIO_NAMESPACE}" --ignore-not-found=true --wait=true --timeout=120s || true
  minio_render_file "${MINIO_BUCKET_JOB_FILE}" | kubectl apply -f -
  kubectl wait --namespace="${MINIO_NAMESPACE}" --for=condition=complete "job/minio-create-bucket" --timeout=300s

  log_step "Applying ArangoPlatformStorage ${ARANGO_DEPLOYMENT_NAME} (metadata.name matches ArangoDeployment)"
  render_arango_platform_storage_yaml | kns apply -f -

  log_step "MinIO object storage ready (namespace=${MINIO_NAMESPACE}, bucket=${ARANGO_MINIO_BUCKET}, endpoint in-cluster: http://minio.${MINIO_NAMESPACE}.svc.cluster.local:9000)"
}

# Community storage YAML applies arangolocalstorages.storage.arangodb.com with managed-by=Tiller; enterprise Helm refuses to adopt it.
prepare_enterprise_helm_storage_crd() {
  local crd="arangolocalstorages.storage.arangodb.com"
  kubectl get crd "${crd}" >/dev/null 2>&1 || return 0
  local managed release
  managed="$(kubectl get crd "${crd}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
  release="$(kubectl get crd "${crd}" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)"
  if [[ "${managed}" == "Helm" && "${release}" == "${ARANGO_HELM_RELEASE}" ]]; then
    log_step "CRD ${crd} already owned by Helm release ${ARANGO_HELM_RELEASE}"
    return 0
  fi
  log_step "Deleting CRD ${crd} (labels/annotations are not owned by Helm release '${ARANGO_HELM_RELEASE}'; was managed-by '${managed:-unknown}')"
  log_step "Reason: enterprise Helm chart cannot adopt CRDs applied from community arango-storage.yaml (Tiller legacy labels)."
  log_step "The ArangoLocalStorage resource will be reapplied from ${LOCAL_STORAGE_FILE##*/} during deploy."
  kubectl delete crd "${crd}" --wait=true --timeout=180s
}

# Replace community YAML operators + community ArangoDeployment with enterprise Helm operator + enterprise AI manifest.
# Does not install the Contextual Data Platform *suite* (unified UI, Agentic AI services): that requires Arango's
# platform.yaml and the arangodb_operator_platform CLI — see README "Enterprise" and Arango online setup docs.
switch_to_enterprise_platform() {
  ensure_prereqs
  require_cmd helm
  local community_deploy="${BUNDLE_DIR}/single-server.yaml"
  local enterprise_deploy="${BUNDLE_DIR}/single-server-enterprise-ai.yaml"

  [[ -f "${enterprise_deploy}" ]] || {
    echo "Enterprise deployment manifest not found: ${enterprise_deploy}" >&2
    exit 1
  }
  [[ -f "${community_deploy}" ]] || {
    echo "Community deployment manifest not found: ${community_deploy}" >&2
    exit 1
  }

  if [[ -z "${ARANGO_LICENSE_CLIENT_ID:-}" || -z "${ARANGO_LICENSE_CLIENT_SECRET:-}" ]]; then
    echo "Set ARANGO_LICENSE_CLIENT_ID and ARANGO_LICENSE_CLIENT_SECRET (from your Arango license credentials), then re-run." >&2
    exit 1
  fi

  log_step "Enterprise migration: this replaces community operators with the enterprise Helm chart and applies ${enterprise_deploy##*/}"
  log_step "After ArangoDB is up, install the Platform package with arangodb_operator_platform and platform.yaml from Arango (platform name must match ArangoDeployment: ${ARANGO_DEPLOYMENT_NAME})"

  stop_ui_background || true
  stop_api_background || true

  log_step "Deleting community ArangoDeployment if present (${community_deploy##*/})"
  kns delete -f "${community_deploy}" --ignore-not-found=true --wait=true --timeout=420s || true

  if truthy "${WIPE_ENTERPRISE_PVC:-}"; then
    log_step "Deleting PVCs labeled arango_deployment=${ARANGO_DEPLOYMENT_NAME} (--wipe-data)"
    kns delete pvc -l "arango_deployment=${ARANGO_DEPLOYMENT_NAME}" --ignore-not-found=true --wait=true --timeout=180s || true
  else
    log_step "Keeping existing PVCs (use to-enterprise --wipe-data if the new pod fails to start or you want a clean database)"
  fi

  log_step "Removing community operator Deployments (required before enterprise Helm install)"
  kubectl delete deployment arango-deployment-operator arango-storage-operator -n default --ignore-not-found=true --wait=true --timeout=180s || true
  kubectl delete deployment arango-deployment-operator arango-storage-operator -n "${ARANGO_K8S_NAMESPACE}" --ignore-not-found=true --wait=true --timeout=180s || true

  create_license_secret
  log_step "Applying ArangoDB CRDs (${CRD_FILE##*/})"
  kubectl apply -f "${CRD_FILE}"
  install_operator_enterprise

  export ARANGO_OPERATOR_FLAVOR=enterprise
  export DEPLOYMENT_FILE="${enterprise_deploy}"
  wait_for_cluster_ready
  deploy_arango

  start_ui_background
  start_api_background

  log_step "For future deploy/undeploy, use: export ARANGO_OPERATOR_FLAVOR=enterprise ARANGO_DEPLOYMENT_FILE=${enterprise_deploy}"
  show_status
}

# Writes .state/arango-root-password.txt from the live secret so the UI password is always on disk after deploy/setup.
sync_arango_root_password_file_from_secret() {
  ensure_prereqs
  local pw
  pw="$(kns get secret "${ARANGO_ROOT_PASSWORD_SECRET_NAME}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d | tr -d '\n\r')" || true
  if [[ -z "${pw}" ]]; then
    if kns get secret "${ARANGO_ROOT_PASSWORD_SECRET_NAME}" >/dev/null 2>&1; then
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

  if ! kns get secret "${ARANGO_JWT_SECRET_NAME}" >/dev/null 2>&1; then
    local jwt_token
    jwt_token="$(generate_secret)"
    kns create secret generic "${ARANGO_JWT_SECRET_NAME}" \
      --from-literal=token="${jwt_token}"
    log_step "Created JWT secret: ${ARANGO_JWT_SECRET_NAME}"
  else
    log_step "JWT secret already exists: ${ARANGO_JWT_SECRET_NAME}"
  fi

  if ! kns get secret "${ARANGO_ROOT_PASSWORD_SECRET_NAME}" >/dev/null 2>&1; then
    local root_password
    root_password="${ARANGO_ROOT_PASSWORD:-$(generate_secret)}"

    kns create secret generic "${ARANGO_ROOT_PASSWORD_SECRET_NAME}" \
      --from-literal=username=root \
      --from-literal=password="${root_password}"

    log_step "Created root password secret: ${ARANGO_ROOT_PASSWORD_SECRET_NAME}"
  else
    log_step "Root password secret already exists: ${ARANGO_ROOT_PASSWORD_SECRET_NAME}"
  fi

  sync_arango_root_password_file_from_secret
}

# Enterprise ArangoDeployment references spec.license.secretName; the secret must exist before apply.
# "Automatic" in Arango docs means the operator activates/renews the license using this secret — not that Kubernetes creates the secret without credentials.
ensure_enterprise_license_secret() {
  [[ "${ARANGO_OPERATOR_FLAVOR}" == "enterprise" ]] || return 0
  if kns get secret arango-license-key >/dev/null 2>&1; then
    log_step "Enterprise license secret arango-license-key already present"
    return 0
  fi
  if [[ -n "${ARANGO_LICENSE_CLIENT_ID:-}" && -n "${ARANGO_LICENSE_CLIENT_SECRET:-}" ]]; then
    create_license_secret
    return 0
  fi
  cat <<'EOF' >&2
Enterprise mode requires Kubernetes secret arango-license-key (keys license-client-id and license-client-secret).

Provide credentials once, then re-run:
  export ARANGO_LICENSE_CLIENT_ID='…'
  export ARANGO_LICENSE_CLIENT_SECRET='…'

Or create the secret manually (default namespace is arango; override with -n):
  kubectl create secret generic arango-license-key -n arango \
    --from-literal=license-client-id="<license-client-id>" \
    --from-literal=license-client-secret="<license-client-secret>"

The operator then activates and renews the license using this secret (see Step 3 in Arango online setup).
EOF
  exit 1
}

deploy_arango() {
  ensure_prereqs
  ensure_bundle_files
  ensure_secrets
  ensure_enterprise_license_secret
  preflight_enterprise_license_api
  ensure_host_bind_mount_permissions
  [[ -f "${DEPLOYMENT_FILE}" ]] || {
    echo "Deployment file not found: ${DEPLOYMENT_FILE}" >&2
    exit 1
  }

  wait_for_operator_ready
  ensure_local_storage_applied

  log_step "Applying ArangoDB deployment manifest ${DEPLOYMENT_FILE}"
  kns apply -f "${DEPLOYMENT_FILE}"
  wait_for_arango_pod
  repair_arango_local_storage_volume_paths
  recycle_arango_db_pod_after_pv_repair
  wait_arango_pod_ready_with_progress
  wait_for_arango_deployment_ready

  if truthy "${ARANGO_LOAD_SAMPLE_DATA:-}"; then
    load_sample_data
  fi

  sync_openai_api_key_from_env
}

sync_openai_api_key_from_env() {
  [[ -n "${OPENAI_API_KEY:-}" ]] || return 0
  mkdir -p "${STATE_DIR}"
  umask 077
  printf '%s\n' "${OPENAI_API_KEY}" > "${OPENAI_API_KEY_FILE}"
  chmod 600 "${OPENAI_API_KEY_FILE}" 2>/dev/null || true
  log_step "OPENAI_API_KEY saved to ${OPENAI_API_KEY_FILE} (for apps on this host)"
}

undeploy_arango() {
  ensure_prereqs
  kns delete -f "${DEPLOYMENT_FILE}" --ignore-not-found=true
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
  echo "ARANGO_K8S_NAMESPACE=${ARANGO_K8S_NAMESPACE}"
  kubectl get nodes || true
  echo
  kns get pods -A || true
  echo
  kns get svc || true
  echo
  echo "== Secrets =="
  kns get secret "${ARANGO_JWT_SECRET_NAME}" "${ARANGO_ROOT_PASSWORD_SECRET_NAME}" || true
  echo
  echo "== Local API keys (host files; not sent to Minikube) =="
  if [[ -f "${OPENAI_API_KEY_FILE}" ]]; then
    echo "OPENAI_API_KEY file: ${OPENAI_API_KEY_FILE} (refreshed when OPENAI_API_KEY is set during deploy/all-up)"
  else
    echo "OPENAI_API_KEY file: none yet — export OPENAI_API_KEY before ./manage-arango.sh deploy or all-up to create ${OPENAI_API_KEY_FILE}"
  fi
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
  kns port-forward "svc/${ARANGO_PORT_FORWARD_SVC}" "${ARANGO_UI_LOCAL_PORT}:8529"
}

open_api() {
  ensure_prereqs
  if [[ "${ARANGO_API_LOCAL_PORT}" == "${ARANGO_UI_LOCAL_PORT}" ]]; then
    echo "ARANGO_API_LOCAL_PORT must differ from ARANGO_UI_LOCAL_PORT" >&2
    exit 1
  fi
  echo "Forwarding ArangoDB HTTP (UI + /_api) to https://127.0.0.1:${ARANGO_API_LOCAL_PORT}"
  kns port-forward "svc/${ARANGO_PORT_FORWARD_SVC}" "${ARANGO_API_LOCAL_PORT}:8529"
}

open_shell() {
  ensure_prereqs
  local pod
  pod="$(kns get pod -l "${ARANGO_DB_POD_LABEL_SELECTOR}" -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "${pod}" ]] || {
    echo "No ArangoDB pod found" >&2
    exit 1
  }
  kns exec -it "${pod}" -- /bin/sh
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

  root_pw="$(kns get secret "${ARANGO_ROOT_PASSWORD_SECRET_NAME}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d | tr -d '\n\r')"
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

  log_step "Importing sample JSONL via HTTPS REST (port-forward ${pf_port}→svc/${ARANGO_PORT_FORWARD_SVC}:8529 in ns ${ARANGO_K8S_NAMESPACE}; curl -k)"

  # In-pod arangoimport to 127.0.0.1 often returns 401 with the operator TLS/auth stack; match browser path from host.
  (
    set -euo pipefail
    kns port-forward "svc/${ARANGO_PORT_FORWARD_SVC}" "${pf_port}:8529" >/dev/null 2>&1 &
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
  HTTPS + curl -k from the host via a short port-forward to svc/${ARANGO_PORT_FORWARD_SVC} in namespace ${ARANGO_K8S_NAMESPACE} (see load_sample_data).

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
  if truthy "${ARANGO_WITH_PLATFORM_INSTALL:-}" || truthy "${ARANGO_PLATFORM_PACKAGE_INSTALL:-}"; then
    resolve_arango_platform_yaml_path >/dev/null || {
      echo "all-up --with-platform (or ARANGO_PLATFORM_PACKAGE_INSTALL=1) requires platform.yaml — set ARANGO_PLATFORM_YAML or add ${SCRIPT_DIR}/platform.yaml (from Arango)." >&2
      exit 1
    }
  fi
  start_minikube
  start_mount
  install_operator
  deploy_arango
  start_ui_background
  start_api_background
  if truthy "${ARANGO_WITH_PLATFORM_INSTALL:-}" || truthy "${ARANGO_PLATFORM_PACKAGE_INSTALL:-}"; then
    install_contextual_data_platform_package
  fi
  if truthy "${ARANGO_WITH_MINIO_INSTALL:-}" || truthy "${ARANGO_MINIO_INSTALL:-}"; then
    install_minio_object_storage
  fi
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
  create-license-secret) create_license_secret ;;
  install-operator) install_operator ;;
  install-operator-enterprise) install_operator_enterprise ;;
  to-enterprise)
    WIPE_ENTERPRISE_PVC=
    case "${2:-}" in
      --wipe-data) WIPE_ENTERPRISE_PVC=1 ;;
      "") ;;
      *)
        echo "Unknown option for to-enterprise: $2 (use --wipe-data)" >&2
        exit 1
        ;;
    esac
    switch_to_enterprise_platform
    ;;
  deploy)
    shift
    ARANGO_LOAD_SAMPLE_DATA=
    ARANGO_WITH_PLATFORM_INSTALL=
    ARANGO_WITH_MINIO_INSTALL=
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --load-sample-data) ARANGO_LOAD_SAMPLE_DATA=1 ;;
        --with-platform) ARANGO_WITH_PLATFORM_INSTALL=1 ;;
        --with-minio) ARANGO_WITH_MINIO_INSTALL=1 ;;
        *)
          echo "Unknown option for deploy: $1 (use --load-sample-data, --with-platform, and/or --with-minio)" >&2
          exit 1
          ;;
      esac
      shift
    done
    if truthy "${ARANGO_WITH_PLATFORM_INSTALL:-}" || truthy "${ARANGO_PLATFORM_PACKAGE_INSTALL:-}"; then
      resolve_arango_platform_yaml_path >/dev/null || {
        echo "deploy --with-platform requires platform.yaml — set ARANGO_PLATFORM_YAML or add ${SCRIPT_DIR}/platform.yaml" >&2
        exit 1
      }
    fi
    deploy_arango
    if truthy "${ARANGO_WITH_PLATFORM_INSTALL:-}" || truthy "${ARANGO_PLATFORM_PACKAGE_INSTALL:-}"; then
      install_contextual_data_platform_package
    fi
    if truthy "${ARANGO_WITH_MINIO_INSTALL:-}" || truthy "${ARANGO_MINIO_INSTALL:-}"; then
      install_minio_object_storage
    fi
    ;;
  undeploy) undeploy_arango ;;
  status) show_status ;;
  ui) open_ui ;;
  api) open_api ;;
  shell) open_shell ;;
  import-example) show_import_example ;;
  load-sample-data) load_sample_data ;;
  all-up)
    shift
    ARANGO_LOAD_SAMPLE_DATA=
    ARANGO_WITH_PLATFORM_INSTALL=
    ARANGO_WITH_MINIO_INSTALL=
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --load-sample-data) ARANGO_LOAD_SAMPLE_DATA=1 ;;
        --with-platform) ARANGO_WITH_PLATFORM_INSTALL=1 ;;
        --with-minio) ARANGO_WITH_MINIO_INSTALL=1 ;;
        *)
          echo "Unknown option for all-up: $1 (use --load-sample-data, --with-platform, and/or --with-minio)" >&2
          exit 1
          ;;
      esac
      shift
    done
    all_up
    ;;
  all-down) all_down ;;
  check-license|license-check) check_license_command ;;
  platform-install) install_contextual_data_platform_package ;;
  minio-install) install_minio_object_storage ;;
  ""|-h|--help|help) usage ;;
  *)
    echo "Unknown command: $1" >&2
    usage
    exit 1
    ;;
esac
