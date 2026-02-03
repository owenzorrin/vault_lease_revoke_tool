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

# Initialize grand total
grand_total=0

# Get all top-level mounts
while read -r mount; do
    mount_clean="${mount%/}"
    echo "Mount: ${mount_clean}"

    # Initialize mount total
    mount_total=0

    # Navigate through creds if it exists
    if vault list "sys/leases/lookup/${mount}creds" &>/dev/null; then
        # List all roles under creds
        while read -r role; do
            role_clean="${role%/}"
            count=$(vault list "sys/leases/lookup/${mount}creds/${role}" 2>/dev/null | wc -l)
            actual_count=$((count - 2))
            echo "  ├─ ${role_clean}: ${actual_count} leases"
            mount_total=$((mount_total + actual_count))
        done < <(vault list -format=json "sys/leases/lookup/${mount}creds/" 2>/dev/null | jq -r '.[]')

        echo "  └─ Total for ${mount_clean}: ${mount_total} leases"
    else
        echo "  └─ No creds found"
    fi

    echo ""
    grand_total=$((grand_total + mount_total))
done < <(vault list -format=json sys/leases/lookup | jq -r '.[]')

# Total count across all mounts
echo "=== Grand Total ==="
total=$(vault list -format=json sys/leases/lookup 2>/dev/null | jq -r '.[]' | while read -r mount; do
    if vault list "sys/leases/lookup/${mount}creds" &>/dev/null; then
        vault list -format=json "sys/leases/lookup/${mount}creds/" 2>/dev/null | jq -r '.[]' | while read -r role; do
            count=$(vault list "sys/leases/lookup/${mount}creds/${role}" 2>/dev/null | wc -l)
            echo $((count - 2))
        done
    fi
done | awk '{sum+=$1} END {print sum}')

echo "Total: ${total} leases"
