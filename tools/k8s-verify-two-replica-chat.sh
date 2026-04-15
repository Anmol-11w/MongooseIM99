#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-mim}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
MIM_CONTAINER="${MIM_CONTAINER:-mongooseim}"
MIM_SELECTOR="${MIM_SELECTOR:-app.kubernetes.io/name=mongooseim}"
MIM_SELECTOR_FALLBACK="${MIM_SELECTOR_FALLBACK:-app=mongooseim}"

POSTGRES_SELECTOR="${POSTGRES_SELECTOR:-app.kubernetes.io/name=mongooseim,app.kubernetes.io/component=postgresql}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-postgresql}"
PG_USER="${PG_USER:-mongooseim}"
PG_DB="${PG_DB:-mongooseim}"

PASSWORD="${PASSWORD:-Test1234}"
USER_PREFIX="${USER_PREFIX:-replicacheck}"
RUN_ID="${RUN_ID:-$(date +%s)}"
SKIP_DB_CHECK="${SKIP_DB_CHECK:-false}"

DOMAIN="${DOMAIN:-}"
POSTGRES_POD="${POSTGRES_POD:-}"

POD_A=""
POD_B=""

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_working_kubectl() {
  if ! "$KUBECTL_BIN" version --client >/dev/null 2>&1; then
    die "kubectl is installed but not executable in this environment. Set KUBECTL_BIN to a compatible binary path."
  fi
}

running_pods_by_selector() {
  local selector="$1"
  "$KUBECTL_BIN" -n "$NAMESPACE" get pods -l "$selector" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sed '/^$/d'
}

running_pods_by_name_pattern() {
  "$KUBECTL_BIN" -n "$NAMESPACE" get pods \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep 'mongooseim' || true
}

select_mongooseim_pods() {
  local pods pod_count
  pods="$(running_pods_by_selector "$MIM_SELECTOR" || true)"
  pod_count="$(printf '%s\n' "$pods" | awk 'NF {c++} END {print c+0}')"

  if [[ "$pod_count" -lt 2 ]]; then
    warn "Selector '$MIM_SELECTOR' found $pod_count running pod(s). Trying fallback selector '$MIM_SELECTOR_FALLBACK'."
    MIM_SELECTOR="$MIM_SELECTOR_FALLBACK"
    pods="$(running_pods_by_selector "$MIM_SELECTOR" || true)"
    pod_count="$(printf '%s\n' "$pods" | awk 'NF {c++} END {print c+0}')"
  fi

  if [[ "$pod_count" -lt 2 ]]; then
    warn "Fallback selector '$MIM_SELECTOR_FALLBACK' found $pod_count running pod(s). Trying pod-name pattern fallback."
    pods="$(running_pods_by_name_pattern)"
    pod_count="$(printf '%s\n' "$pods" | awk 'NF {c++} END {print c+0}')"
  fi

  [[ "$pod_count" -ge 2 ]] || die "Need at least 2 running MongooseIM pods; found $pod_count"

  POD_A="$(printf '%s\n' "$pods" | sed -n '1p')"
  POD_B="$(printf '%s\n' "$pods" | sed -n '2p')"
}

detect_domain() {
  if [[ -n "$DOMAIN" ]]; then
    return
  fi

  DOMAIN="$("$KUBECTL_BIN" -n "$NAMESPACE" exec "$POD_A" -c "$MIM_CONTAINER" -- bash -lc '
    CONF="${EJABBERD_CONFIG_PATH:-/var/lib/mongooseim/etc/mongooseim.toml}"
    awk -F"\"" "/^[[:space:]]*default_server_domain[[:space:]]*=/ { print \$2; exit }" "$CONF"
  ' 2>/dev/null || true)"

  if [[ -z "$DOMAIN" ]]; then
    DOMAIN="$("$KUBECTL_BIN" -n "$NAMESPACE" exec "$POD_A" -c "$MIM_CONTAINER" -- bash -lc '
      CONF="${EJABBERD_CONFIG_PATH:-/var/lib/mongooseim/etc/mongooseim.toml}"
      awk -F"\"" "/^[[:space:]]*hosts[[:space:]]*=/ { print \$2; exit }" "$CONF"
    ' 2>/dev/null || true)"
  fi

  [[ -n "$DOMAIN" ]] || die "Could not detect XMPP domain. Set DOMAIN=<your-domain> and retry."
}

read_vm_arg() {
  local pod="$1"
  local flag="$2"

  if [[ "$flag" == "name" ]]; then
    "$KUBECTL_BIN" -n "$NAMESPACE" exec "$pod" -c "$MIM_CONTAINER" -- sh -lc \
      "awk '/^-s?name[[:space:]]+/{print \$2; exit}' /var/lib/mongooseim/etc/vm.args"
    return
  fi

  "$KUBECTL_BIN" -n "$NAMESPACE" exec "$pod" -c "$MIM_CONTAINER" -- sh -lc \
    "awk '/^-${flag}[[:space:]]+/{print \$2; exit}' /var/lib/mongooseim/etc/vm.args"
}

