# Arango on Minikube (single node)

Local Arango suite of services using the [kube-arangodb](https://github.com/arangodb/kube-arangodb) operator. **`manage-arango.sh`** drives Minikube, mounts, deploy, and optional sample import.

## Quick start

Install the basic dependencies:

```bash
./install_kubectl+helm+minikube  
```

Stand up the Arango Cluster

```bash
./manage-arango.sh all-up
./manage-arango.sh status
```

First start after a Minikube restart can take **several minutes**: the **`single-server-sngl-…`** pod stays in **`Init:*`** while TLS prep runs and the image may be pulled. (You may also see a **`single-server-id-…`** pod; that is image discovery, not the database.) `all-up` waits only on **`role=single`** and prints pod status every 20s.

Bring down the Arango Cluster

```bash
./manage-arango.sh all-down
```

- UI: `https://127.0.0.1:8529` (same server also serves `/_api/...` on that port)
- Second local port for tooling: `https://127.0.0.1:18529` (optional; same process as UI)

## Sample graph import

Bundled files: `arango-import/nodes.jsonl` and `edges.jsonl` → collections `nodes`, `edges`. 

```bash
./manage-arango.sh all-up --load-sample-data
# or, if Arango is already running:
./manage-arango.sh load-sample-data
```

For manual `arangoimport` inside the pod, use `./manage-arango.sh shell` and paths under `/imports/`. If you hit **401** against localhost in the pod, use `load-sample-data` instead (host `curl -k` via a short port-forward).

## Host folders

| On your machine | Role |
|-----------------|------|
| `./arango-import` | Files visible in the pod as `/imports` (via `minikube mount` → `/mnt/arango-import`) |
| `./arango-data` | Database files (PVC backed by `ArangoLocalStorage` + second mount → `/mnt/arango-data`) |

`all-up` starts both mounts in the background. Stopping the mounts or Minikube does not delete `./arango-data` on disk; deleting PVCs or `minikube delete` is a different story (see `./manage-arango.sh help` and Kubernetes docs).

## Secrets

On first deploy the script can create **`single-server-jwt`** and **`arango-root-pwd`**. A generated root password may be saved under **`.state/arango-root-password.txt`**. To set your own values first, use **`./manage-arango.sh create-secrets`** or create the secrets with `kubectl` (see script usage).

## kubectl (optional)

```bash
kubectl get arangodeployment,pods,svc,pvc -l arango_deployment=single-server
kubectl get arangolocalstorages
```

## If `all-up` waits forever on Arango

Run `kubectl describe arangodeployment single-server` and check **PVC** / **pod events**. Common causes: import or data **`minikube mount`** not running, or a **Pending** PVC (storage class / `ArangoLocalStorage`).

## More

```bash
./manage-arango.sh help
```

Lists every command (`mount`, `data-mount`, `deploy --load-sample-data`, `ui-bg`, etc.) and environment variables.
