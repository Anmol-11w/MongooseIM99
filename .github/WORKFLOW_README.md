# 🚀 Workflow & Kubernetes Operations Guide

This guide explains how GitHub Actions CI/CD workflows operate, how to access Kubernetes pods, view logs, and troubleshoot MongooseIM in production.

---

## 📑 Table of Contents
1. [GitHub Actions Workflows](#1-github-actions-workflows)
2. [Kubernetes Pod Operations](#2-kubernetes-pod-operations)
3. [Viewing Logs](#3-viewing-logs)
4. [Going Inside Pods (Interactive Shell)](#4-going-inside-pods-interactive-shell)
5. [Extracting Configs & Secret Keys](#5-extracting-configs--secret-keys)
6. [MongooseIM Admin CLI Commands](#6-mongooseim-admin-cli-commands)

---

## 1. 🤖 GitHub Actions Workflows

### A. CI/CD Deployment Pipeline (`.github/workflows/ci.yml`)
* **Trigger**: Push to `main` branch or Pull Requests.
* **Actions**:
  1. Runs Erlang test suites.
  2. Builds Docker image tagged with git SHA (`ghcr.io/Pargat-tech/Wingtrill-mongooseim:sha-<shortsha>`).
  3. Pushes image to GitHub Container Registry.
  4. SSHs into the deployment server, injects environment variables/secrets (`MIM_*`), upgrades Helm release (`mim`), and restarts pods.

### B. AI Code Review Gate (`.github/workflows/ai_code_review.yml`)
* **Trigger**: Pull requests or comment commands (`@ai`, `@review`, `@opencode`, `@claude`).
* **Actions**:
  1. Analyzes code diffs via LLM.
  2. Runs test suites and posts Code Coverage report on PR (80% pass threshold).

---

## 2. ☸️ Kubernetes Pod Operations

### Find All Pods and Namespaces
```bash
# List all pods across all namespaces
kubectl get pods -A

# List all pods in the 'mim' namespace
kubectl get pods -n mim
```

### Auto-Set Pod Variable in Terminal
```bash
POD=$(kubectl get pods -n mim -l app=mongooseim -o jsonpath='{.items[0].metadata.name}')
echo "Active Pod: $POD"
```

---

## 3. 📄 Viewing Logs

### A. Real-Time Stream (Follow Logs)
```bash
# Stream live logs for a pod in 'mim' namespace
kubectl logs -f <POD_NAME> -n mim

# Stream live logs for specific container (mongooseim)
kubectl logs -f <POD_NAME> -n mim -c mongooseim
```

### B. View Last N Lines of Logs
```bash
# View last 100 lines
kubectl logs --tail=100 -n mim <POD_NAME>

# View last 500 lines with timestamps
kubectl logs --tail=500 --timestamps -n mim <POD_NAME>
```

### C. View Logs of a Crashed Container (Previous Run)
```bash
# If a pod crashed and restarted, view previous crash log:
kubectl logs -n mim <POD_NAME> --previous
```

### D. View Logs for All MongooseIM Pods At Once
```bash
kubectl logs -f -n mim -l app=mongooseim --all-containers
```

---

## 4. 🐚 Going Inside Pods (Interactive Shell)

### A. Open Interactive Bash Shell Inside Pod
```bash
# Open interactive terminal session
kubectl exec -it <POD_NAME> -n mim -- /bin/bash

# If bash is unavailable, fall back to sh:
kubectl exec -it <POD_NAME> -n mim -- sh
```

### B. Run Single Command Without Entering Pod
```bash
# Run uptime or date inside pod
kubectl exec -i <POD_NAME> -n mim -- date

# Inspect active processes
kubectl exec -i <POD_NAME> -n mim -- ps aux
```

---

## 5. 🔑 Extracting Configs & Secret Keys

### A. Inspect MongooseIM Configuration (`mongooseim.toml`)
```bash
kubectl exec -i <POD_NAME> -n mim -- cat /etc/mongooseim/mongooseim.toml
```

### B. Extract JWT Public Key
```bash
kubectl exec -i <POD_NAME> -n mim -- cat /var/lib/mongooseim/jwt_public_key.pem
```

### C. Extract TLS Certificate & Key
```bash
# TLS Certificate
kubectl exec -i <POD_NAME> -n mim -- cat /usr/lib/mongooseim/priv/ssl/fake_cert.pem

# TLS Key
kubectl exec -i <POD_NAME> -n mim -- cat /usr/lib/mongooseim/priv/ssl/fake_key.pem
```

---

## 6. 🛠️ MongooseIM Admin CLI Commands

Run `mongooseimctl` commands directly via `kubectl`:

```bash
# Check cluster status
kubectl exec -i <POD_NAME> -n mim -- mongooseimctl status

# Check log level
kubectl exec -i <POD_NAME> -n mim -- mongooseimctl get_loglevel

# Count registered users for domain
kubectl exec -i <POD_NAME> -n mim -- mongooseimctl account countUsers --domain xmpp-mongo.wingtrill.com

# Register a new test user
kubectl exec -i <POD_NAME> -n mim -- mongooseimctl account register --user testuser --domain xmpp-mongo.wingtrill.com --password mypassword
```
