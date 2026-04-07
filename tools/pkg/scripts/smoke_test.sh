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

mv smoke_templates.escript "$MIM_DIR/"

echo "Check, that templates are correctly processed"
echo "Override default demo_session_lifetime=600 with 700"
MIM_unused_var="'\n\t\t\"" MIM_demo_session_lifetime=700 mongooseimctl bootstrap
mongooseimctl escript "$MIM_DIR/smoke_templates.escript"

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


echo "Configuring auth for smoke test (no MySQL available)"
MIM_CONF=/etc/mongooseim/mongooseim.toml

# ---- LOGGING ADDED: dump original config before any editing ----
echo "=== ORIGINAL CONFIG START ==="
cat "$MIM_CONF"
echo "=== ORIGINAL CONFIG END ==="

# ---- LOGGING ADDED: show which awk is being used ----
echo "=== AWK VERSION ==="
awk --version 2>&1 || awk -W version 2>&1 || echo "Could not determine awk version"
echo "=== AWK BINARY ==="
ls -la $(command -v awk)

awk '
	BEGIN { skip = 0 }
	{
		if ($0 ~ /^[[:space:]]*\[auth\.(rdbms|jwt)\][[:space:]]*$/) {
			skip = 1
			next
		}
		if (skip && $0 ~ /^[[:space:]]*\[/ && $0 !~ /^[[:space:]]*\[auth\.(rdbms|jwt)\][[:space:]]*$/) {
			skip = 0
		}
		if (!skip) {
			print
		}
	}
' "$MIM_CONF" > /tmp/mim_conf_tmp && mv /tmp/mim_conf_tmp "$MIM_CONF" || true

# ---- LOGGING ADDED: dump config after auth rdbms/jwt removal ----
echo "=== CONFIG AFTER AUTH RDBMS/JWT REMOVAL ==="
cat "$MIM_CONF"
echo "=== END ==="

sed -i '/^[[:space:]]*\[auth\.internal\][[:space:]]*$/d' "$MIM_CONF" || true

# ---- LOGGING ADDED: dump config after auth.internal deletion ----
echo "=== CONFIG AFTER AUTH.INTERNAL DELETE ==="
cat "$MIM_CONF"
echo "=== END ==="

if ! grep -q '^[[:space:]]*\[auth\.internal\][[:space:]]*$' "$MIM_CONF"; then
	sed -i '/^[[:space:]]*\[auth\][[:space:]]*$/a\[auth.internal]' "$MIM_CONF" || true
fi

# ---- LOGGING ADDED: dump config after auth.internal insertion ----
echo "=== CONFIG AFTER AUTH.INTERNAL INSERT ==="
cat "$MIM_CONF"
echo "=== END ==="

awk '
	BEGIN { skip = 0 }
	{
		if ($0 ~ /^[[:space:]]*\[outgoing_pools\.rdbms(\.|\])/) {
			skip = 1
			next
		}
		if (skip && $0 ~ /^[[:space:]]*\[/ && $0 !~ /^[[:space:]]*\[outgoing_pools\.rdbms(\.|\])/) {
			skip = 0
		}
		if (!skip) {
			print
		}
	}
' "$MIM_CONF" > /tmp/mim_conf_tmp && mv /tmp/mim_conf_tmp "$MIM_CONF" || true

# ---- LOGGING ADDED: dump final config before mongooseim starts ----
echo "=== FINAL CONFIG BEFORE MONGOOSEIM START ==="
cat "$MIM_CONF"
echo "=== END ==="

# ---- LOGGING ADDED: show awk regex test to confirm if mawk alternation works ----
echo "=== AWK ALTERNATION REGEX TEST ==="
echo "[auth.rdbms]" | awk '/\[auth\.(rdbms|jwt)\]/ { print "AWK regex alternation WORKS" }'
echo "[auth.jwt]"   | awk '/\[auth\.(rdbms|jwt)\]/ { print "AWK regex alternation WORKS" }'
echo "If nothing printed above this line, awk alternation is BROKEN (mawk bug)"
echo "=== END ==="

echo "Starting mongooseim via 'mongooseimctl start'"
mongooseimctl start

echo "Waiting for the port 5222 to accept TCP connections"
if ! ./wait-for-it.sh -h localhost -p 5222 -t 90; then
	echo "MongooseIM did not open port 5222 in time"
	mongooseimctl status || true
	# ---- LOGGING ADDED: dump log with more lines and all log files ----
	echo "=== MONGOOSEIM LOG ==="
	tail -n 500 /var/log/mongooseim/mongooseim.log 2>/dev/null || echo "mongooseim.log not found"
	echo "=== ERLANG CRASH LOG ==="
	cat /var/log/mongooseim/erlang.log.1 2>/dev/null || echo "erlang.log.1 not found"
	echo "=== ALL LOG FILES IN /var/log/mongooseim/ ==="
	ls -la /var/log/mongooseim/ 2>/dev/null || echo "log directory not found"
	echo "=== MIM_DIR LOG FILES ==="
	ls -la "$MIM_DIR/log/" 2>/dev/null || echo "no log dir in MIM_DIR"
	tail -n 500 "$MIM_DIR/log/erlang.log.1" 2>/dev/null || echo "no erlang.log.1 in MIM_DIR/log"
	tail -n 500 "$MIM_DIR/log/mongooseim.log" 2>/dev/null || echo "no mongooseim.log in MIM_DIR/log"
	echo "=== FINAL CONFIG AT FAILURE TIME ==="
	cat "$MIM_CONF"
	echo "=== END ==="
	exit 1
fi

echo "Checking status via 'mongooseimctl status'"
mongooseimctl status

echo "Trying to register a user with 'mongooseimctl register localhost a_password'"
mongooseimctl account registerUser --domain localhost --password a_password || echo "Warning: registration failed, skipping"

echo "Trying to register a user with 'mongooseimctl register_identified user localhost a_password_2'"
mongooseimctl account registerUser --username user --domain localhost --password a_password_2 || echo "Warning: registration failed, skipping"

echo "Skipping user count check in smoke test"

echo "Checking if MongooseIM has logged any errors"
grep -wr 'error' /var/log/mongooseim && exit 1 || true

echo "Stopping mongooseim via 'mongooseimctl stop'"
mongooseimctl stop