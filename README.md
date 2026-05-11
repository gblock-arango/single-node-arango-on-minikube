# Arango on Minikube (single node)

Local Arango suite of services using the [kube-arangodb](https://github.com/arangodb/kube-arangodb) operator. **`manage-arango.sh`** drives Minikube, mounts, deploy, and optional sample import.

## Quick start

Install the basic dependencies:

```bash
./install_kubectl+helm+minikube  
```

Stand up the cluster — same behavior as before (**`ARANGO_OPERATOR_FLAVOR` defaults to community**). If you export **`OPENAI_API_KEY`** before running deploy/`all-up`, the script saves it to **`.state/openai-api-key`** (mode `600`, gitignored), similar to the root password file for local apps.

```bash
./manage-arango.sh all-up
./manage-arango.sh status
```

First start after a Minikube restart can take **several minutes**: the **`single-server-sngl-…`** pod stays in **`Init:*`** while TLS prep runs and the image may be pulled. (You may also see a **`single-server-id-…`** pod; that is image discovery, not the database.) `all-up` waits only on **`role=single`** and prints pod status periodically.

Bring down the Arango Cluster

```bash
./manage-arango.sh all-down
```

Access the cluster here:

- UI: `https://127.0.0.1:8529`
- API: `https://127.0.0.1:18529` 

with username = root and password = "replace-with-a-strong-password" (or value set by user following Secrets section below).

## Sample graph import

Bundled files: `arango-import/nodes.jsonl` and `edges.jsonl` → collections `nodes`, `edges`. 

```bash
./manage-arango.sh all-up --load-sample-data
# or, if Arango is already running:
./manage-arango.sh load-sample-data
```

For manual `arangoimport` inside the pod, use `./manage-arango.sh shell` and paths under `/imports/`. If you hit **401** against localhost in the pod, use `load-sample-data` instead (host `curl -k` via a short port-forward).

## Host folders

`./arango-import` mounts on the host so that files are visible in the pod as `/imports` (via `minikube mount` → `/mnt/arango-import`)

Note: no database data is mounted on the host. Database PVC data lives on the **Minikube VM** under **`ArangoLocalStorage` `spec.localPath`** (repo default **`/var/lib/arango-local-data`**). RocksDB needs working `fsync`; do not point Arango data at a `minikube mount` / 9p path.

`./manage-arango.sh status` shows **Cluster localPath** from the live CR; that path is what Arango actually uses. If you still see **`/mnt/arango-data`** after editing `kubernetes-1.4.2/arango-local-storage.yaml`, the CR was probably created with the old value: remove the deployment, PVCs/PVs, and the `ArangoLocalStorage`, then re-apply the manifest (or run `minikube delete` for a clean slate).

`all-up` starts only the import-folder mount in the background. To reset data on the VM, use the directory from `status` or `kubectl get arangolocalstorage arango-minikube-local-data -o jsonpath='{.spec.localPath[0]}{"\n"}'` (for example `minikube ssh -- sudo rm -rf /var/lib/arango-local-data/*` when that is your localPath). `minikube delete` removes the VM and all data.

## Secrets

On deploy / `create-secrets`, the script ensures **`single-server-jwt`** and **`arango-root-pwd`** exist. It always copies the root password from **`arango-root-pwd`** into **`.state/arango-root-password.txt`** (mode `600`) so the Web UI can use **`root`** with that password. If **`OPENAI_API_KEY`** is set when you run **`deploy`** or **`all-up`**, it is copied to **`.state/openai-api-key`** for tools on your machine (nothing is pushed into ArangoDB automatically). To set your own DB password first, create the secret with `kubectl` (see script usage), then run **`./manage-arango.sh create-secrets`** or **`./manage-arango.sh deploy`** to refresh the password file.

## kubectl (optional)

```bash
kubectl get arangodeployment,pods,svc,pvc -l arango_deployment=single-server
kubectl get arangolocalstorages
```

## If `all-up` waits forever on Arango

Run `kubectl describe arangodeployment single-server` and check **PVC** / **pod events**. Common causes: import **`minikube mount`** not running, a **Pending** PVC (storage class / `ArangoLocalStorage`), or database files on a **9p** path (RocksDB needs native disk under **`/var/lib/arango-local-data`** in the VM by default).

## Enterprise / Contextual Data Platform (advanced)

Optional: **`kubernetes-1.4.2/single-server-enterprise-ai.yaml`**, **`install-operator-enterprise.sh`**, **`ARANGO_OPERATOR_FLAVOR=enterprise`**, plus license credentials and Arango’s [installation guide](https://docs.arango.ai/contextual-data-platform/install-and-upgrade/online-setup/). Not required for default **`./manage-arango.sh all-up`**.

## More

```bash
./manage-arango.sh help
```

Lists every command (`mount`, `deploy --load-sample-data`, `ui-bg`, etc.) and environment variables.
