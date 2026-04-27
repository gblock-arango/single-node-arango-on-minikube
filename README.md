# ArangoDB test standup

Local single-node ArangoDB on Minikube, with a host folder mounted for imports.

## Files

- `install_kubectl+helm+minikube`: installs local prerequisites on Ubuntu 22
- `kubernetes-1.4.2/arango-crd.yaml`: Arango CRDs
- `kubernetes-1.4.2/arango-deployment.yaml`: Arango deployment operator install bundle
- `kubernetes-1.4.2/arango-storage.yaml`: Arango storage operator install bundle
- `kubernetes-1.4.2/single-server.yaml`: ArangoDB `ArangoDeployment`
- `manage-arango.sh`: starts and manages the local cluster

## Quick start

Install prerequisites first:

```bash
./install_kubectl+helm+minikube
```

Then bring everything up:

```bash
./manage-arango.sh all-up
```

`all-up` now waits for:

- the Minikube node to become ready
- core Kubernetes services to recover after restart
- Arango operator deployments to become available
- the Arango pod to appear before waiting on pod readiness
- the `ArangoDeployment` itself to report `Ready=True`

It also prints timestamped progress messages during these waits, so you can see which stage is currently blocking startup.

When setup completes, `all-up` also starts the UI port-forward in the background automatically.

On first deploy, the script creates these Kubernetes secrets if they do not already exist:

- `single-server-jwt`
- `arango-root-pwd`

If the root password is generated automatically, it is saved to:

- `.state/arango-root-password.txt`

Check status:

```bash
./manage-arango.sh status
```

Open the ArangoDB UI:

```bash
./manage-arango.sh ui
```

Or start/stop the UI port-forward in the background manually:

```bash
./manage-arango.sh ui-bg
./manage-arango.sh ui-stop
```

Then browse to:

- `https://127.0.0.1:8529`

## Import folder

The default local import folder is:

- `./arango-import`

It is mounted:

- into the Minikube node at `/mnt/arango-import`
- into the ArangoDB container at `/imports`

Put your local import files in `./arango-import`.

Example:

```bash
./manage-arango.sh shell
arangoimport --file /imports/nodes.jsonl --type jsonl --collection vertices
arangoimport --file /imports/edges.jsonl --type jsonl --collection edges
```

## About the Minikube mount

`minikube mount` is a foreground process. If you run it in a terminal and stop the terminal, the mount stops too.

This repo handles that by running the mount in the background and tracking its PID:

```bash
./manage-arango.sh mount
./manage-arango.sh umount
```

There are `minikube start --mount` / `--mount-string` flags, but they are not the most dependable option for this workflow, so this setup does not rely on them.

## Useful commands

```bash
./manage-arango.sh start
./manage-arango.sh mount
./manage-arango.sh create-secrets
./manage-arango.sh install-operator
./manage-arango.sh deploy
./manage-arango.sh ui-bg
./manage-arango.sh ui-stop
./manage-arango.sh status
./manage-arango.sh ui
./manage-arango.sh undeploy
./manage-arango.sh all-down
```

## Kubernetes inspection

After deployment:

```bash
kubectl get arangodeployment
kubectl describe arangodeployment single-server
kubectl get all
kubectl get pvc
kubectl get svc
kubectl get secret
```

Only Arango-created resources:

```bash
kubectl get all -l arango_deployment=single-server
kubectl get pvc -l arango_deployment=single-server
kubectl get svc -l arango_deployment=single-server
kubectl get arangodeployments
kubectl get arangolocalstorages
```

## Secrets
<!-- Note: You may see historical warning events like:
    Reconciliation Failed ... Secret for JWT token is missing single-server-jwt
That is normal. kubectl describe shows the event history, including earlier failures. Those do not mean the deployment is still broken. -->

The deployment explicitly references:

- JWT secret: `single-server-jwt`
- root password secret: `arango-root-pwd`

Create them ahead of time if you want to control the values yourself:

```bash
kubectl create secret generic single-server-jwt \
  --from-literal=token='replace-with-a-long-random-secret'

kubectl create secret generic arango-root-pwd \
  --from-literal=username=root \
  --from-literal=password='replace-with-a-strong-password'
```

Or let the script create them once if missing:

```bash
./manage-arango.sh create-secrets
```