# Arango on Minikube (single node)

Local Arango suite of services using the [kube-arangodb](https://github.com/arangodb/kube-arangodb) operator. **`manage-arango.sh`** drives Minikube, mounts, deploy, and optional sample import.

## Quick start

Install the basic dependencies:

```bash
./install_kubectl+helm+minikube  
```

Stand up the cluster — **defaults: enterprise** operator (Helm) and **`single-server-enterprise-ai.yaml`**. You need a **license secret** before deploy (see below). For **community** edition instead: `ARANGO_OPERATOR_FLAVOR=community ./manage-arango.sh all-up`.

If you export **`OPENAI_API_KEY`** before running deploy/`all-up`, the script saves it to **`.state/openai-api-key`** (mode `600`, gitignored), similar to the root password file for local apps.

Note: ArangoDB Cloud **deployment API keys** (dashboard user/API keys) are not always the same as **Kubernetes license** **client id** + **client secret** used by `license.arango.ai` and `arango-license-key`. Use the **Contextual Data Platform / enterprise onboarding** license pair from Arango when in doubt ([online setup](https://docs.arango.ai/contextual-data-platform/install-and-upgrade/online-setup/#step-3-create-a-secret-for-the-license)).

```bash
export ARANGO_LICENSE_CLIENT_ID='…'   
export ARANGO_LICENSE_CLIENT_SECRET='…'
./manage-arango.sh check-license   # optional: only verify credentials against license.arango.ai (exit 0/1)
./manage-arango.sh all-up          # Minikube + enterprise DB (+ optional --with-platform if platform.yaml is present)
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

On deploy / `create-secrets`, the script ensures **`single-server-jwt`** and **`arango-root-pwd`** exist. It always copies the root password from **`arango-root-pwd`** into **`.state/arango-root-password.txt`** (mode `600`) so the Web UI can use **`root`** with that password.

**Enterprise** additionally requires **`arango-license-key`** (`license-client-id`, `license-client-secret`). If it is missing, set **`ARANGO_LICENSE_CLIENT_ID`** and **`ARANGO_LICENSE_CLIENT_SECRET`** before **`deploy`** / **`all-up`**, or run **`./manage-arango.sh create-license-secret`**, or create the secret with **`kubectl`** as in [Arango Step 3](https://docs.arango.ai/contextual-data-platform/install-and-upgrade/online-setup/#step-3-create-a-secret-for-the-license). License **`check-license`** / preflight read the **secret first** when it exists (so stale **`ARANGO_LICENSE_*`** in **`~/.bashrc`** does not override what you just applied); use **`ARANGO_LICENSE_PREFER_ENV=1`** to force env-only testing.

On **`all-up`** / **`deploy`** (enterprise), the script calls **`https://license.arango.ai/_api/v1/identity`** with your credentials (same check the operator uses). **401/403** means bad id/secret; connectivity errors mean firewall/DNS. To skip: **`ARANGO_LICENSE_SKIP_PREFLIGHT=1`**.

If enterprise **Helm** fails with **`arangolocalstorages... cannot be imported`** (legacy **`managed-by: Tiller`** from an old community install), **`install-operator-enterprise`** / **`all-up`** now deletes that CRD so Helm can recreate it; **`deploy`** then reapplies **`arango-local-storage.yaml`**.

If **`OPENAI_API_KEY`** is set when you run **`deploy`** or **`all-up`**, it is copied to **`.state/openai-api-key`** for tools on your machine (nothing is pushed into ArangoDB automatically). To set your own DB password first, create the secret with `kubectl` (see script usage), then run **`./manage-arango.sh create-secrets`** or **`./manage-arango.sh deploy`** to refresh the password file.

## kubectl (optional)

Resources live in namespace **`arango`** by default (override with **`ARANGO_K8S_NAMESPACE`** before running **`manage-arango.sh`**).

```bash
kubectl get arangodeployment,pods,svc,pvc -n arango -l arango_deployment=single-server
kubectl get arangolocalstorages
```

## If `all-up` waits forever on Arango

Run `kubectl describe arangodeployment single-server -n arango` (or your `ARANGO_K8S_NAMESPACE`) and check **PVC** / **pod events**. Common causes: import **`minikube mount`** not running, a **Pending** PVC (storage class / `ArangoLocalStorage`), or database files on a **9p** path (RocksDB needs native disk under **`/var/lib/arango-local-data`** in the VM by default).

## Enterprise / Contextual Data Platform (advanced)

You need **license credentials** (client id + secret) and, for the full **Platform Suite** (unified web UI, Agentic AI services, etc.), the **`platform.yaml`** package file from Arango — see the [online setup guide](https://docs.arango.ai/contextual-data-platform/install-and-upgrade/online-setup/).

**Namespace:** this repo defaults to **`arango`** (same as many Arango docs). Set **`ARANGO_K8S_NAMESPACE`** if you need a different namespace; use **`kubectl -n …`** / **`--namespace …`** for manual commands to match.

### 1. Fresh install (default): enterprise `all-up`

After **`./install_kubectl+helm+minikube`**, set license env vars (or pre-create **`arango-license-key`**) and run **`./manage-arango.sh all-up`**. No separate **`to-enterprise`** step.

### 2. Migrate an existing community stack to enterprise

With Minikube already up and still on **community** operators + **`single-server.yaml`**:

```bash
export ARANGO_LICENSE_CLIENT_ID='<from Arango>'
export ARANGO_LICENSE_CLIENT_SECRET='<from Arango>'
./manage-arango.sh to-enterprise              # keeps existing PVC / data if possible
# or, for a clean database volume:
./manage-arango.sh to-enterprise --wipe-data
```

This removes the community YAML operators, installs the **enterprise** Helm chart (webhooks, gateway, storage), applies **`kubernetes-1.4.2/single-server-enterprise-ai.yaml`**, and restarts UI/API port-forwards. It does **not** install the Platform Suite by itself.

Afterward, for **`deploy` / `undeploy`**, you normally need no extra exports (enterprise is the default). To use **community** instead:

```bash
export ARANGO_OPERATOR_FLAVOR=community
# optional explicit manifest:
export ARANGO_DEPLOYMENT_FILE="$PWD/kubernetes-1.4.2/single-server.yaml"
```

### 3. Install the Platform Suite (control plane / unified UI)

You need **`platform.yaml`** from Arango (not generated in this repo).

**One command (after placing `platform.yaml` next to `manage-arango.sh`, or setting `ARANGO_PLATFORM_YAML`):**

```bash
./manage-arango.sh all-up --with-platform
# or on an already-running DB:  ./manage-arango.sh deploy --with-platform
# or only the platform step:     ./manage-arango.sh platform-install
```

The script downloads **`arangodb_operator_platform`** from [kube-arangodb releases](https://github.com/arangodb/kube-arangodb/releases) (matching **`ARANGO_OPERATOR_VERSION`**) into **`.state/arangodb_operator_platform`** unless **`ARANGO_PLATFORM_CLI`** points to your own binary. **`ARANGO_PLATFORM_NAMESPACE`** defaults to the same value as **`ARANGO_K8S_NAMESPACE`** (by default **`arango`**).

**Manual equivalent** (same as [online setup](https://docs.arango.ai/contextual-data-platform/install-and-upgrade/online-setup/)):

1. Download **`arangodb_operator_platform`** from [kube-arangodb releases](https://github.com/arangodb/kube-arangodb/releases) (same version line as **`ARANGO_OPERATOR_VERSION`**, default 1.4.2).
2. Run **`package install`** with your **`platform.yaml`** and **`--platform.name single-server`**, **`-n arango`** (or your **`ARANGO_K8S_NAMESPACE`**):

```bash
arangodb_operator_platform --namespace arango package install \
  --license.client.id "$ARANGO_LICENSE_CLIENT_ID" \
  --license.client.secret "$ARANGO_LICENSE_CLIENT_SECRET" \
  --platform.name single-server \
  ./platform.yaml
```

Optional: **object storage** (MinIO or remote S3) for ML-related platform features — [platform storage](https://arangodb.github.io/kube-arangodb/docs/platform/storage.html) and [step 8](https://docs.arango.ai/contextual-data-platform/install-and-upgrade/online-setup/) in the Arango guide. This repo can install a **local MinIO** plus **`ArangoPlatformStorage`** automatically:

```bash
./manage-arango.sh all-up --with-minio
# or after the DB is already up:
./manage-arango.sh minio-install
```

Use **`ARANGO_MINIO_INSTALL=1`** with **`all-up`** / **`deploy`** the same way as **`--with-minio`**. Override **`MINIO_ROOT_USER`** / **`MINIO_ROOT_PASSWORD`** (defaults are dev-only **`minioadmin`** / **`miniopassword`**), **`MINIO_NAMESPACE`** (default **`minio`**), or **`ARANGO_MINIO_BUCKET`** (default **`arango-platform-storage`**) as needed. Requires **enterprise** flavor and operator **CRDs** (including **`ArangoPlatformStorage`**); **`metadata.name`** on **`ArangoPlatformStorage`** matches **`ARANGO_DEPLOYMENT_NAME`** (default **`single-server`**).

Manual operator install (same chart flags as **`manage-arango.sh`**): **`install-operator-enterprise.sh`** is optional; **`./manage-arango.sh install-operator`** uses Helm when **`ARANGO_OPERATOR_FLAVOR=enterprise`** (the default). For **community**, set **`ARANGO_OPERATOR_FLAVOR=community`** before **`install-operator`** / **`all-up`**.

## More

```bash
./manage-arango.sh help
```

Lists every command (`mount`, `deploy --load-sample-data`, `deploy --with-minio`, `minio-install`, `ui-bg`, etc.) and environment variables.
