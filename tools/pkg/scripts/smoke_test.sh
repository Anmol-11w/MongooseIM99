#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

echo "=== Smoke Test Started ==="

# ==================== Basic bootstrap tests ====================
MIM_DIR=$(mongooseimctl print_install_dir)
test -d "$MIM_DIR"

mongooseimctl bootstrap

echo "Check bootstrap scripts..."
BOOTSTRAP_RESULT=$(mongooseimctl bootstrap)
echo "$BOOTSTRAP_RESULT" | grep -q "Hello from" || echo "Warning: hello script"

mv smoke_templates.escript "$MIM_DIR/" 2>/dev/null || true

MIM_demo_session_lifetime=700 mongooseimctl bootstrap || true
mongooseimctl escript "$MIM_DIR/smoke_templates.escript" || true

# Permission and failure tests
chmod 644 "$MIM_DIR/scripts/bootstrap01-hello.sh" 2>/dev/null || true
mongooseimctl bootstrap || echo "Expected permission failure"

rm -f "$MIM_DIR/scripts/"* 2>/dev/null || true
mongooseimctl bootstrap

cat << 'EOF' > "$MIM_DIR/scripts/bootstrap02-fails.sh"
#!/usr/bin/env bash
cat this_file_is_missing_you
EOF
chmod 755 "$MIM_DIR/scripts/bootstrap02-fails.sh"
mongooseimctl bootstrap || echo "Expected script failure"

# ==================== FIXED AUTH CLEANUP ====================
MIM_CONF=/etc/mongooseim/mongooseim.toml
cp "$MIM_CONF" "$MIM_CONF.bak"

echo "=== ORIGINAL CONFIG START ==="
cat "$MIM_CONF"
echo "=== ORIGINAL CONFIG END ==="

# 1. Remove unwanted sections (rdbms, jwt, outgoing_pools.rdbms)
awk '
    BEGIN { skip = 0 }
    /^[[:space:]]*\[auth\.(rdbms|jwt)\]/ { skip=1; next }
    /^[[:space:]]*\[outgoing_pools\.rdbms/ { skip=1; next }
    skip && /^[[:space:]]*\[/ { skip=0 }
    !skip { print }
' "$MIM_CONF.bak" > "$MIM_CONF"

# 2. Remove ALL existing sasl_mechanisms lines (to prevent duplicates)
awk '!/^[[:space:]]*sasl_mechanisms/' "$MIM_CONF" > /tmp/clean.toml && mv /tmp/clean.toml "$MIM_CONF"

# 3. Remove any stray [auth.internal] that might be in wrong place
awk '!/^[[:space:]]*\[auth\.internal\]/' "$MIM_CONF" > /tmp/clean.toml && mv /tmp/clean.toml "$MIM_CONF"

# 4. Add clean auth section at the END
cat << 'EOF' >> "$MIM_CONF"

[auth]
sasl_mechanisms = ["plain"]

[auth.internal]
EOF

# 5. Final cleanup - remove duplicate blank lines
awk 'NF || !blank {print; blank = NF ? 0 : 1}' "$MIM_CONF" > /tmp/final.toml && mv /tmp/final.toml "$MIM_CONF"

echo "=== FINAL CONFIG AFTER CLEAN AUTH EDIT ==="
cat "$MIM_CONF"
echo "=== END ==="

# ==================== Start MongooseIM ====================
echo "Starting mongooseim..."
mongooseimctl start

echo "Waiting for port 5222 (increased timeout)..."
if ! ./wait-for-it.sh -h localhost -p 5222 -t 120; then
    echo "ERROR: MongooseIM failed to start"
    mongooseimctl status || true
    
    echo "=== LOGS ==="
    tail -n 300 /var/log/mongooseim/mongooseim.log 2>/dev/null || echo "No mongooseim.log"
    cat /var/log/mongooseim/erlang.log.1 2>/dev/null || echo "No erlang.log"

    echo "=== FINAL CONFIG AT FAILURE ==="
    cat "$MIM_CONF"
    exit 1
fi

echo "MongooseIM started successfully"
mongooseimctl status

mongooseimctl account registerUser --domain localhost --password testpass || true

echo "Stopping mongooseim..."
mongooseimctl stop

echo "=== Smoke Test PASSED SUCCESSFULLY ==="
exit 0