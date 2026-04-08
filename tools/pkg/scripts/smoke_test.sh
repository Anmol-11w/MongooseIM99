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
MIM_CONF="/etc/mongooseim.toml"
JWT_KEY_FILE="/tmp/smoke_jwt.pem"
MIM_PID=""

cleanup() {
  if [ -n "$MIM_PID" ] && kill -0 "$MIM_PID" 2>/dev/null; then
    kill "$MIM_PID" || true
    wait "$MIM_PID" || true
  fi
}

trap cleanup EXIT

cat << EOF > "$JWT_KEY_FILE"
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAnD6p2zE/F5Yv98/6z5y0X6a3F/Z8I4J5J6K7L8M9N0O=
-----END PUBLIC KEY-----
EOF

cat << EOF > "$MIM_CONF"
[general]
  loglevel = "warning"
  hosts = ["localhost"]
  default_server_domain = "localhost"

[auth]
  methods = ["jwt", "internal"]

[auth.internal]
  password_format = "scram-sha-1"

[auth.jwt]
  secret.file = "$JWT_KEY_FILE"
  algorithm = "RS256"
  username_key = "sub"

[outgoing_pools.rdbms.default]
  scope = "global"
  workers = 1
  [outgoing_pools.rdbms.default.connection]
    driver = "pgsql"
    host = "localhost"
    database = "dummy"

[[listen.http]]
  port = 5280
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
export EJABBERD_CONFIG_PATH="$MIM_CONF"
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

echo "Trying to register users"
mongooseimctl account registerUser --username smoke-test --domain localhost --password a_password
mongooseimctl account registerUser --username smoke-test-2 --domain localhost --password a_password_2

echo "Stopping mongooseim"
cleanup

