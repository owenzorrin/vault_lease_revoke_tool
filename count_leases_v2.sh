#!/bin/bash

# Check prerequisites
if ! command -v vault &> /dev/null; then
    echo "ERROR: Vault CLI is not installed or not in PATH"
    exit 1
fi

if [ -z "$VAULT_ADDR" ]; then
    echo "ERROR: VAULT_ADDR is not set. Export it with: export VAULT_ADDR='https://your-vault-server:8200'"
    exit 1
fi

if [ -z "$VAULT_TOKEN" ]; then
    echo "ERROR: VAULT_TOKEN is not set. Export it with: export VAULT_TOKEN='your-token'"
    exit 1
fi

echo "=== Vault Lease Report ==="
echo "Time: $(date)"
echo ""

# Get all top-level mounts
vault list -format=json sys/leases/lookup 2>/dev/null | jq -r '.[]' | while read -r mount; do
    mount_clean="${mount%/}"
    echo "Mount: ${mount_clean}"
    
    # Check if this is an auth mount
    if [[ "$mount" == auth/* ]]; then
        # For auth mounts, we need to go deeper: auth/ -> auth/approle/ -> auth/approle/login
        # First, list what's under auth/
        vault list -format=json "sys/leases/lookup/${mount}" 2>/dev/null | jq -r '.[]' | while read -r auth_method; do
            auth_method_clean="${auth_method%/}"
            
            # Now check for login under this auth method
            if vault list "sys/leases/lookup/${mount}${auth_method}login" &>/dev/null; then
                count=$(vault list "sys/leases/lookup/${mount}${auth_method}login" 2>/dev/null | wc -l)
                actual_count=$((count - 2))
                echo "  └─ ${auth_method_clean}/login: ${actual_count} leases"
            fi
        done
    else
        # For secret engine mounts, look for "creds" path
        if vault list "sys/leases/lookup/${mount}creds" &>/dev/null; then
            vault list -format=json "sys/leases/lookup/${mount}creds/" 2>/dev/null | jq -r '.[]' | while read -r role; do
                role_clean="${role%/}"
                count=$(vault list "sys/leases/lookup/${mount}creds/${role}" 2>/dev/null | wc -l)
                actual_count=$((count - 2))
                echo "  └─ ${role_clean}: ${actual_count} leases"
            done
        else
            echo "  └─ No creds found"
        fi
    fi
    
    echo ""
done

# Grand total
echo "=== Grand Total ==="
total=$(vault list -format=json sys/leases/lookup 2>/dev/null | jq -r '.[]' | while read -r mount; do
    if [[ "$mount" == auth/* ]]; then
        # Handle auth mounts - go deeper into auth methods
        vault list -format=json "sys/leases/lookup/${mount}" 2>/dev/null | jq -r '.[]' | while read -r auth_method; do
            if vault list "sys/leases/lookup/${mount}${auth_method}login" &>/dev/null; then
                count=$(vault list "sys/leases/lookup/${mount}${auth_method}login" 2>/dev/null | wc -l)
                echo $((count - 2))
            fi
        done
    else
        # Handle secret engine mounts
        if vault list "sys/leases/lookup/${mount}creds" &>/dev/null; then
            vault list -format=json "sys/leases/lookup/${mount}creds/" 2>/dev/null | jq -r '.[]' | while read -r role; do
                count=$(vault list "sys/leases/lookup/${mount}creds/${role}" 2>/dev/null | wc -l)
                echo $((count - 2))
            done
        fi
    fi
done | awk '{sum+=$1} END {print sum}')

echo "Total: ${total} leases"