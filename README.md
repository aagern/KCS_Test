# KCS 2.4 Kubernetes Pre-Installation Checker

`kcs_k8s_check.sh` verifies that a Kubernetes cluster meets all prerequisites for installing **Kaspersky Container Security 2.4** before you run `helm install`. Temporary resources created during the check (a test PVC, a registry-probe pod, and per-node eBPF-check pods — all in namespace `default`) are deleted automatically on exit.

## Requirements

| Tool | Purpose |
|---|---|
| `bash` ≥ 4.0 | Script runtime |
| `kubectl` | Cluster access |
| `grep`, `sed`, `awk` | JSON parsing (POSIX, present on all systems) |
| `dig` or `nslookup` | DNS check (check F only, optional) |

A valid kubeconfig must be reachable — either via `KUBECONFIG`, `--kubeconfig`, or the default `~/.kube/config`.

## Quick start

```bash
# Interactive — the script prompts for namespace, StorageClass, domain, and IngressClass
chmod +x kcs_k8s_check.sh
./kcs_k8s_check.sh
```

Use a specific kubeconfig:

```bash
KUBECONFIG=/path/to/kubeconfig.yaml ./kcs_k8s_check.sh
# or
kubectl config use-context my-cluster && ./kcs_k8s_check.sh
```

Check an external PostgreSQL server (Check J):

```bash
./kcs_k8s_check.sh \
  --external-db 10.160.6.210 \
  --external-db-user kcs_checker \
  --external-db-password 'MySecurePass'
```

Check an external HashiCorp Vault server (Check K):

```bash
./kcs_k8s_check.sh \
  --vault 10.160.6.210 \
  --vault-account /path/to/vault-account.key
```

Both optional checks can be combined:

```bash
./kcs_k8s_check.sh \
  --external-db 10.160.6.210 \
  --external-db-user kcs_checker \
  --external-db-password 'MySecurePass' \
  --vault 10.160.6.210 \
  --vault-account /path/to/vault-account.key
```

## Environment variables

All parameters can be set as environment variables to run non-interactively (useful for CI/CD pipelines).

| Variable | Default | Description |
|---|---|---|
| `TARGET_NAMESPACE` | `kcs` | Namespace where KCS will be installed |
| `STORAGE_CLASS` | *(cluster default)* | StorageClass to test for PVC binding |
| `DOMAIN` | *(empty — skips DNS check)* | KCS domain to verify DNS resolution for |
| `INGRESS_CLASS` | *(empty — accepts any)* | Expected IngressClass name |
| `REGISTRY_TEST_IMAGE` | `curlimages/curl:latest` | Image used to probe the KCS registry |
| `SKIP_DNS_CHECK` | *(unset)* | Set to `1` to skip check F (DNS) |
| `SKIP_REGISTRY_CHECK` | *(unset)* | Set to `1` to skip check G (registry) |
| `EXTERNAL_DB_HOST` | *(empty — skips check J)* | External PostgreSQL hostname or IP |
| `EXTERNAL_DB_USER` | `postgres` | PostgreSQL user for the connectivity test |
| `EXTERNAL_DB_PASSWORD` | *(empty)* | Password for the PostgreSQL user |
| `EXTERNAL_DB_PORT` | `5432` | PostgreSQL port |
| `VAULT_HOST` | *(empty — skips check K)* | HashiCorp Vault hostname or IP |
| `VAULT_ACCOUNT_FILE` | *(empty)* | Path to the vault credentials key file |
| `VAULT_CHECK_TIMEOUT` | `60` | Seconds to wait for the Vault check pod to complete |

### Non-interactive example

```bash
TARGET_NAMESPACE=kcs \
STORAGE_CLASS=longhorn \
DOMAIN=kcs.example.com \
INGRESS_CLASS=nginx \
./kcs_k8s_check.sh
```

### CI/CD example (skip slow network checks)

```bash
TARGET_NAMESPACE=kcs \
STORAGE_CLASS=longhorn \
SKIP_DNS_CHECK=1 \
SKIP_REGISTRY_CHECK=1 \
./kcs_k8s_check.sh
```

