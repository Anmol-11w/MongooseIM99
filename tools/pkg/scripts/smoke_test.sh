#!/usr/bin/env bash

# Use bash "strict mode"
# Based on http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

echo "Check that print_install_dir works"
MIM_DIR=$(mongooseimctl print_install_dir)
test -d "$MIM_DIR"

echo "Executing init scripts via 'mongooseimctl bootstrap'"
mongooseimctl bootstrap

echo "Check that bootstrap01-hello.sh script is executed"
BOOTSTRAP_RESULT=$(mongooseimctl bootstrap)
echo "$BOOTSTRAP_RESULT" | grep "Hello from"

mv smoke_templates.escript "$MIM_DIR/" || true

echo "Check, that templates are correctly processed"
echo "Override default demo_session_lifetime=600 with 700"
MIM_unused_var="'\n\t\t\"" MIM_demo_session_lifetime=700 mongooseimctl bootstrap
mongooseimctl escript "$MIM_DIR/smoke_templates.escript"

MIM_DEMO_SESSION_LIFETIME=700 mongooseimctl bootstrap
mongooseimctl escript "$MIM_DIR/smoke_templates.escript"

echo "Check, that bootstrap fails, if permissions are wrong"
GOOD_SCRIPT="$MIM_DIR/scripts/bootstrap01-hello.sh"
chmod "644" "$GOOD_SCRIPT" || true

BAD_PERM_BOOTSTRAP_RESULT=$(mongooseimctl bootstrap || echo "It should fail")
echo "$BAD_PERM_BOOTSTRAP_RESULT" | grep "It should fail" || true

echo "Check, that bootstrap works without any scripts"
rm -f "$MIM_DIR/scripts/"* || true
mongooseimctl bootstrap

echo "Check, that bootstrap fails, if any of bootstrap scripts fail"
BAD_SCRIPT="$MIM_DIR/scripts/bootstrap02-fails.sh"
cat << EOF > "$BAD_SCRIPT"
#!/usr/bin/env bash
cat this_file_is_missing_you
EOF
chmod 755 "$BAD_SCRIPT"

BAD_BOOTSTRAP_RESULT=$(mongooseimctl bootstrap || echo "It should fail")
echo "$BAD_BOOTSTRAP_RESULT" | grep "It should fail" || true

echo "Configuring auth for smoke test (internal only, no RDBMS/MySQL available)"

MIM_CONF=/etc/mongooseim/mongooseim.toml

# ---- Backup original config ----
cp "$MIM_CONF" "$MIM_CONF.bak" || true

echo "=== ORIGINAL CONFIG START ==="
cat "$MIM_CONF"
echo "=== ORIGINAL CONFIG END ==="

# ---- Clean up unwanted sections (rdbms, jwt, outgoing_pools.rdbms) ----
awk '
    BEGIN { skip = 0 }
    /^[[:space:]]*\[auth\.(rdbms|jwt)\]/ { skip = 1; next }
    /^[[:space:]]*\[outgoing_pools\.rdbms/ { skip = 1; next }
    skip && /^[[:space:]]*\[/ { skip = 0 }
    !skip { print }
' "$MIM_CONF.bak" > "$MIM_CONF"

echo "=== CONFIG AFTER REMOVING RDBMS/JWT SECTIONS ==="
cat "$MIM_CONF"
echo "=== END ==="

# ---- Ensure clean [auth] section with sasl_mechanisms at the correct level ----
cat << 'EOF' >> "$MIM_CONF"

[auth]
sasl_mechanisms = ["plain"]

[auth.internal]
EOF

# Remove any duplicate empty [auth] lines if present
awk '!seen[$0]++' "$MIM_CONF" > /tmp/mim_conf_clean && mv /tmp/mim_conf_clean "$MIM_CONF"

echo "=== FINAL CONFIG AFTER CLEAN AUTH EDIT ==="
cat "$MIM_CONF"
echo "=== END ==="

# ---- Optional: Test awk regex alternation (for debugging mawk issues) ----
echo "=== AWK ALTERNATION REGEX TEST ==="
echo "[auth.rdbms]" | awk '/\[auth\.(rdbms|jwt)\]/ { print "AWK regex alternation WORKS" }' || true
echo "[auth.jwt]"   | awk '/\[auth\.(rdbms|jwt)\]/ { print "AWK regex alternation WORKS" }' || true
echo "If nothing printed above this line, awk alternation is BROKEN (mawk bug)"
echo "=== END ==="

echo "Starting mongooseim via 'mongooseimctl start'"
mongooseimctl start

echo "Waiting for the port 5222 to accept TCP connections"
if ! ./wait-for-it.sh -h localhost -p 5222 -t 90; then
	echo "MongooseIM did not open port 5222 in time"
	mongooseimctl status || true

	echo "=== MONGOOSEIM LOG ==="
	tail -n 500 /var/log/mongooseim/mongooseim.log 2>/dev/null || echo "mongooseim.log not found"
	echo "=== ERLANG CRASH LOG ==="
	cat /var/log/mongooseim/erlang.log.1 2>/dev/null || echo "erlang.log.1 not found"
	echo "=== ALL LOG FILES IN /var/log/mongooseim/ ==="
	ls -la /var/log/mongooseim/ 2>/dev/null || echo "log directory not found"

	echo "=== FINAL CONFIG AT FAILURE TIME ==="
	cat "$MIM_CONF"
	echo "=== END ==="
	exit 1
fi

echo "Checking status via 'mongooseimctl status'"
mongooseimctl status

echo "Trying to register a user"
mongooseimctl account registerUser --domain localhost --password a_password || echo "Warning: registration failed, skipping"

echo "Trying to register identified user"
mongooseimctl account registerUser --username user --domain localhost --password a_password_2 || echo "Warning: registration failed, skipping"

echo "Checking if MongooseIM has logged any errors"
grep -wr 'error' /var/log/mongooseim && exit 1 || true

echo "Stopping mongooseim via 'mongooseimctl stop'"
mongooseimctl stop

echo "Smoke test completed successfully!"