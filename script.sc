#!/bin/bash

# Script to revoke all irrevocable leases in HashiCorp Vault
# This script follows the process outlined in the Vault documentation

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if vault CLI is installed
if ! command -v vault &> /dev/null; then
    print_error "Vault CLI is not installed or not in PATH"
    exit 1
fi

# Check required environment variables
if [ -z "$VAULT_ADDR" ]; then
    print_error "VAULT_ADDR is not set. Export it with: export VAULT_ADDR='https://your-vault-server:8200'"
    exit 1
fi

if [ -z "$VAULT_TOKEN" ]; then
    print_error "VAULT_TOKEN is not set. Export it with: export VAULT_TOKEN='your-token'"
    exit 1
fi

# Check if vault is accessible
if ! vault status &> /dev/null; then
    print_error "Cannot connect to Vault. Please check your VAULT_ADDR and authentication"
    exit 1
fi

print_info "Starting irrevocable lease cleanup process..."
echo ""

# Step 1: Check initial count of irrevocable leases
print_info "Step 1: Checking total number of irrevocable leases..."
INITIAL_COUNT=$(vault read -format=json sys/leases/count type=irrevocable | jq -r '.data.lease_count // 0')
print_info "Found ${INITIAL_COUNT} irrevocable lease(s)"
echo ""

if [ "$INITIAL_COUNT" -eq 0 ]; then
    print_info "No irrevocable leases found. Exiting."
    exit 0
fi

# Step 2: List all irrevocable leases
print_info "Step 2: Retrieving all irrevocable leases..."
LEASES_JSON=$(vault read -format=json sys/leases type=irrevocable limit=none)

# Extract lease IDs
LEASE_IDS=$(echo "$LEASES_JSON" | jq -r '.data.leases[]?.lease_id // empty')

if [ -z "$LEASE_IDS" ]; then
    print_warning "No lease IDs found in the response"
    exit 0
fi

# Count leases
LEASE_COUNT=$(echo "$LEASE_IDS" | wc -l | tr -d ' ')
print_info "Found ${LEASE_COUNT} lease(s) to revoke"
echo ""

# Display first few leases as preview
print_info "Preview of irrevocable leases (first 5):"
echo "$LEASE_IDS" | head -5 | while read -r lease; do
    echo "  - $lease"
done
if [ "$LEASE_COUNT" -gt 5 ]; then
    echo "  ... and $((LEASE_COUNT - 5)) more"
fi
echo ""

# Critical warning about resource usage
echo "========================================="
print_warning "⚠️  IMPORTANT WARNING ⚠️"
echo "========================================="
echo "Force revoking irrevocable leases can:"
echo "  • Consume significant server resources"
echo "  • Impact Vault performance during execution"
echo "  • Cause Vault to become out of sync with secret engines"
echo ""
echo "Use this operation with caution, especially in production environments!"
echo "Consider running during maintenance windows for large numbers of leases."
echo "========================================="
echo ""

# Interactive menu
echo "What would you like to do?"
echo "1) Revoke ALL ${LEASE_COUNT} irrevocable leases"
echo "2) Revoke a specific number of leases"
echo "3) Display detailed lease information and exit"
echo "4) Cancel and exit"
echo ""
read -p "Enter your choice (1-4): " CHOICE

case $CHOICE in
    1)
        LEASES_TO_REVOKE="$LEASE_IDS"
        TO_REVOKE_COUNT=$LEASE_COUNT
        print_warning "You chose to revoke ALL ${LEASE_COUNT} leases"
        ;;
    2)
        read -p "Enter number of leases to revoke (1-${LEASE_COUNT}): " NUM_TO_REVOKE
        
        # Validate input
        if ! [[ "$NUM_TO_REVOKE" =~ ^[0-9]+$ ]] || [ "$NUM_TO_REVOKE" -lt 1 ] || [ "$NUM_TO_REVOKE" -gt "$LEASE_COUNT" ]; then
            print_error "Invalid number. Please enter a number between 1 and ${LEASE_COUNT}"
            exit 1
        fi
        
        LEASES_TO_REVOKE=$(echo "$LEASE_IDS" | head -n "$NUM_TO_REVOKE")
        TO_REVOKE_COUNT=$NUM_TO_REVOKE
        print_info "Will revoke ${NUM_TO_REVOKE} lease(s)"
        ;;
    3)
        print_info "Detailed lease information:"
        echo ""
        echo "$LEASES_JSON" | jq -r '.data.leases[] | "Lease ID: \(.lease_id)\nError: \(.error)\n---"'
        echo ""
        print_info "Exiting without making changes"
        exit 0
        ;;
    4)
        print_info "Operation cancelled by user"
        exit 0
        ;;
    *)
        print_error "Invalid choice. Exiting."
        exit 1
        ;;
