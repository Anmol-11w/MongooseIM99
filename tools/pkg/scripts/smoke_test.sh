#!/usr/bin/env bash

# Use bash "strict mode"
# Based on http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

echo "Check that print_install_dir works"
MIM_DIR=$(mongooseimctl print_install_dir)
test -d "$MIM_DIR"

echo "Executing init scripts via 'mongooseimctl bootstrap'"
# Fails, if the exit code is wrong
mongooseimctl bootstrap

echo "Check that bootstrap01-hello.sh script is executed"
BOOTSTRAP_RESULT=$(mongooseimctl bootstrap)
echo "$BOOTSTRAP_RESULT" | grep "Hello from"

# Script should be accessable by the "mongooseim" user
mv smoke_templates.escript "$MIM_DIR/"

echo "Check, that templates are correctly processed"
echo "Override default demo_session_lifetime=600 with 700"
# We check escaping with MIM_unused_var
MIM_unused_var="'\n\t\t\"" MIM_demo_session_lifetime=700 mongooseimctl bootstrap
mongooseimctl escript "$MIM_DIR/smoke_templates.escript"

# Uppercase variables also work
MIM_DEMO_SESSION_LIFETIME=700 mongooseimctl bootstrap
mongooseimctl escript "$MIM_DIR/smoke_templates.escript"

echo "Check, that bootstrap fails, if permissions are wrong"
GOOD_SCRIPT="$MIM_DIR/scripts/bootstrap01-hello.sh"
chmod "644" "$GOOD_SCRIPT"

BAD_PERM_BOOTSTRAP_RESULT=$(mongooseimctl bootstrap || echo "It should fail")
echo "$BAD_PERM_BOOTSTRAP_RESULT" | grep "It should fail"


echo "Check, that bootstrap works without any scripts"
rm "$MIM_DIR/scripts/"*
mongooseimctl bootstrap


echo "Check, that bootstrap fails, if any of bootstrap scripts fail"
BAD_SCRIPT="$MIM_DIR/scripts/bootstrap02-fails.sh"
cat << EOF > "$BAD_SCRIPT"
#!/usr/bin/env bash

cat this_file_is_missing_you
EOF

chmod 755 "$BAD_SCRIPT"

BAD_BOOTSTRAP_RESULT=$(mongooseimctl bootstrap || echo "It should fail")
echo "$BAD_BOOTSTRAP_RESULT" | grep "It should fail"


echo "Preparing minimal smoke-test config (no external DB required)"
MIM_CONF="/etc/mongooseim/mongooseim.toml"
MIM_PID=""

cleanup() {
  if [ -n "$MIM_PID" ] && kill -0 "$MIM_PID" 2>/dev/null; then
    kill "$MIM_PID" || true
    wait "$MIM_PID" || true
  fi
}

trap cleanup EXIT

cat << EOF > "$MIM_CONF"
[general]
  loglevel = "warning"
  hosts = ["localhost"]
  default_server_domain = "localhost"

[auth]
  methods = ["jwt"]
  sasl_mechanisms = ["plain"]

[auth.jwt]
  secret.value = "smoke-jwt-secret"
  algorithm = "HS256"
  username_key = "user"


[[listen.http]]
  port = 5280
  transport.num_acceptors = 10
  transport.max_connections = 1024

  [[listen.http.handlers.mongoose_graphql_handler]]
    host = "_"
    path = "/api/graphql"
    schema_endpoint = "user"

  [[listen.http.handlers.mongoose_bosh_handler]]
    host = "_"
    path = "/http-bind"

[[listen.c2s]]
  port = 5222
  access = "c2s"

[modules.mod_roster]
  backend = "mnesia"

[modules.mod_offline]
  backend = "mnesia"
EOF

echo "Starting mongooseim in foreground"
/usr/lib/mongooseim/bin/mongooseim foreground &
MIM_PID=$!

echo "Waiting for the port 5222 to accept TCP connections"
if ! ./wait-for-it.sh -h localhost -p 5222 -t 90; then
	echo "MongooseIM did not open port 5222 in time"
	tail -n 200 /var/log/mongooseim/mongooseim.log 2>/dev/null || true
	tail -n 200 /usr/lib/mongooseim/log/mongooseim.log 2>/dev/null || true
	exit 1
fi

echo "Checking status via 'mongooseimctl status'"
mongooseimctl status

echo "Checking JWT authentication via GraphQL user endpoint"

jwt_b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

JWT_SECRET="smoke-jwt-secret"
JWT_USER="smokeuser"
JWT_NOW="$(date +%s)"
JWT_EXP="$((JWT_NOW + 300))"

JWT_HEADER='{"alg":"HS256","typ":"JWT"}'
JWT_PAYLOAD="{\"user\":\"${JWT_USER}\",\"iat\":${JWT_NOW},\"nbf\":${JWT_NOW},\"exp\":${JWT_EXP}}"

JWT_HEADER_B64="$(printf '%s' "$JWT_HEADER" | jwt_b64url)"
JWT_PAYLOAD_B64="$(printf '%s' "$JWT_PAYLOAD" | jwt_b64url)"
JWT_SIGNING_INPUT="${JWT_HEADER_B64}.${JWT_PAYLOAD_B64}"
JWT_SIGNATURE_B64="$(printf '%s' "$JWT_SIGNING_INPUT" \
  | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary \
  | jwt_b64url)"
JWT_TOKEN="${JWT_SIGNING_INPUT}.${JWT_SIGNATURE_B64}"

GRAPHQL_QUERY='{"query":"query { checkAuth { authStatus username } }"}'
AUTH_RAW="${JWT_USER}@localhost:${JWT_TOKEN}"
AUTH_HEADER="$(printf '%s' "$AUTH_RAW" | openssl base64 -A)"

HTTP_RESPONSE="$({
  exec 3<>/dev/tcp/localhost/5280
  printf 'POST /api/graphql HTTP/1.1\r\nHost: localhost\r\nAuthorization: Basic %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
    "$AUTH_HEADER" "${#GRAPHQL_QUERY}" "$GRAPHQL_QUERY" >&3
  cat <&3
  exec 3<&-
  exec 3>&-
} || true)"

if ! printf '%s' "$HTTP_RESPONSE" | head -n1 | grep -q ' 200 '; then
  echo "JWT auth check failed: expected HTTP 200 from /api/graphql"
  printf '%s\n' "$HTTP_RESPONSE" | head -n 40
  exit 1
fi

if ! printf '%s' "$HTTP_RESPONSE" | grep -q '"authStatus":"AUTHORIZED"'; then
  echo "JWT auth check failed: expected authStatus AUTHORIZED"
  printf '%s\n' "$HTTP_RESPONSE" | head -n 40
  exit 1
fi

if ! printf '%s' "$HTTP_RESPONSE" | grep -q '"username":"smokeuser@localhost"'; then
  echo "JWT auth check failed: expected username smokeuser@localhost"
  printf '%s\n' "$HTTP_RESPONSE" | head -n 40
  exit 1
fi

echo "JWT authentication smoke check passed"

echo "Stopping mongooseim"
cleanup

