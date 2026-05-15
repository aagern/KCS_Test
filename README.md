# KCS 2.4 Kubernetes Pre-Installation Checker

`kcs_k8s_check.sh` verifies that a Kubernetes cluster meets all prerequisites for installing **Kaspersky Container Security 2.4** before you run `helm install`. It is fully read-only — the only temporary resources it creates (a test PVC and a registry-probe pod, both in namespace `default`) are deleted automatically on exit.

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

| ID | Check | Threshold |
|---|---|---|
| A | Kubernetes server version | ≥ 1.21, all nodes `amd64` |
| B | Allocatable CPU across all nodes | ≥ 10 cores |
| C | Allocatable memory across all nodes | ≥ 20 GiB |
| D | StorageClass exists + test PVC binds + ephemeral storage | SC present, PVC `Bound` within 30 s, ≥ 28 GiB ephemeral |
| E | Ingress controller | At least one `IngressClass` resource exists |
| F | DNS resolution for `DOMAIN` | Domain resolves; warns (not fails) if not yet configured |
| G | Registry reachability (`repo.kcs.kaspersky.com`) | HTTP 2xx/3xx/401/403 from inside the cluster |

Checks F and G are skipped when `DOMAIN` is empty or `SKIP_*` flags are set.

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

The test suite runs unit tests (normalization helpers, mock-kubectl pass/fail cases, python3-absence check) and integration tests against a real cluster. All 36 tests must pass.
