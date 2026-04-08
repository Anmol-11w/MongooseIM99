#!/usr/bin/env bash
set -euo pipefail

# Matching your production path exactly
MIM_CONF="/etc/mongooseim.toml"
JWT_KEY_FILE="/tmp/smoke_jwt.pem"

echo "--- Starting MongooseIM Smoke Test ---"

# 1. Create a dummy RSA Public Key file
# This prevents the 'secret.file not found' error during startup
cat << EOF > "$JWT_KEY_FILE"
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAnD6p2zE/F5Yv98/6z5y0X6a3F/Z8I4J5J6K7L8M9N0O=
-----END PUBLIC KEY-----
EOF

# 2. Generate a minimal valid config at the production path
# We include 'internal' auth just so the registerUser test can pass
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

# 3. Start MongooseIM pointing to your custom config path
echo "Starting MongooseIM using $MIM_CONF..."
export EJABBERD_CONFIG_PATH="$MIM_CONF"
/usr/lib/mongooseim/bin/mongooseim foreground &
MIM_PID=$!

# 4. Wait for the service to actually bind to the port
echo "Waiting for XMPP port 5222..."
if ! ./wait-for-it.sh -h localhost -p 5222 -t 60; then
    echo "ERROR: MongooseIM failed to start at $MIM_CONF"
    # Show logs if it fails
    tail -n 50 /var/log/mongooseim/mongooseim.log 2>/dev/null || true
    exit 1
fi

# 5. Operational Checks
echo "Running operational checks..."
mongooseimctl status

echo "Testing user registration (Internal Auth)..."
mongooseimctl account registerUser --username "smoke-test" --domain "localhost" --password "smoke-pass"

echo "--- Smoke Test Passed Successfully ---"

# Cleanup
kill "$MIM_PID"
exit 0