verify_erlang_identity() {
  local node_a node_b cookie_a cookie_b
  node_a="$(read_vm_arg "$POD_A" "name")"
  node_b="$(read_vm_arg "$POD_B" "name")"
  cookie_a="$(read_vm_arg "$POD_A" "setcookie")"
  cookie_b="$(read_vm_arg "$POD_B" "setcookie")"

  [[ -n "$node_a" && -n "$node_b" ]] || die "Failed to read Erlang node names from vm.args"
  [[ "$node_a" != "$node_b" ]] || die "Both pods use the same Erlang node name: $node_a"
  [[ -n "$cookie_a" && "$cookie_a" == "$cookie_b" ]] || die "Erlang cookie mismatch between pods"

  log "Erlang nodes are unique and share the same cookie"
}

register_user() {
  local pod="$1"
  local username="$2"
  local output

  output="$("$KUBECTL_BIN" -n "$NAMESPACE" exec "$pod" -c "$MIM_CONTAINER" -- \
    mongooseimctl account registerUser \
      --username "$username" \
      --domain "$DOMAIN" \
      --password "$PASSWORD" 2>&1)" || {
      warn "registerUser failed on $pod for $username@$DOMAIN (this is expected for jwt-only auth in some setups)"
      warn "registerUser output: $output"
      return
    }

  log "Registered $username@$DOMAIN on $pod"
}

send_message() {
  local pod="$1"
  local from_jid="$2"
  local to_jid="$3"
  local body="$4"

  "$KUBECTL_BIN" -n "$NAMESPACE" exec "$pod" -c "$MIM_CONTAINER" -- \
    mongooseimctl stanza sendMessage \
      --from "$from_jid" \
      --to "$to_jid" \
      --body "$body" >/dev/null
}

detect_postgres_pod() {
  if [[ -n "$POSTGRES_POD" ]]; then
    return
  fi

  POSTGRES_POD="$("$KUBECTL_BIN" -n "$NAMESPACE" get pods -l "$POSTGRES_SELECTOR" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

  [[ -n "$POSTGRES_POD" ]] || die "PostgreSQL pod not found with selector '$POSTGRES_SELECTOR'. Set POSTGRES_POD=<pod> to override."
}

psql_count() {
  local sql="$1"
  "$KUBECTL_BIN" -n "$NAMESPACE" exec "$POSTGRES_POD" -c "$POSTGRES_CONTAINER" -- \
    psql -U "$PG_USER" -d "$PG_DB" -t -A -c "$sql" | tr -d '[:space:]'
}

verify_db_rows() {
  local user_a="$1"
  local user_b="$2"
  local mam_sql inbox_sql mam_count inbox_count

  mam_sql="SELECT COUNT(*) FROM mam_message WHERE (from_jid LIKE '${user_a}@${DOMAIN}%' AND remote_bare_jid='${user_b}@${DOMAIN}') OR (from_jid LIKE '${user_b}@${DOMAIN}%' AND remote_bare_jid='${user_a}@${DOMAIN}');"
  inbox_sql="SELECT COUNT(*) FROM inbox WHERE lserver='${DOMAIN}' AND ((luser='${user_a}' AND remote_bare_jid='${user_b}@${DOMAIN}') OR (luser='${user_b}' AND remote_bare_jid='${user_a}@${DOMAIN}'));"

  mam_count="$(psql_count "$mam_sql")"
  inbox_count="$(psql_count "$inbox_sql")"

  [[ "$mam_count" =~ ^[0-9]+$ ]] || die "Unexpected mam_message count result: '$mam_count'"
  [[ "$inbox_count" =~ ^[0-9]+$ ]] || die "Unexpected inbox count result: '$inbox_count'"

  if [[ "$mam_count" -lt 1 ]]; then
    die "MAM validation failed: expected >=1 row, got $mam_count"
  fi
  if [[ "$inbox_count" -lt 1 ]]; then
    die "Inbox validation failed: expected >=1 row, got $inbox_count"
  fi

  log "DB validation passed (mam_message=$mam_count, inbox=$inbox_count)"
}

main() {
  require_cmd "$KUBECTL_BIN"
  require_cmd awk
  require_cmd sed
  require_working_kubectl

  log "Selecting MongooseIM pods in namespace '$NAMESPACE'"
  select_mongooseim_pods
  log "Using pods: A=$POD_A B=$POD_B"

  verify_erlang_identity

  detect_domain
  log "Detected XMPP domain: $DOMAIN"

  local user_a user_b from_a from_b msg_a msg_b
  user_a="${USER_PREFIX}a${RUN_ID}"
  user_b="${USER_PREFIX}b${RUN_ID}"
  from_a="${user_a}@${DOMAIN}"
  from_b="${user_b}@${DOMAIN}"

  register_user "$POD_A" "$user_a"
  register_user "$POD_B" "$user_b"

  msg_a="replica-check-${RUN_ID}-A-to-B"
  msg_b="replica-check-${RUN_ID}-B-to-A"

  log "Sending message from $from_a via pod $POD_A to $from_b"
  send_message "$POD_A" "$from_a" "$from_b" "$msg_a"

  log "Sending message from $from_b via pod $POD_B to $from_a"
  send_message "$POD_B" "$from_b" "$from_a" "$msg_b"

  sleep 2

  if [[ "$SKIP_DB_CHECK" == "true" ]]; then
    warn "SKIP_DB_CHECK=true, skipping PostgreSQL validation"
  else
    detect_postgres_pod
    log "Validating DB rows on pod: $POSTGRES_POD"
    verify_db_rows "$user_a" "$user_b"
  fi

  log "Replica chat verification succeeded"
  log "Users used for this run: $from_a and $from_b"
}

main "$@"
