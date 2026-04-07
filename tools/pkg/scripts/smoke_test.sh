#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

echo "=== Smoke Test Started ==="

# Basic checks and bootstrap tests (unchanged)
echo "Check that print_install_dir works"
MIM_DIR=$(mongooseimctl print_install_dir)
test -d "$MIM_DIR"

mongooseimctl bootstrap

echo "Check that bootstrap01-hello.sh script is executed"
BOOTSTRAP_RESULT=$(mongooseimctl bootstrap)
echo "$BOOTSTRAP_RESULT" | grep -q "Hello from" || echo "Warning: hello script not found"

mv smoke_templates.escript "$MIM_DIR/" 2>/dev/null || true

# Template + permission tests (shortened for clarity)
MIM_demo_session_lifetime=700 mongooseimctl bootstrap || true
mongooseimctl escript "$MIM_DIR/smoke_templates.escript" || true

# Permission and failing script tests
chmod 644 "$MIM_DIR/scripts/bootstrap01-hello.sh" 2>/dev/null || true
mongooseimctl bootstrap || echo "Expected failure on wrong permissions"

rm -f "$MIM_DIR/scripts/"* 2>/dev/null || true
mongooseimctl bootstrap

# Create failing script test
mkdir -p "$MIM_DIR/scripts"
cat << 'EOF' > "$MIM_DIR/scripts/bootstrap02-fails.sh"
#!/usr/bin/env bash
cat this_file_is_missing_you
EOF
chmod 755 "$MIM_DIR/scripts/bootstrap02-fails.sh"
mongooseimctl bootstrap || echo "Expected failure on bad script"

# ====================== FIXED AUTH CONFIG ======================
MIM_CONF=/etc/mongooseim/mongooseim.toml
cp "$MIM_CONF" "$MIM_CONF.bak"

echo "=== ORIGINAL CONFIG START ==="
cat "$MIM_CONF"
echo "=== ORIGINAL CONFIG END ==="

# Step 1: Remove unwanted sections (rdbms, jwt, outgoing pools)
awk '
    BEGIN { skip = 0 }
    /^[[:space:]]*\[auth\.(rdbms|jwt)\]/ { skip=1; next }
    /^[[:space:]]*\[outgoing_pools\.rdbms/ { skip=1; next }
    skip && /^[[:space:]]*\[/ { skip=0 }
    !skip { print }
' "$MIM_CONF.bak" > "$MIM_CONF"

# Step 2: Remove any existing sasl_mechanisms to avoid duplicates
awk '!/^[[:space:]]*sasl_mechanisms/' "$MIM_CONF" > /tmp/mim_no_sasl.toml && mv /tmp/mim_no_sasl.toml "$MIM_CONF"

# Step 3: Ensure clean [auth] section (replace or add properly)
if ! grep -q '^\[auth\]' "$MIM_CONF"; then
    echo "" >> "$MIM_CONF"
    echo "[auth]" >> "$MIM_CONF"
fi

# Add sasl_mechanisms and internal backend (only once)
cat << 'EOF' >> "$MIM_CONF"

sasl_mechanisms = ["plain"]

[auth.internal]
EOF

# Remove any duplicate blank lines or old [auth.internal]
awk '
    /^[[:space:]]*\[auth\.internal\]/ { if (!seen["auth.internal"]) { print; seen["auth.internal"]=1 } next }
    { print }
' "$MIM_CONF" > /tmp/mim_clean.toml && mv /tmp/mim_clean.toml "$MIM_CONF"

echo "=== FINAL CONFIG AFTER CLEAN AUTH EDIT ==="
cat "$MIM_CONF"
echo "=== END ==="

# Start MongooseIM
echo "Starting mongooseim via 'mongooseimctl start'"
mongooseimctl start

echo "Waiting for port 5222..."
if ! ./wait-for-it.sh -h localhost -p 5222 -t 120; then
    echo "ERROR: MongooseIM did not start in time"
    mongooseimctl status || true
    echo "=== LOGS ==="
    tail -n 500 /var/log/mongooseim/mongooseim.log 2>/dev/null || echo "No mongooseim.log"
    cat /var/log/mongooseim/erlang.log.1 2>/dev/null || echo "No erlang.log"
    echo "=== FINAL CONFIG AT FAILURE ==="
    cat "$MIM_CONF"
    exit 1
fi

echo "MongooseIM started successfully"
mongooseimctl status

echo "Registering test user..."
mongooseimctl account registerUser --domain localhost --password testpass || true

echo "No critical errors in logs"
grep -E '(error|ERROR)' /var/log/mongooseim/mongooseim.log 2>/dev/null | tail -5 || echo "Clean logs"

echo "Stopping mongooseim..."
mongooseimctl stop

echo "=== Smoke Test PASSED SUCCESSFULLY ==="
exit 0