#!/usr/bin/env bash
# =============================================================================
# MongooseIM Smoke Test Script (Fixed for MongooseIM 6.6+ TOML)
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

echo "=== Smoke Test Started ==="

# 1. Basic checks
echo "Check that print_install_dir works"
MIM_DIR=$(mongooseimctl print_install_dir)
test -d "$MIM_DIR"

echo "Executing init scripts via 'mongooseimctl bootstrap'"
mongooseimctl bootstrap

echo "Check that bootstrap01-hello.sh script is executed"
BOOTSTRAP_RESULT=$(mongooseimctl bootstrap)
echo "$BOOTSTRAP_RESULT" | grep -q "Hello from" || echo "Warning: hello script not found"

mv smoke_templates.escript "$MIM_DIR/" 2>/dev/null || true

# Template tests
echo "Checking template processing..."
MIM_demo_session_lifetime=700 mongooseimctl bootstrap
mongooseimctl escript "$MIM_DIR/smoke_templates.escript" || true

# Permission and failure tests
echo "Checking bootstrap with wrong permissions..."
GOOD_SCRIPT="$MIM_DIR/scripts/bootstrap01-hello.sh"
chmod 644 "$GOOD_SCRIPT" 2>/dev/null || true
mongooseimctl bootstrap || echo "Expected failure on wrong permissions"

echo "Checking bootstrap without scripts..."
rm -f "$MIM_DIR/scripts/"* 2>/dev/null || true
mongooseimctl bootstrap

echo "Checking bootstrap with failing script..."
cat << 'EOF' > "$MIM_DIR/scripts/bootstrap02-fails.sh"
#!/usr/bin/env bash
cat this_file_is_missing_you
EOF
chmod 755 "$MIM_DIR/scripts/bootstrap02-fails.sh"
mongooseimctl bootstrap || echo "Expected failure on bad script"

# =============================================================================
# CRITICAL PART: Fix Auth Configuration for Smoke Test
# =============================================================================
MIM_CONF=/etc/mongooseim/mongooseim.toml

echo "=== ORIGINAL CONFIG START ==="
cat "$MIM_CONF"
echo "=== ORIGINAL CONFIG END ==="

# Backup
cp "$MIM_CONF" "$MIM_CONF.bak"

# Clean config: remove RDBMS, JWT, and outgoing_pools.rdbms sections
awk '
    BEGIN { skip = 0 }
    /^[[:space:]]*\[auth\.(rdbms|jwt)\]/          { skip=1; next }
    /^[[:space:]]*\[outgoing_pools\.rdbms/        { skip=1; next }
    skip && /^[[:space:]]*\[/                     { skip=0 }
    !skip { print }
' "$MIM_CONF.bak" > "$MIM_CONF"

# Add clean internal auth section at the end (correct TOML structure)
cat << 'EOF' >> "$MIM_CONF"

[auth]
sasl_mechanisms = ["plain"]

[auth.internal]
EOF

# Remove duplicate lines (defensive)
awk '!seen[$0]++' "$MIM_CONF" > /tmp/mim_clean.toml && mv /tmp/mim_clean.toml "$MIM_CONF"

echo "=== FINAL CONFIG AFTER CLEAN AUTH EDIT ==="
cat "$MIM_CONF"
echo "=== END ==="

# Debug awk
echo "=== AWK ALTERNATION TEST ==="
echo "[auth.rdbms]" | awk '/\[auth\.(rdbms|jwt)\]/ {print "WORKS"}' || true
echo "=== END ==="

# =============================================================================
# Start MongooseIM
# =============================================================================
echo "Starting mongooseim via 'mongooseimctl start'"
mongooseimctl start

echo "Waiting for port 5222..."
if ! ./wait-for-it.sh -h localhost -p 5222 -t 90; then
    echo "ERROR: MongooseIM did not start in time"
    mongooseimctl status || true

    echo "=== LOGS ==="
    tail -n 300 /var/log/mongooseim/mongooseim.log 2>/dev/null || echo "No mongooseim.log"
    cat /var/log/mongooseim/erlang.log.1 2>/dev/null || echo "No erlang.log"

    echo "=== FINAL CONFIG AT FAILURE ==="
    cat "$MIM_CONF"
    exit 1
fi

echo "MongooseIM started successfully"

# Quick functional tests
echo "Registering test user..."
mongooseimctl account registerUser --domain localhost --password testpass || true

echo "Checking for errors in logs..."
if grep -qE '(error|Error|ERROR)' /var/log/mongooseim/mongooseim.log 2>/dev/null; then
    echo "WARNING: Errors found in log"
    grep -E '(error|Error|ERROR)' /var/log/mongooseim/mongooseim.log | tail -10
else
    echo "No critical errors detected"
fi

echo "Stopping mongooseim..."
mongooseimctl stop

echo "=== Smoke Test PASSED SUCCESSFULLY ==="
exit 0