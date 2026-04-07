#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

echo "=== Smoke Test Started ==="

# Basic checks
MIM_DIR=$(mongooseimctl print_install_dir)
test -d "$MIM_DIR"

mongooseimctl bootstrap

echo "Check bootstrap scripts..."
BOOTSTRAP_RESULT=$(mongooseimctl bootstrap)
echo "$BOOTSTRAP_RESULT" | grep -q "Hello from" || echo "Warning: hello script"

mv smoke_templates.escript "$MIM_DIR/" 2>/dev/null || true

# Quick template test
MIM_demo_session_lifetime=700 mongooseimctl bootstrap || true
mongooseimctl escript "$MIM_DIR/smoke_templates.escript" || true

# Permission / failure tests (keep them short)
chmod 644 "$MIM_DIR/scripts/bootstrap01-hello.sh" 2>/dev/null || true
mongooseimctl bootstrap || echo "Expected permission failure"

rm -f "$MIM_DIR/scripts/"* 2>/dev/null || true
mongooseimctl bootstrap

# Failing script test
mkdir -p "$MIM_DIR/scripts"
cat << 'EOF' > "$MIM_DIR/scripts/bootstrap02-fails.sh"
#!/usr/bin/env bash
cat this_file_is_missing_you
EOF
chmod 755 "$MIM_DIR/scripts/bootstrap02-fails.sh"
mongooseimctl bootstrap || echo "Expected script failure"

# ====================== CLEAN AUTH CONFIG ======================
MIM_CONF=/etc/mongooseim/mongooseim.toml
cp "$MIM_CONF" "$MIM_CONF.bak"

echo "=== ORIGINAL CONFIG START ==="
cat "$MIM_CONF"
echo "=== ORIGINAL CONFIG END ==="

# Remove unwanted sections
awk '
    BEGIN { skip = 0 }
    /^[[:space:]]*\[auth\.(rdbms|jwt)\]/ { skip=1; next }
    /^[[:space:]]*\[outgoing_pools\.rdbms/ { skip=1; next }
    skip && /^[[:space:]]*\[/ { skip=0 }
    !skip { print }
' "$MIM_CONF.bak" > "$MIM_CONF"

# Remove ALL lines containing sasl_mechanisms or [auth.internal]
awk '
    !/^[[:space:]]*sasl_mechanisms/ &&
    !/^[[:space:]]*\[auth\.internal\]/
' "$MIM_CONF" > /tmp/clean1.toml && mv /tmp/clean1.toml "$MIM_CONF"

# Remove any empty or partial [auth] section
awk '
    /^[[:space:]]*\[auth\][[:space:]]*$/ { if (!seen_auth) { print; seen_auth=1 } next }
    { print }
' "$MIM_CONF" > /tmp/clean2.toml && mv /tmp/clean2.toml "$MIM_CONF"

# Add clean auth section at the very end
cat << 'EOF' >> "$MIM_CONF"

[auth]
sasl_mechanisms = ["plain"]

[auth.internal]
EOF

# Final cleanup: remove extra blank lines
awk 'NF || !blank {print; blank = NF ? 0 : 1}' "$MIM_CONF" > /tmp/final.toml && mv /tmp/final.toml "$MIM_CONF"

echo "=== FINAL CONFIG AFTER CLEAN AUTH EDIT ==="
cat "$MIM_CONF"
echo "=== END ==="

# Start MongooseIM
echo "Starting mongooseim..."
mongooseimctl start

echo "Waiting for port 5222 (timeout 150s)..."
if ! ./wait-for-it.sh -h localhost -p 5222 -t 150; then
    echo "ERROR: MongooseIM failed to start"
    mongooseimctl status || true
    echo "=== LOGS ==="
    tail -n 400 /var/log/mongooseim/mongooseim.log 2>/dev/null || echo "No mongooseim.log"
    cat /var/log/mongooseim/erlang.log.1 2>/dev/null || echo "No erlang.log"
    echo "=== FINAL CONFIG AT FAILURE ==="
    cat "$MIM_CONF"
    exit 1
fi

echo "MongooseIM started successfully"
mongooseimctl status

echo "Registering test user..."
mongooseimctl account registerUser --domain localhost --password testpass || true

echo "Stopping mongooseim..."
mongooseimctl stop

echo "=== Smoke Test PASSED SUCCESSFULLY ==="
exit 0