esac

# Final confirmation
echo ""
read -p "Are you sure you want to proceed with revoking ${TO_REVOKE_COUNT} lease(s)? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    print_info "Operation cancelled by user"
    exit 0
fi

# Ask for parallelism level
echo ""
read -p "Enter number of parallel revocations (1-50, default 10): " PARALLEL
PARALLEL=${PARALLEL:-10}
if ! [[ "$PARALLEL" =~ ^[0-9]+$ ]] || [ "$PARALLEL" -lt 1 ] || [ "$PARALLEL" -gt 50 ]; then
    print_error "Invalid number. Using default of 10."
    PARALLEL=10
fi
print_info "Will run ${PARALLEL} revocations in parallel"

# Step 3: Force revoke leases in parallel
echo ""
print_info "Step 3: Force revoking irrevocable leases (parallelism: ${PARALLEL})..."

# Create temp directory for tracking results
RESULTS_DIR=$(mktemp -d)
trap "rm -rf $RESULTS_DIR" EXIT

# Worker function for parallel revocation
revoke_lease() {
    local lease_id="$1"
    local results_dir="$2"
    local idx="$3"
    local total="$4"

    if vault lease revoke -force -prefix "$lease_id" > /dev/null 2>&1; then
        echo "OK" > "${results_dir}/result_${idx}"
        echo -e "${GREEN}[INFO]${NC} [${idx}/${total}] ✓ Revoked: ${lease_id}"
    else
        echo "FAIL" > "${results_dir}/result_${idx}"
        echo -e "${RED}[ERROR]${NC} [${idx}/${total}] ✗ Failed: ${lease_id}"
    fi
}
export -f revoke_lease
export GREEN RED NC RESULTS_DIR TO_REVOKE_COUNT

# Run revocations in parallel
IDX=0
echo "$LEASES_TO_REVOKE" | while IFS= read -r LEASE_ID; do
    if [ -n "$LEASE_ID" ]; then
        ((IDX++))
        echo "${LEASE_ID} ${RESULTS_DIR} ${IDX} ${TO_REVOKE_COUNT}"
    fi
done | xargs -P "$PARALLEL" -L 1 bash -c 'revoke_lease "$1" "$2" "$3" "$4"' _

# Count results
REVOKED=$(grep -rl "OK" "$RESULTS_DIR" 2>/dev/null | wc -l | tr -d ' ')
FAILED=$(grep -rl "FAIL" "$RESULTS_DIR" 2>/dev/null | wc -l | tr -d ' ')

# Step 4: Verify final count
print_info "Step 4: Verifying irrevocable lease count..."
FINAL_COUNT=$(vault read -format=json sys/leases/count type=irrevocable | jq -r '.data.lease_count // 0')
print_info "Remaining irrevocable leases: ${FINAL_COUNT}"
echo ""

# Summary
echo "========================================="
echo "Summary:"
echo "========================================="
echo "Initial irrevocable leases: ${INITIAL_COUNT}"
echo "Leases revoked: ${REVOKED}"
echo "Leases failed: ${FAILED}"
echo "Final irrevocable leases: ${FINAL_COUNT}"
echo "========================================="

if [ "$FINAL_COUNT" -eq 0 ]; then
    print_info "All irrevocable leases have been successfully removed!"
    exit 0
else
    print_warning "Some irrevocable leases remain. You may need to:"
    echo "  1. Check the error messages above"
    echo "  2. Investigate backend connectivity issues"
    echo "  3. Consider using remove_irrevocable_lease_after parameter"
    exit 1
fi
