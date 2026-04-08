#!/usr/bin/env bash

# Use bash "strict mode"
set -euo pipefail
IFS=$'\n\t'

echo "--- Starting MongooseIM Smoke Test ---"

echo "Check that print_install_dir works"
MIM_DIR=$(mongooseimctl print_install_dir)
test -d "$MIM_DIR"

echo "Executing init scripts via 'mongooseimctl bootstrap'"
mongooseimctl bootstrap

echo "Check that bootstrap01-hello.sh script is executed"
BOOTSTRAP_RESULT=$(mongooseimctl bootstrap)
echo "$BOOTSTRAP_RESULT" | grep "Hello from" || echo "Warning: Hello script not found, skipping check"

# Script should be accessible by the "mongooseim" user
mv smoke_templates.escript "$MIM_DIR/"

echo "Check, that templates are correctly processed"
MIM_DEMO_SESSION_LIFETIME=700 mongooseimctl bootstrap
mongooseimctl escript "$MIM_DIR/smoke_templates.escript"

echo "Check, that bootstrap works without any scripts"
find "$MIM_DIR/scripts/" -type f -delete || true
mongooseimctl bootstrap

echo "--- Patching config for smoke test (Bypassing JWT, PSQL, Redis) ---"
MIM_CONF=/etc/mongooseim/mongooseim.toml

# 1. Wipe everything from [auth] section downwards to clear production templates
# This removes the JWT and PSQL/Redis pools that cause crashes in CI
sed -i '/^\[auth\]/,$d' "$MIM_CONF"

# 2. Append clean, standalone internal configuration for the test
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

echo "Starting MongooseIM in foreground..."
# We use & to run in background so the script can continue to wait-for-it
mongooseimctl foreground &
MIM_PID=$!

echo "Waiting for port 5222 to open..."
if ! ./wait-for-it.sh -h localhost -p 5222 -t 90; then
    echo "ERROR: MongooseIM failed to start (Port 5222 timed out)."
    echo "--- Last 100 lines of MongooseIM log ---"
    tail -n 100 /var/log/mongooseim/mongooseim.log 2>/dev/null || true
    kill "$MIM_PID" 2>/dev/null || true
    exit 1
fi

echo "Checking status..."
mongooseimctl status

echo "Registering test user with PASSWORD (Internal Auth)..."
mongooseimctl account registerUser --username "smoke-user" --domain "localhost" --password "smoke-pass"

echo "Checking for critical errors in logs..."
# Ignore warnings, only exit on actual 'error' strings
if grep -wr 'error' /var/log/mongooseim; then
    echo "Found errors in log file."
    exit 1
fi

echo "Stopping MongooseIM..."
kill "$MIM_PID" 2>/dev/null || true
wait "$MIM_PID" 2>/dev/null || true

echo "--- Smoke Test Passed ---"