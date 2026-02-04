# Vault Lease Revoke Tool & Lease Report Tool

A set of bash scripts for managing, reporting on, and force-revoking irrevocable leases in [HashiCorp Vault](https://www.vaultproject.io/). Irrevocable leases occur when Vault is unable to revoke a lease (e.g., due to backend connectivity issues or plugin errors), and they can accumulate over time if left unaddressed.

!PLEASE USE WITH CAUTION AS ONCE LEASE GOT FORCE REVOKED IT CANNOT BE RECOVERED!

## Background

When Vault cannot successfully revoke a lease, it marks the lease as **irrevocable**. These leases remain in Vault's storage and can:

- Consume storage and memory resources
- Cause confusion when auditing active credentials
- Indicate underlying issues with secret engine backends

This toolset helps operators identify, inspect, and clean up irrevocable leases, as well as generate reports on active leases across all mounts.

## Scripts

### `script.sc` — Irrevocable Lease Revocation

An interactive script that walks through the full lifecycle of irrevocable lease cleanup:

1. **Count** — Queries `sys/leases/count` to get the total number of irrevocable leases
2. **List** — Retrieves all irrevocable leases via `sys/leases` with full details
3. **Preview** — Displays the first 5 lease IDs so you can verify before taking action
4. **Interactive menu** with four options:
   - Revoke **all** irrevocable leases
   - Revoke a **specific number** of leases
   - **Display** detailed lease information (lease ID + error reason) and exit
   - **Cancel** and exit without changes
5. **Force revoke** — Uses `vault lease revoke -force -prefix` on each selected lease
6. **Verify** — Re-checks the irrevocable lease count after revocation
7. **Summary** — Reports initial count, revoked, failed, and remaining leases

The script includes input validation, a confirmation prompt before destructive operations, and colored terminal output for readability.

### `count_leases_v2.sh` — Lease Count Report

Generates a structured report of active leases across all Vault secret engine mounts:

- Iterates through all top-level mounts via `sys/leases/lookup`
- For each mount, lists roles under the `creds/` path
- Counts leases per role and totals per mount
- Outputs a grand total across all mounts

Example output:

```
=== Vault Lease Report ===
Time: Mon Feb  3 10:00:00 UTC 2026

Mount: database
  ├─ readonly: 12 leases
  ├─ readwrite: 3 leases
  └─ Total for database: 15 leases

Mount: aws
  ├─ deploy-role: 7 leases
  └─ Total for aws: 7 leases

=== Grand Total ===
Total: 22 leases
```

## Prerequisites

- [HashiCorp Vault CLI](https://developer.hashicorp.com/vault/docs/commands) installed and in `PATH`
- [jq](https://jqlang.github.io/jq/) for JSON parsing
- Required environment variables (both scripts validate these on startup):
  - `VAULT_ADDR` — set to your Vault server address (e.g., `https://vault.example.com:8200`)
  - `VAULT_TOKEN` — set to a valid Vault token (e.g., via `vault login` or `export VAULT_TOKEN='...'`)
- Sufficient permissions — these scripts require access to:
  - `sys/leases` (read, list)
  - `sys/leases/count` (read)
  - `sys/leases/lookup` (list)
  - `sys/leases/revoke` (update) — for `script.sc` only

## Usage

```bash
# Clone the repository
git clone https://github.com/owenzorrin/vault_lease_revoke_tool.git
cd vault_lease_revoke_tool

# Make scripts executable (if needed)
chmod +x script.sc count_leases_v2.sh

# Set required environment variables
export VAULT_ADDR='https://vault.example.com:8200'
export VAULT_TOKEN='hvs.your-token-here'

# Generate a lease count report
./count_leases_v2.sh

# Interactively revoke irrevocable leases
./script.sc
```

## Important Considerations

- **Performance impact**: Force-revoking leases consumes server resources. For large numbers of leases, run during a maintenance window.
- **Vault sync**: Force revocation bypasses the normal revocation flow. Vault may become out of sync with the underlying secret engine (e.g., database credentials may still exist even after the lease is removed from Vault).
- **Alternative approach**: For non-urgent cleanup, consider setting the `remove_irrevocable_lease_after` parameter on your secret engine mounts to let Vault clean up irrevocable leases automatically after a set duration.