### Air-gapped cluster (custom registry probe image)

```bash
TARGET_NAMESPACE=kcs \
REGISTRY_TEST_IMAGE=alpine \
./kcs_k8s_check.sh
```

## Checks performed

| ID | Check | Threshold / Requirement |
|---|---|---|
| A | Kubernetes server version | ≥ 1.21, all nodes `amd64` |
| B | Allocatable CPU across all nodes | ≥ 10 cores |
| C | Allocatable memory across all nodes | ≥ 20 GiB |
| D | StorageClass exists + test PVC binds + ephemeral storage | SC present, PVC `Bound` within 30 s, ≥ 28 GiB ephemeral |
| E | Ingress controller | At least one `IngressClass` resource exists |
| F | DNS resolution for `DOMAIN` | Domain resolves; warns (not fails) if not yet configured |
| G | Registry reachability (`repo.kcs.kaspersky.com`) | HTTP 2xx/3xx/401/403 from inside the cluster |
| H | OS distribution and kernel version | Kernel ≥ 4.18 on every node (FAIL if below); kernel < 5.8 triggers a WARN (kcs-ih must run in privileged mode) |
| I | eBPF capabilities — BTF support | `/sys/kernel/btf/vmlinux` must exist on every node (`CONFIG_DEBUG_INFO_BTF=y`), required for eBPF CO-RE used by KCS agents |
| J | External PostgreSQL database | Runs a `postgres:15-alpine` pod inside the cluster and performs `pg_isready` + `psql -c "SELECT 1"` against the supplied host — verifies both network path and authentication |
| K | HashiCorp Vault | Runs a `curlimages/curl` pod inside the cluster and checks Vault health (HTTP status) then authenticates with the supplied token — verifies both network reachability and token validity |

Checks F and G are skipped when `DOMAIN` is empty or `SKIP_*` flags are set. Check J is skipped when `--external-db` is not provided. Check K is skipped when `--vault` is not provided.

### Notes on checks H and I

**Check H — kernel version** reads `nodeInfo.kernelVersion` directly from the Kubernetes API — no SSH required. Two thresholds apply:

- **< 4.18** → **FAIL** — KCS agents cannot run at all.
- **≥ 4.18 and < 5.8** → **WARN** — KCS works but the `kcs-ih` component must be configured with `privileged: true`.
- **≥ 5.8** → **PASS** — full support, no extra configuration needed.

**Check I — eBPF BTF** deploys a short-lived privileged `busybox` pod on each node (via `nodeName` scheduling) that checks whether `/sys/kernel/btf/vmlinux` exists on the host. This file is present when the kernel was compiled with `CONFIG_DEBUG_INFO_BTF=y`, which is required for the eBPF CO-RE technology used by KCS node agents. The pod is deleted immediately after the check regardless of outcome.

Most modern distributions (Ubuntu 20.04+, RHEL 9, Debian 11+, Astra Linux SE 1.7) ship kernels with BTF enabled by default. If BTF is absent, KCS will attempt a fallback compatibility mode, but full runtime monitoring functionality may be limited.

### Notes on check J

**Check J — External PostgreSQL** is only relevant when KCS is deployed with an external database instead of the embedded one. When `--external-db` is provided (or `EXTERNAL_DB_HOST` is set), the check:

1. Schedules a short-lived `postgres:15-alpine` pod in namespace `default`.
2. Runs `pg_isready` to verify the PostgreSQL port is reachable from within the cluster network.
3. Runs `psql -c "SELECT 1"` to verify the supplied user and password are accepted.
4. Deletes the pod immediately after the check.

The check tests the network path **from inside the cluster** to the external database, which is the path KCS itself will use at runtime. It does **not** require any special Kubernetes permissions beyond the ability to schedule pods in `default`.

**Prerequisites for the external PostgreSQL server:**

- Listen on an IP reachable from the pod network (set `listen_addresses = '*'` or the node IP in `postgresql.conf`).
- Allow connections from the pod CIDR in `pg_hba.conf`, e.g.:
  ```
  host  all  kcs_checker  10.244.0.0/16  md5
  ```
