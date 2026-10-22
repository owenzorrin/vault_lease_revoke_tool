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

### `revoke_irrevocable_leases.sh` — Irrevocable Lease Revocation

An interactive script that walks through the full lifecycle of irrevocable lease cleanup:

0. **Target banner** — Shows the Vault address, cluster name, version, namespace, and the token's name/policies before anything else, so you can confirm you are pointed at the right environment
1. **Count** — Queries `sys/leases/count` to get the total number of irrevocable leases
2. **List** — Retrieves all irrevocable leases via `sys/leases` with full details, and saves them to a **snapshot CSV** before anything is changed
3. **Preview** — Displays the first 5 lease IDs so you can verify before taking action
4. **Interactive menu** with four options:
   - Revoke **all** irrevocable leases
   - Revoke a **specific number** of leases
   - **Display** detailed lease information (lease ID + error reason) and exit
   - **Cancel** and exit without changes
5. **Force revoke** — Uses `vault lease revoke -force -prefix` on each selected lease. The confirmation prompt repeats the Vault address and cluster name. Any error returned by Vault is shown on screen and saved
6. **Verify** — Re-checks the irrevocable lease count after revocation
7. **Summary** — Reports initial count, selected, revoked, failed, and remaining leases, plus the paths of the audit files

The script includes input validation, a confirmation prompt before destructive operations, and colored terminal output for readability.

**Exit codes:** `0` if every selected lease was revoked (even if other, unselected irrevocable leases remain); `1` if any revocation failed or the run could not start.

#### Audit files

Each run that reaches the revocation menu writes two CSV files to `./lease_audit/` (override with `AUDIT_DIR=/path`). The files are created with owner-only permissions (`umask 077`) and `lease_audit/` is listed in `.gitignore`.

| File | Written | Columns |
|---|---|---|
| `irrevocable_leases_<UTC timestamp>.csv` | Before any revocation | `lease_id,error` |
| `revoke_results_<UTC timestamp>.csv` | After revocation | `timestamp,lease_id,result,message` (`result` is `OK` or `FAIL`; `message` holds Vault's error text for failures) |

### `count_leases_v2.sh` — Lease Count Report

Generates a structured report of active leases across Vault mounts:

- Iterates through all top-level mounts via `sys/leases/lookup`
- For each secret engine mount, lists roles under the `creds/` path and counts leases per role
- For each `auth/<method>`, counts leases under `login`
- Outputs a grand total across all counted paths, collected in a single pass

**Scope:** only `<mount>/creds/<role>` and `auth/<method>/login` are counted. Leases under other paths (for example `aws/sts/...`) are not included, and the report prints this scope at the top.

**Errors are not hidden.** An empty path counts as `0`. Any other failure (for example `permission denied` or a connection error) is printed to stderr and the script exits with status `1`, so a partial report is never mistaken for a complete one.

Example output:

```
=== Vault Lease Report ===
Time: Mon Feb  3 10:00:00 UTC 2026
Scope: leases under <mount>/creds/<role> and auth/<method>/login (other lease paths are not counted)

Mount: database
  └─ readonly: 12 leases
  └─ readwrite: 3 leases

Mount: aws
  └─ deploy-role: 7 leases

Mount: auth
  └─ approle/login: 4 leases

=== Grand Total ===
Total: 26 leases
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
  - `sys/leases/revoke` (update) — for `revoke_irrevocable_leases.sh` only

## Usage

```bash
# Clone the repository
git clone https://github.com/owenzorrin/vault_lease_revoke_tool.git
cd vault_lease_revoke_tool

# Make scripts executable (if needed)
chmod +x revoke_irrevocable_leases.sh count_leases_v2.sh

# Set required environment variables
export VAULT_ADDR='https://vault.example.com:8200'
export VAULT_TOKEN='hvs.your-token-here'

# Generate a lease count report
./count_leases_v2.sh

# Interactively revoke irrevocable leases
./revoke_irrevocable_leases.sh
```

## Important Considerations

- **Performance impact**: Force-revoking leases consumes server resources. For large numbers of leases, run during a maintenance window.
- **Vault sync**: Force revocation bypasses the normal revocation flow. Vault may become out of sync with the underlying secret engine (e.g., database credentials may still exist even after the lease is removed from Vault).
- **Alternative approach**: For non-urgent cleanup, consider setting the `remove_irrevocable_lease_after` parameter on your secret engine mounts to let Vault clean up irrevocable leases automatically after a set duration.
