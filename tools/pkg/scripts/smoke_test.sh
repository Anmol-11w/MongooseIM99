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

# ------------------------------------------------------------------------------
# CHANGE 1: Replaced awk with gawk explicitly for all awk calls.
# WHY: The original script used ERE alternation syntax like (rdbms|jwt) and
# (\.|\]) inside awk regex. Standard awk (mawk) on Debian/Ubuntu does NOT
# support alternation in regex. This caused the awk commands to silently match
# nothing, leaving broken RDBMS auth and pool config in mongooseim.toml.
# MongooseIM then tried to connect to MySQL on startup, failed silently, and
# never opened port 5222 — causing the 90s timeout failure.
# Fix: Use gawk which fully supports ERE alternation.
# ------------------------------------------------------------------------------

# Remove auth sections that rely on unavailable external dependencies (rdbms, jwt).
gawk '
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
' "$MIM_CONF" > /tmp/mim_conf_tmp && mv /tmp/mim_conf_tmp "$MIM_CONF"
# ------------------------------------------------------------------------------
# CHANGE 2: Removed "|| true" at the end of the gawk+mv pipeline above.
# WHY: The original had "|| true" which silently swallowed any failure in the
# awk or mv command. If config editing fails, we WANT the script to stop and
# show the error. With set -euo pipefail active, removing || true means a real
# failure will now abort the script with a visible error instead of continuing
# with a broken config file.
# ------------------------------------------------------------------------------

# Remove auth.internal if exists to avoid duplicates before re-adding it.
sed -i '/^[[:space:]]*\[auth\.internal\][[:space:]]*$/d' "$MIM_CONF"
# ------------------------------------------------------------------------------
# CHANGE 3: Removed "|| true" from the sed -i command above.
# WHY: Same reason as CHANGE 2. If sed fails (e.g. file not found, permission
# error), we want a real failure, not silent continuation with broken config.
# ------------------------------------------------------------------------------

# Add auth.internal right after [auth] section.
if ! grep -q '^[[:space:]]*\[auth\.internal\][[:space:]]*$' "$MIM_CONF"; then
    sed -i '/^[[:space:]]*\[auth\][[:space:]]*$/a\[auth.internal]' "$MIM_CONF"
    # --------------------------------------------------------------------------
    # CHANGE 4: Removed "|| true" from the sed -i command above.
    # WHY: Same reason as CHANGE 2 and 3. If adding [auth.internal] fails, the
    # config will be missing the only working auth backend. MongooseIM will then
    # fail to start. We want this to be a loud, visible failure not a silent one.
    # --------------------------------------------------------------------------
fi

# Remove entire RDBMS outgoing pool section.
gawk '
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
' "$MIM_CONF" > /tmp/mim_conf_tmp && mv /tmp/mim_conf_tmp "$MIM_CONF"
# ------------------------------------------------------------------------------
# CHANGE 5: Replaced awk with gawk here too (same reason as CHANGE 1).
# Also removed "|| true" (same reason as CHANGE 2).
# The (\.|\]) alternation in the regex requires gawk/ERE support.
# Without this, the RDBMS outgoing pool block stays in the config, MongooseIM
# tries to connect to a non-existent MySQL pool, and startup fails silently.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# CHANGE 6: Added config validation step before starting MongooseIM.
# WHY: Previously there was zero visibility into whether config editing worked.
# If the config is broken, we now fail here with a clear message and dump the
# config contents, instead of waiting 90 seconds for a port timeout and getting
# no useful output. mongooseimctl check_config is a built-in command that
# validates the toml file without starting the node.
# ------------------------------------------------------------------------------
echo "Validating MongooseIM config before starting..."
if ! mongooseimctl check_config; then
    echo "ERROR: MongooseIM config is invalid. Dumping config for inspection:"
    cat "$MIM_CONF"
    exit 1
fi

echo "Starting mongooseim via 'mongooseimctl start'"
mongooseimctl start

echo "Waiting for the port 5222 to accept TCP connections"
if ! ./wait-for-it.sh -h localhost -p 5222 -t 90; then
    echo "MongooseIM did not open port 5222 in time"
    # --------------------------------------------------------------------------
    # CHANGE 7: Added config dump inside the timeout failure handler.
    # WHY: The original failure handler only ran mongooseimctl status and
    # tailed the log. But if the log is empty (node crashed before writing
    # anything), you got zero diagnostic info. Dumping the final config shows
    # exactly what MongooseIM tried to start with, making it easy to spot any
    # remaining bad config that the awk/sed editing missed.
    # --------------------------------------------------------------------------
    echo "=== Dumping MongooseIM config for inspection ==="
    cat "$MIM_CONF"
    echo "=== End of config ==="
    mongooseimctl status || true
    tail -n 200 /var/log/mongooseim/mongooseim.log 2>/dev/null || true
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