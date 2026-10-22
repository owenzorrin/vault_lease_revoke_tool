#!/bin/bash

# Check prerequisites
if ! command -v vault &> /dev/null; then
    echo "ERROR: Vault CLI is not installed or not in PATH" >&2
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is not installed or not in PATH" >&2
    exit 1
fi

if [ -z "$VAULT_ADDR" ]; then
    echo "ERROR: VAULT_ADDR is not set. Export it with: export VAULT_ADDR='https://your-vault-server:8200'" >&2
    exit 1
fi

if [ -z "$VAULT_TOKEN" ]; then
    echo "ERROR: VAULT_TOKEN is not set. Export it with: export VAULT_TOKEN='your-token'" >&2
    exit 1
fi

# vault_list_keys <path>
# Prints the keys under <path>, one per line.
#   - "No value found" (nothing there) is NOT an error: prints nothing, returns 0.
#   - Any other failure (permission denied, connection error, ...) is reported
#     on stderr and returns 1, so the report never silently under-counts.
vault_list_keys() {
    local path="$1" out err_file err rc
    err_file=$(mktemp)
    out=$(vault list -format=json "$path" 2>"$err_file")
    rc=$?
    err=$(cat "$err_file")
    rm -f "$err_file"

    if [ $rc -eq 0 ]; then
        echo "$out" | jq -r '.[]'
        return 0
    fi
    if [[ "$err" == *"No value found"* ]]; then
        return 0
    fi
    echo "ERROR: 'vault list ${path}' failed: ${err}" >&2
    return 1
}

# count_keys <path>
# Prints the number of keys under <path> (0 if there are none).
count_keys() {
    local keys
    keys=$(vault_list_keys "$1") || return 1
    if [ -z "$keys" ]; then
        echo 0
    else
        printf '%s\n' "$keys" | wc -l | tr -d ' '
    fi
}

echo "=== Vault Lease Report ==="
echo "Time: $(date)"
echo "Scope: leases under <mount>/creds/<role> and auth/<method>/login (other lease paths are not counted)"
echo ""

TOTAL=0

# Get all top-level mounts
mounts=$(vault_list_keys "sys/leases/lookup") || exit 1

while IFS= read -r mount; do
    [ -z "$mount" ] && continue
    mount_clean="${mount%/}"
    echo "Mount: ${mount_clean}"

    # Check if this is an auth mount
    if [[ "$mount" == auth/* ]]; then
        # For auth mounts, we need to go deeper: auth/ -> auth/approle/ -> auth/approle/login
        # First, list what's under auth/
        auth_methods=$(vault_list_keys "sys/leases/lookup/${mount}") || exit 1

        while IFS= read -r auth_method; do
            [ -z "$auth_method" ] && continue
            auth_method_clean="${auth_method%/}"

            # Count the leases under login for this auth method
            count=$(count_keys "sys/leases/lookup/${mount}${auth_method}login") || exit 1
            echo "  └─ ${auth_method_clean}/login: ${count} leases"
            TOTAL=$((TOTAL + count))
        done <<< "$auth_methods"
    else
        # For secret engine mounts, look for "creds" path
        roles=$(vault_list_keys "sys/leases/lookup/${mount}creds/") || exit 1

        if [ -z "$roles" ]; then
            echo "  └─ No creds found"
        else
            while IFS= read -r role; do
                [ -z "$role" ] && continue
                role_clean="${role%/}"
                count=$(count_keys "sys/leases/lookup/${mount}creds/${role}") || exit 1
                echo "  └─ ${role_clean}: ${count} leases"
                TOTAL=$((TOTAL + count))
            done <<< "$roles"
        fi
    fi

    echo ""
done <<< "$mounts"

# Grand total (accumulated during the single pass above)
echo "=== Grand Total ==="
echo "Total: ${TOTAL} leases"
