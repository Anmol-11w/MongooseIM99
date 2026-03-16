#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <preset>"
  echo "Supported presets: internal_mnesia, pgsql_mnesia, mysql_redis, ldap_mnesia, elasticsearch_and_cassandra_mnesia"
  exit 1
fi

PRESET="$1"
ROOT_DIR="$(cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd)"

source "${ROOT_DIR}/tools/db-versions.sh"

NAMESPACE="ci-${PRESET//_/-}"
DEFAULT_TIMEOUT="420s"
TIMEOUT="${K8S_SMOKE_TIMEOUT:-$DEFAULT_TIMEOUT}"

announce() {
  echo
  echo "==> $1"
}

wait_for_deployment() {
  local deployment_name="$1"
  local deployment_timeout="${2:-$TIMEOUT}"

  kubectl -n "$NAMESPACE" rollout status "deployment/${deployment_name}" --timeout="$deployment_timeout"
}

ensure_namespace() {
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

on_error() {
  echo
  echo "Kubernetes backend smoke failed for preset '${PRESET}'"
  kubectl -n "$NAMESPACE" get pods -o wide || true
  kubectl -n "$NAMESPACE" get svc || true
  kubectl -n "$NAMESPACE" describe pods || true
}

trap on_error ERR

deploy_redis() {
  cat <<EOF | kubectl -n "$NAMESPACE" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:${REDIS_VERSION}
        ports:
        - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  selector:
    app: redis
  ports:
  - name: redis
    port: 6379
    targetPort: 6379
EOF
  wait_for_deployment redis
}

deploy_minio() {
  cat <<EOF | kubectl -n "$NAMESPACE" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: minio/minio:${MINIO_VERSION}
        args: ["server", "/data", "--console-address", ":9001"]
        env:
        - name: MINIO_ACCESS_KEY
          value: "AKIAIAOAONIULXQGMOUA"
        - name: MINIO_SECRET_KEY
          value: "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"
        ports:
        - containerPort: 9000
        - containerPort: 9001
---
apiVersion: v1
kind: Service
metadata:
  name: minio
spec:
  selector:
    app: minio
  ports:
  - name: minio
    port: 9000
    targetPort: 9000
  - name: minio-console
    port: 9001
    targetPort: 9001
EOF
  wait_for_deployment minio
}

deploy_pgsql() {
  cat <<EOF | kubectl -n "$NAMESPACE" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgsql
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pgsql
  template:
    metadata:
      labels:
        app: pgsql
    spec:
      containers:
      - name: pgsql
        image: postgres:${PGSQL_VERSION}
        env:
        - name: POSTGRES_PASSWORD
          value: "password"
        - name: POSTGRES_DB
          value: "mongooseim"
        - name: POSTGRES_USER
          value: "mongooseim"
        ports:
        - containerPort: 5432
---
apiVersion: v1
kind: Service
metadata:
  name: pgsql
spec:
  selector:
    app: pgsql
  ports:
  - name: pgsql
    port: 5432
    targetPort: 5432
EOF
  wait_for_deployment pgsql
}

deploy_mysql() {
  cat <<EOF | kubectl -n "$NAMESPACE" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - name: mysql
        image: mysql:${MYSQL_VERSION}
        env:
        - name: MYSQL_ROOT_PASSWORD
          value: "secret"
        - name: MYSQL_DATABASE
          value: "mongooseim"
        - name: MYSQL_USER
          value: "mongooseim"
        - name: MYSQL_PASSWORD
          value: "mongooseim_secret"
        ports:
        - containerPort: 3306
---
apiVersion: v1
kind: Service
metadata:
  name: mysql
spec:
  selector:
    app: mysql
  ports:
  - name: mysql
    port: 3306
    targetPort: 3306
EOF
  wait_for_deployment mysql
}

deploy_rmq() {
  cat <<EOF | kubectl -n "$NAMESPACE" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rmq
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rmq
  template:
    metadata:
      labels:
        app: rmq
    spec:
      containers:
      - name: rmq
        image: rabbitmq:${RMQ_VERSION}
        ports:
        - containerPort: 5672
        - containerPort: 15672
---
apiVersion: v1
kind: Service
metadata:
  name: rmq
spec:
  selector:
    app: rmq
  ports:
  - name: amqp
    port: 5672
    targetPort: 5672
  - name: http
    port: 15672
    targetPort: 15672
EOF
  wait_for_deployment rmq
}

deploy_ldap() {
  cat <<EOF | kubectl -n "$NAMESPACE" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ldap
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ldap
  template:
    metadata:
      labels:
        app: ldap
    spec:
      containers:
      - name: ldap
        image: osixia/openldap:${LDAP_VERSION}
        env:
        - name: LDAP_DOMAIN
          value: "esl.com"
        - name: LDAP_ORGANISATION
          value: "Erlang Solutions"
        - name: LDAP_ADMIN_PASSWORD
          value: "mongooseim_secret"
        ports:
        - containerPort: 389
        - containerPort: 636
---
apiVersion: v1
kind: Service
metadata:
  name: ldap
spec:
  selector:
    app: ldap
  ports:
  - name: ldap
    port: 389
    targetPort: 389
  - name: ldaps
    port: 636
    targetPort: 636
EOF
  wait_for_deployment ldap
}

deploy_elasticsearch() {
  cat <<EOF | kubectl -n "$NAMESPACE" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: elasticsearch
spec:
  replicas: 1
  selector:
    matchLabels:
      app: elasticsearch
  template:
    metadata:
      labels:
        app: elasticsearch
    spec:
      containers:
      - name: elasticsearch
        image: docker.elastic.co/elasticsearch/elasticsearch:${ELASTICSEARCH_VERSION}
        env:
        - name: ES_JAVA_OPTS
          value: "-Xms512m -Xmx512m"
        ports:
        - containerPort: 9200
---
apiVersion: v1
kind: Service
metadata:
  name: elasticsearch
spec:
  selector:
    app: elasticsearch
  ports:
  - name: http
    port: 9200
    targetPort: 9200
EOF
  wait_for_deployment elasticsearch 600s
}

deploy_cassandra() {
  cat <<EOF | kubectl -n "$NAMESPACE" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cassandra
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cassandra
  template:
    metadata:
      labels:
        app: cassandra
    spec:
      containers:
      - name: cassandra
        image: cassandra:${CASSANDRA_VERSION}
        env:
        - name: HEAP_NEWSIZE
          value: "64M"
        - name: MAX_HEAP_SIZE
          value: "256M"
        ports:
        - containerPort: 9042
---
apiVersion: v1
kind: Service
metadata:
  name: cassandra
spec:
  selector:
    app: cassandra
  ports:
  - name: cql
    port: 9042
    targetPort: 9042
EOF
  wait_for_deployment cassandra 600s
}

run_preset() {
  case "$PRESET" in
    internal_mnesia)
      deploy_redis
      deploy_minio
      ;;
    pgsql_mnesia)
      deploy_redis
      deploy_pgsql
      ;;
    mysql_redis)
      deploy_redis
      deploy_mysql
      deploy_rmq
      ;;
    ldap_mnesia)
      deploy_redis
      deploy_ldap
      ;;
    elasticsearch_and_cassandra_mnesia)
      deploy_redis
      deploy_elasticsearch
      deploy_cassandra
      ;;
    *)
      echo "Unsupported preset '${PRESET}'"
      exit 1
      ;;
  esac
}

announce "Creating namespace '${NAMESPACE}'"
ensure_namespace

announce "Deploying Kubernetes backend profile for preset '${PRESET}'"
run_preset

announce "Kubernetes backend smoke summary"
kubectl -n "$NAMESPACE" get deploy,pods,svc

echo
echo "Kubernetes backend smoke passed for preset '${PRESET}'"
