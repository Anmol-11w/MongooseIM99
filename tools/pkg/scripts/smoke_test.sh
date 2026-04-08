#!/usr/bin/env bash

# Use bash "strict mode"
set -euo pipefail
IFS=$'\n\t'

# Print each command before executing for easier debugging
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR

echo "Check that print_install_dir works"
MIM_DIR=$(mongooseimctl print_install_dir)
test -d "$MIM_DIR"

echo "Executing init scripts via 'mongooseimctl bootstrap'"
mongooseimctl bootstrap

echo "Check that bootstrap01-hello.sh script is executed"
BOOTSTRAP_RESULT=$(mongooseimctl bootstrap)
echo "$BOOTSTRAP_RESULT" | grep "Hello from"

# Script should be accessible by the "mongooseim" user
mv smoke_templates.escript "$MIM_DIR/"

echo "Check, that templates are correctly processed"
MIM_DEMO_SESSION_LIFETIME=700 mongooseimctl bootstrap
mongooseimctl escript "$MIM_DIR/smoke_templates.escript"

echo "Check, that bootstrap works without any scripts"
find "$MIM_DIR/scripts/" -type f -delete
mongooseimctl bootstrap

echo "--- Patching config for smoke test (Bypassing JWT, PSQL, Redis) ---"
MIM_CONF=/etc/mongooseim/mongooseim.toml

# 1. Wipe everything from [auth] section downwards to clear production templates
# This removes the JWT and PSQL pools that aren't available during build
sed -i '/^\[auth\]/,$d' "$MIM_CONF"

# 2. Append clean, standalone internal configuration
cat << EOF >> "$MIM_CONF"
[auth]
  methods = ["internal"]

[auth.internal]
  password_format = "scram-sha-1"

[outgoing_pools.rdbms.default]
  scope = "global"
  workers = 2
  [outgoing_pools.rdbms.default.connection]
    driver = "mnesia"

[modules.mod_roster]
  backend = "mnesia"

[modules.mod_contact_sync]
  backend = "mnesia"

[modules.mod_offline]
  backend = "mnesia"
EOF

echo "Starting MongooseIM in foreground"
# Foreground mode is more stable for Docker build layers
mongooseimctl foreground &
MIM_PID=$!

echo "Waiting for port 5222..."
if ! ./wait-for-it.sh -h localhost -p 5222 -t 90; then
    echo "ERROR: MongooseIM failed to start or port 5222 is closed."
    echo "--- Last 100 lines of MongooseIM log ---"
    tail -n 100 /var/log/mongooseim/mongooseim.log 2>/dev/null || true
    kill "$MIM_PID" 2>/dev/null || true
    exit 1
fi

echo "Checking status via 'mongooseimctl status'"
mongooseimctl status

echo "Registering a test user using password auth"
mongooseimctl account registerUser --username "smoke-test-user" --domain "localhost" --password "password123"

echo "Checking if MongooseIM has logged any critical errors"
# We exclude 'warning' because some modules might complain about missing Redis/PSQL gracefully
grep -wr 'error' /var/log/mongooseim && exit 1 || true

echo "Stopping MongooseIM"
kill "$MIM_PID" 2>/dev/null || true
wait "$MIM_PID" 2>/dev/null || true

echo "Smoke test completed successfully"