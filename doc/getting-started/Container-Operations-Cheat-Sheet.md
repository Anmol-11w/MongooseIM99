# Wingtrill-Mongooseim Container Operations Cheat Sheet

This page is a practical runbook for daily operations in this repository.

It covers:

- how to enter the server container
- how to check logs
- how to run MongooseIM commands
- how to do temporary in-container changes
- how to do permanent code changes and redeploy
- basic troubleshooting commands

## 1. Quick context for this repository

- Kubernetes namespace used by project scripts: `mim`
- Main MongooseIM container name: `mongooseim`
- Helm release name used in CI: `mim`
- Kubernetes deployment name used in CI: `mim-mongooseim`
- Docker Compose in this repo currently starts PostgreSQL only

## 1.1 SSH to server

Use your secure credential store for passwords/keys. Avoid saving credentials in git.

ssh root@94.136.184.234

## 2. Useful files:

- `Dockerfile`
- `docker-compose.yml`
- `helm/mongooseim/values.yaml`
- `helm/mongooseim/templates/deployment.yaml`
- `k8s/mongooseim-deployment.yaml`
- `load-test.sh`
- `push_user_count.sh`


## 3. Kubernetes basics (current workflow)

### 3.1 Find pods

kubectl get pods -n mim
kubectl get pods -n mim -w (live)

### 3.2 Check logs

```bash
kubectl logs -n mim "$POD" -c mongooseim --tail=200
kubectl logs -n mim "$POD" -c mongooseim -f
kubectl logs -n mim "$POD" -c mongooseim --previous
kubectl describe pod -n mim "$POD"
```

### 3.3 Enter the server container

```bash
kubectl exec -it -n mim "$POD" -c mongooseim -- /bin/bash
```

## basic commands 

```bash
./bin/mongooseimctl start
./bin/mongooseimctl stop
./bin/mongooseimctl restart
./bin/mongooseimctl ping
./bin/mongooseimctl status
./bin/mongooseimctl remote_console
./bin/mongooseimctl console
./bin/mongooseimctl foreground
```

### 3.4 Run useful `mongooseimctl` commands from Kubernetes

```bash
kubectl exec -i -n mim "$POD" -c mongooseim -- mongooseimctl status
kubectl exec -i -n mim "$POD" -c mongooseim -- mongooseimctl account listUsers --domain xmpp-mongo.wingtrill.com
kubectl exec -i -n mim "$POD" -c mongooseim -- mongooseimctl account countUsers --domain xmpp-mongo.wingtrill.com
```

Register a user:

```bash
kubectl exec -i -n mim "$POD" -c mongooseim -- \
  mongooseimctl account registerUser \
  --username "alice" \
  --domain "xmpp-mongo.wingtrill.com" \
  --password "Test1234"
```

## 4. Change in running server container (temporary hotfix)

Use this only for emergency debugging.

1. Enter pod and inspect runtime config path:

```bash
kubectl exec -it -n mim "$POD" -c mongooseim -- /bin/bash
```

2. Edit file with `vi` or `sed`.
3. Validate status:

```bash
mongooseimctl status
```

4. If needed, restart pod/deployment:

```bash
kubectl rollout restart deployment/mim-mongooseim -n mim
kubectl rollout status deployment/mim-mongooseim -n mim --timeout=300s
```


## 5. Change in server code (permanent way)

### 5.1 Edit code/config in repository

Common places:

- `src/custom/ai_bot/mod_ai_bot.erl`
- `src/custom/ai_bot/mod_ai_bot_voice.erl`
- `helm/mongooseim/templates/deployment.yaml`
- `helm/mongooseim/values.yaml`

### 5.2 Build and push image

```bash
TAG=sha-$(git rev-parse --short HEAD)
docker build -t ghcr.io/anmol-11w/mongooseim99:$TAG .
docker push ghcr.io/anmol-11w/mongooseim99:$TAG
```

### 5.3 Upgrade Helm release

```bash
helm upgrade --install mim ./helm/mongooseim \
  --namespace mim \
  --reset-values \
  --set image.repository="ghcr.io/anmol-11w/mongooseim99" \
  --set image.tag="$TAG" \
  --set image.pullPolicy="Always"
```

### 5.4 Restart and verify rollout

```bash
kubectl rollout restart deployment/mim-mongooseim -n mim
kubectl rollout status deployment/mim-mongooseim -n mim --timeout=300s
kubectl get pods -n mim
```


## 6. Common troubleshooting commands

### 6.1 Pod crash loop

```bash
kubectl get pods -n mim
kubectl describe pod -n mim "$POD"
kubectl logs -n mim "$POD" -c mongooseim --previous
```

### 6.2 Restart only app deployment

```bash
kubectl rollout restart deployment/mim-mongooseim -n mim
kubectl rollout status deployment/mim-mongooseim -n mim --timeout=300s
```

### 6.3 Check PostgreSQL pod quickly

```bash
PG_POD=$(kubectl get pod -n mim -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n mim "$PG_POD" --tail=100
```

## 7. One-page command list

# Admin commands
```bash
kubectl exec -i -n mim "$POD" -c mongooseim -- mongooseimctl status
kubectl exec -i -n mim "$POD" -c mongooseim -- mongooseimctl get_loglevel
kubectl exec -i -n mim "$POD" -c mongooseim -- mongooseimctl account countUsers --domain xmpp-mongo.wingtrill.com
```

# Helm upgrade to new image
```bash
helm upgrade --install mim ./helm/mongooseim --namespace mim --set image.repository=ghcr.io/anmol-11w/mongooseim99 --set image.tag=sha-<shortsha> --set image.pullPolicy=Always
```