- The supplied user needs at least `LOGIN` privilege and `CONNECT` on the target database.

**Passwords with YAML-special characters** (`"`, `\`, `{`, `}`) are not currently escaped in the pod YAML — use a password that does not contain these characters, or set `EXTERNAL_DB_PASSWORD` via environment variable rather than `--external-db-password`.

### Notes on check K

**Check K — HashiCorp Vault** is only relevant when KCS is deployed with external secret storage. When `--vault` is provided, the check:

1. Reads Vault credentials from the `--vault-account` key file (see format below).
2. Schedules a short-lived `curlimages/curl` pod in namespace `default`.
3. Performs an HTTP health check against `<vault-addr>/v1/sys/health` to verify reachability and sealed state (HTTP 503 = sealed).
4. Authenticates with the token using `GET /v1/auth/token/lookup-self` (HTTP 200 = valid token).
5. Deletes the pod immediately after the check.

The check tests the network path **from inside the cluster** to the external Vault server, which is the path KCS itself will use at runtime.

**Possible outcomes:**

| Result | Meaning |
|---|---|
| `VAULT_OK` | Vault is reachable, unsealed, and the token is valid |
| `VAULT_UNREACHABLE` | Pod cannot reach Vault — check firewall / network policy |
| `VAULT_SEALED` | Vault responded but is sealed — unseal before installing KCS |
| `VAULT_AUTH_FAIL` | Vault is reachable but the token is invalid or expired |
| *(timeout / warn)* | Pod did not complete within `VAULT_CHECK_TIMEOUT` seconds |

#### Vault account key file format

The `--vault-account` argument points to a plain-text file with two fields:

```ini
# vault-account.key
VAULT_ADDR=http://10.160.6.210:8200
VAULT_TOKEN=s.your-vault-token-here
```

- **`VAULT_ADDR`** — full URL of the Vault server, reachable from within the pod network. If omitted, the script constructs `http://<--vault arg>:8200`.
- **`VAULT_TOKEN`** — a Vault token with at least `lookup-self` capability. In production, create a short-lived token scoped to KCS paths:

  ```bash
  vault token create -policy=kcs-readonly -ttl=1h
  ```

Generate a key file automatically:

```bash
bash generate-vault-account.sh http://10.160.6.210:8200 s.your-token
# writes: vault-account.key  (chmod 600)
```

An annotated example is provided in `vault-account-example.key`.

**Prerequisites for the Vault server:**

- Vault must be initialized and unsealed.
- The server address must be reachable from within the cluster pod network (not only from the node itself).
- The token must have at minimum the `lookup-self` capability (`auth/token/lookup-self` endpoint).

## Output

**Console** — colour-coded pass/fail/warn per check, summary table at the end.

**Report file** — Markdown file written to the current directory:

```
kcs-precheck-YYYYMMDD-HHMMSS.md
```

The report contains the measured value, threshold, status, and raw `kubectl` output for each check, plus a recommendations section for any failures.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | All checks passed (or only warnings) |
| `1` | At least one check failed — cluster is not ready |
| `2` | `kubectl` cannot reach the cluster |

## Running the tests

```bash
bash kcs_k8s_check_test.sh --kubeconfig=/path/to/kubeconfig.yaml
```

The test suite runs unit tests (normalization helpers, kernel version parsing, mock-kubectl pass/fail cases, python3-absence check, external-DB and Vault checks) and integration tests against a real cluster. All 63 unit tests must pass; integration tests require `--kubeconfig=` and optionally `--external-db=` / `--vault=`.

```bash
# Unit tests only
bash kcs_k8s_check_test.sh

# Full integration including external PostgreSQL and Vault
bash kcs_k8s_check_test.sh \
  --kubeconfig=/path/to/kubeconfig.yaml \
  --external-db=10.160.6.210 \
  --external-db-user=kcs_checker \
  --external-db-password='MyPass' \
  --vault=10.160.6.210 \
  --vault-account=/path/to/vault-account.key
```
