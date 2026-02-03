# Vault Lease Revoke Tool

A high-performance, parallelized CLI tool for managing, reporting on, and force-revoking irrevocable leases in [HashiCorp Vault](https://developer.hashicorp.com/vault).

## Background 
When Vault cannot successfully revoke a lease, it marks the lease as irrevocable. These leases remain in Vault's storage and can:

Consume storage and memory resources
- Cause confusion when auditing active credentials
- Indicate underlying issues with secret engine backends
- This toolset helps operators identify, inspect, and clean up irrevocable leases, as well as generate reports on active leases across all mounts.

## Features

- **Native Parallelism**: Processes revocations concurrently using Go routines and semaphores.
- **No Dependencies**: Does not require jq, awk, or even the vault CLI installed on the host.
- **Smart Reporting**: Hierarchical view of leases across all mounts and roles.
- **Safe by Default**: Includes confirmation prompts and adjustable concurrency limits.

## Installation

### From Source 
Ensure you have Go 1.21+ installed: 
```
go build -o vlrt main.go
```

### Cross-Compiling 
If you are building on a Mac (Darwin) to run the tool on a Linux environment: 

#### For Linux Intel/AMD 

```
GOOS=linux GOARCH=amd64 go build -o vlrt-linux main.go
```

#### For Linux ARM (like AWS Graviton) 
```
GOOS=linux GOARCH=arm64 go build -o vlrt main.go
```

### Docker & Kubernetes
The repository includes a `Dockerfile` for multi-stage builds.

#### Building the Image
```bash
docker build -t username/vlrt:latest .
```
**Note**: When running in Kubernetes or via CronJob, ensure you use the `-f` (force) flag to bypass interactive prompts.

## Usage

The tool utilizes standard Vault environment variables for authentication: 
```
export VAULT_ADDR='https://your-vault-url:8200'
export VAULT_TOKEN='your-privileged-token'
```

### 1. Generate Lease Report 
Generates a summary of all active leases across mounts and roles. 

```
./vlrt --report
```

### 2. Irrevocable Lease Cleanup
Identifies and force-revokes leases stuck in the "irrevocable" state. 
```
./vlrt --clean
```

## Flags & Configuration

| Flag | Default | Description |
| :--- | :--- | :--- |
| `--report` | `false` | Triggers the hierarchical lease count report. |
| `--clean` | `false` | Triggers the irrevocable lease cleanup logic. |
| `-n` | `0` | **Limit:** Number of leases to process. `0` processes all found leases. |
| `-p` | `10` | **Parallelism:** Number of concurrent API requests. (Recommended range: 1-50). |
| `-f` | `false` | **Force:** Skips the interactive `y/n` confirmation for automation. |

---

## Examples

Standard Interactive Cleanup: Uses the default parallelism of 10 and prompts for confirmation. 
```
./vlrt --clean
```

Automated Batch Cleanup (High Performance): Process the first 1000 leases with 30 concurrent workers without a prompt. 
```
./vlrt --clean -n 1000 -p 30 -f
```

## Performance & Safety

**Concurrency**: The default parallelism of 10 is designed to be safe for most production Vault clusters. Increasing this significantly may cause high CPU usage or rate-limiting.

**Force Revocation**: This tool targets the `sys/leases/revoke-force` endpoint. This removes the lease from Vault's state but may leave orphaned credentials on the target secret engine (e.g., a database user) if that backend is unreachable.
