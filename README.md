# KCS 2.5.1 Kubernetes Pre-Installation Checker

`kcs_k8s_check.sh` verifies that a Kubernetes cluster meets all prerequisites for installing **Kaspersky Container Security 2.5.1** before you run `helm install`. Temporary resources created during the check (a test PVC, a registry-probe pod, and per-node eBPF-check pods — all in `PROBE_NAMESPACE`, `default` unless overridden) are deleted automatically on exit.

## How verdicts are decided

The documentation lists the versions Kaspersky covers with configuration tests, and states explicitly that absence from a list is *neither* proof of incompatibility *nor* a guarantee of support. The checker reflects that wording with three outcomes rather than two:

| Verdict | Meaning |
|---|---|
| ✅ **PASS** | The version is in the tested list for this release. |
| ⚠️ **WARN** | The version clears the documented minimum but is not in the tested list. Installation is likely to work; confirm with Technical Support. |
| ❌ **FAIL** | The version is below the documented minimum, or the component is explicitly unsupported. |

Only FAIL makes the run exit non-zero, so an untested-but-plausible cluster never blocks a pilot.

## What changed from the 2.4 checker

| Area | 2.4 | 2.5.1 |
|---|---|---|
| CPU | ≥ 10 cores, summed across **all** nodes | ≥ 13 cores on **every worker node** |
| Memory | ≥ 20 GiB, summed across **all** nodes | ≥ 20 GB on **every worker node** |
| Ephemeral storage | ≥ 28 GiB, summed, folded into the storage check | ≥ 28 GB on **every worker node**, its own check (D) |
| Version lists | Minimum only | Minimum **plus** the tested-version list, with WARN in between |
| OpenShift | 4.8, 4.11 and later | Tested 4.8 and 4.21 — 4.18 now WARNs |
| Kernels | Minimum 4.18, WARN below 5.8 | Same floors, plus WARN for any kernel outside the tested list; 6.17 added |
| Calico | Any version passed | PASS only for 3.22.5 / 3.28 / 3.29 / 3.30 / 3.31 |
| Cilium | 1.16–1.18 | Unchanged, and 1.16 is flagged for `enableTCX=false` |
| Ingress | `IngressClass` required, else FAIL | `IngressClass` **or** Gateway API with a `Gateway` object |
| PostgreSQL | Connectivity only | Connectivity plus `server_version` — floor 15, tested 15 / 17 / 18 |
| Helm | Not checked | New check O — floor 3, tested 3.21.1 / 4.1 |
| Agents | Not checked | New check P — kube-agent sizing from live pod count, node-agent headroom per node |
| Probe namespace | Hardcoded `default` | `PROBE_NAMESPACE`, so the run can exercise the real target namespace |
| Check IDs | A–M | A–P (D is new, so E onward shifted by one) |

**The per-node change is the one to read twice.** A cluster that passed the 2.4 checker can fail the 2.5.1 one without any hardware changing: three workers at 8 cores each summed to 24 and passed the old 10-core total, but none of them meets the 13 cores the documentation asks of a worker node.

## Requirements

| Tool | Purpose |
|---|---|
| `bash` ≥ 3.2 | Script runtime (tested on macOS bash 3.2 and Linux bash 5.1) |
| `kubectl` | Cluster access |
| `grep`, `sed`, `awk` | JSON parsing (POSIX, present on all systems) |
| `helm` | Optional — check O skips cleanly when it is absent |
| `dig` or `nslookup` | DNS check (check G only, optional) |

A valid kubeconfig must be reachable — either via `KUBECONFIG`, `--kubeconfig`, or the default `~/.kube/config`.

## Quick start

```bash
# Interactive — the script prompts for namespace, StorageClass, domain, and IngressClass
chmod +x kcs_k8s_check.sh
./kcs_k8s_check.sh
```

Point the probes at the namespace KCS will occupy, so its quotas and Pod Security Admission labels are exercised too:

```bash
TARGET_NAMESPACE=kcs PROBE_NAMESPACE=kcs ./kcs_k8s_check.sh
```

Use a specific kubeconfig:

```bash
KUBECONFIG=/path/to/kubeconfig.yaml ./kcs_k8s_check.sh
# or
kubectl config use-context my-cluster && ./kcs_k8s_check.sh
```

Check an external PostgreSQL server (check K):

```bash
./kcs_k8s_check.sh \
  --external-db 10.160.6.210 \
  --external-db-user kcs_checker \
  --external-db-password 'MySecurePass'
```

Check an external HashiCorp Vault server (check L):

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
| `TARGET_NAMESPACE` | `kcs` | Namespace where KCS will be installed (reported in the output) |
| `PROBE_NAMESPACE` | `default` | Namespace the temporary probe PVC and pods are created in. Point it at the namespace KCS will occupy to also exercise that namespace's `ResourceQuota`, `LimitRange`, and Pod Security Admission labels |
| `STORAGE_CLASS` | *(cluster default)* | StorageClass to test for PVC binding |
| `DOMAIN` | *(empty — skips DNS check)* | KCS domain to verify DNS resolution for |
| `INGRESS_CLASS` | *(empty — accepts any)* | Expected IngressClass name |
| `REGISTRY_TEST_IMAGE` | `curlimages/curl:latest` | Image used to probe the KCS registry |
| `SKIP_DNS_CHECK` | *(unset)* | Set to `1` to skip check G (DNS) |
| `SKIP_REGISTRY_CHECK` | *(unset)* | Set to `1` to skip check H (registry) |
| `EXTERNAL_DB_HOST` | *(empty — skips check K)* | External PostgreSQL hostname or IP |
| `EXTERNAL_DB_USER` | `postgres` | PostgreSQL user for the connectivity test |
| `EXTERNAL_DB_PASSWORD` | *(empty)* | Password for the PostgreSQL user |
| `EXTERNAL_DB_PORT` | `5432` | PostgreSQL port |
| `VAULT_HOST` | *(empty — skips check L)* | HashiCorp Vault hostname or IP |
| `VAULT_ACCOUNT_FILE` | *(empty)* | Path to the vault credentials key file |
| `VAULT_CHECK_TIMEOUT` | `60` | Seconds to wait for the Vault check pod to complete |
| `REPORT_FILE` | `kcs-precheck-<timestamp>.md` | Path of the Markdown report. Set it to `/dev/null` to suppress the report entirely |

### Non-interactive example

```bash
TARGET_NAMESPACE=kcs \
PROBE_NAMESPACE=kcs \
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

## Supported Kubernetes distributions

Check A identifies the Kubernetes distribution from `kubectl version --output=json` and applies distribution-specific version rules:

| Distribution | Detection | Minimum | Tested in 2.5.1 |
|---|---|---|---|
| Vanilla Kubernetes | No distribution suffix in server `gitVersion` | 1.21 | 1.21, 1.23, 1.28, 1.30, 1.31, 1.32, 1.33, 1.34, 1.35 |
| OpenShift | Client `gitVersion` matches OCP format (`N.N.N-timestamp.pN.`) | 4.8 | 4.8, 4.21 |
| Rancher RKE2 | Server `gitVersion` contains `+rke2r` | K8s ≥ 1.21 | Rancher 1.34, 1.35 |
| K3s | Server `gitVersion` contains `+k3s` | — | Always **FAIL** — not a supported distribution |

A version between the minimum and the tested list — K8s 1.29, for instance — produces a WARN, not a FAIL.

The documentation also lists DeckHouse 1.75.9, Platform V DropApp 4.2.1, Штурвал 2.13 and Боцман 3.3.0. The checker does not fingerprint these; they are evaluated as the vanilla Kubernetes version they embed.

OpenShift detection relies on the `oc` kubectl shim reporting the OCP client version. If a standard `kubectl` binary is used against an OpenShift cluster, the script falls back to treating it as vanilla Kubernetes.

## Checks performed

| ID | Check | Threshold / Requirement |
|---|---|---|
| A | Kubernetes version and distribution | Minimum 1.21 (OpenShift 4.8); PASS only for a tested version, WARN above the minimum but untested; K3s always fails; all nodes `amd64` |
| B | Allocatable CPU **per worker node** | ≥ 13 cores on every worker |
| C | Allocatable memory **per worker node** | ≥ 20 GB on every worker |
| D | Allocatable ephemeral storage **per worker node** | ≥ 28 GB on every worker |
| E | StorageClass exists and a test PVC binds | SC present, PVC `Bound` within 30 s (a consumer pod is created for `WaitForFirstConsumer`) |
| F | Ingress controller or Gateway API | An `IngressClass` exists, **or** the Gateway API is installed with at least one `Gateway` object (`serviceType=gatewayAPI`) |
| G | DNS resolution for `DOMAIN` | Domain resolves; warns (not fails) if not yet configured |
| H | Registry reachability (`repo.kcs.kaspersky.com`) | HTTP 2xx/3xx/401/403 from inside the cluster |
| I | OS distribution and kernel version | Kernel ≥ 4.18 on every node (FAIL below); < 5.8 WARNs (kcs-ih needs privileged mode); a kernel outside the tested list WARNs; Astra Linux nodes are flagged for `CONFIG_DEBUG_INFO_BTF=y` |
| J | eBPF capabilities — BTF support | `/sys/kernel/btf/vmlinux` must exist on every node (`CONFIG_DEBUG_INFO_BTF=y`), required for the eBPF CO-RE used by KCS agents |
| K | External PostgreSQL database | Runs a `postgres:15-alpine` pod inside the cluster, performs `pg_isready` + `psql -c "SELECT 1"`, then reads `SHOW server_version` — minimum major 15, PASS for 15/17/18, WARN for anything newer but untested |
| L | HashiCorp Vault | Runs a `curlimages/curl` pod inside the cluster, checks Vault health, then authenticates with the supplied token |
| M | Container runtime | Reads `nodeInfo.containerRuntimeVersion` for every node — `containerd` and `CRI-O` pass; `docker` fails |
| N | CNI plugin | Flannel (unconstrained); Calico PASS for 3.22.5 / 3.28 / 3.29 / 3.30 / 3.31 and WARN otherwise; Cilium FAIL outside 1.16 / 1.17 / 1.18, and 1.16 is flagged for `enableTCX=false` |
| O | Helm package manager | Helm 3 or later required; PASS for 3.21.1 / 4.1, WARN for any other Helm 3+; SKIP when `helm` is not on `PATH` |
| P | Agent resource headroom | Reports kube-agent sizing from the live pod count (1 core per 2500 pods, 2 GB per 3000 pods) and WARNs for any worker that cannot hold node-agent at its maximum footprint (3 cores / 5 GB) |

**Why B, C and D are per node.** The documentation states 13 cores, 20 GB of RAM and 28 GB of ephemeral storage for *a worker node* in a three-worker / three-`kcs-ih` cluster scanning images up to 10 GB — not as a cluster-wide total. Each worker is therefore measured on its own, and the control plane is excluded with a negated `node-role.kubernetes.io/control-plane` label selector. Cluster totals are still printed, as context for scaling conversations. On a cluster where no node lacks the control-plane role, every node is measured and the verdict is downgraded to WARN.

Checks G and H are skipped when `DOMAIN` is empty or the `SKIP_*` flags are set. Check K is skipped when `--external-db` is not provided; check L when `--vault` is not provided; check O when `helm` is absent.

### Notes on check A

**Check A — Kubernetes version and distribution** reads `kubectl version --output=json` and applies distribution-aware version rules:

- **Vanilla Kubernetes**: server `gitVersion` has no distribution suffix (e.g. `v1.31.2`). PASS when the minor is in the tested list, WARN when it is ≥ 1.21 but untested, FAIL below 1.21.
- **OpenShift**: detected when the client `gitVersion` matches the OCP release format (`N.N.N-timestamp.pN.g…`), which is present when using the `oc` kubectl shim. PASS for **4.8** and **4.21**, WARN for any other release ≥ 4.8, FAIL for 4.7 and below. Note that 4.18 was tested for KCS 2.4 but is not in the 2.5.1 list, so it now WARNs.
- **RKE2 (Rancher)**: detected when server `gitVersion` contains `+rke2r` (e.g. `v1.30.6+rke2r1`). The embedded Kubernetes version is tiered exactly as vanilla Kubernetes.
- **K3s**: detected when server `gitVersion` contains `+k3s` (e.g. `v1.34.3+k3s1`). Always **FAIL** regardless of version — K3s is not a supported distribution.

The architecture sub-check runs regardless of distribution: all nodes must report `amd64`. Non-amd64 nodes (arm64, etc.) cause a FAIL.

### Notes on checks I and J

**Check I — kernel version** reads `nodeInfo.kernelVersion` directly from the Kubernetes API — no SSH required. Four tiers apply:

- **< 4.18** → **FAIL** — KCS agents cannot run at all.
- **≥ 4.18 and < 5.8** → **WARN** — KCS works but the `kcs-ih` component must be configured with `privileged: true`, because the kernel lacks the process-privilege controls kcs-ih relies on.
- **≥ 5.8 but outside the tested list** → **WARN** — runtime profile monitoring is unverified on that kernel.
- **≥ 5.8 and in the tested list** → **PASS**.

Kernels tested for 2.5.1: **4.18, 4.19, 5.4, 5.10, 5.14, 5.15, 6.1, 6.6, 6.8, 6.12, 6.17**. A node on 6.5 — the Ubuntu 22.04.3 HWE kernel, for example — therefore WARNs. Nodes whose `osImage` names Astra Linux additionally get a note that the kernel config must contain `CONFIG_DEBUG_INFO_BTF=y`.

**Check J — eBPF BTF** deploys a short-lived privileged `busybox` pod on each node (via `nodeName` scheduling) that checks whether `/sys/kernel/btf/vmlinux` exists on the host. This file is present when the kernel was compiled with `CONFIG_DEBUG_INFO_BTF=y`, which is required for the eBPF CO-RE technology used by KCS node agents. The pod is deleted immediately after the check regardless of outcome.

Most modern distributions (Ubuntu 20.04+, RHEL 9, Debian 11+, Astra Linux SE 1.7) ship kernels with BTF enabled by default. If BTF is absent, KCS will attempt a fallback compatibility mode, but full runtime monitoring functionality may be limited.

### Notes on check K

**Check K — External PostgreSQL** is only relevant when KCS is deployed with an external database instead of the embedded one. When `--external-db` is provided (or `EXTERNAL_DB_HOST` is set), the check:

1. Schedules a short-lived `postgres:15-alpine` pod in `PROBE_NAMESPACE`.
2. Runs `pg_isready` to verify the PostgreSQL port is reachable from within the cluster network.
3. Runs `psql -c "SELECT 1"` to verify the supplied user and password are accepted.
4. Reads `SHOW server_version` and tiers it: FAIL below major 15, PASS for the tested 15 / 17 / 18, WARN for anything else above the minimum.
5. Deletes the pod immediately after the check.

The documentation also lists ClickHouse v25.\* and Pangolin 6.2.0 as supported external DBMSs. Neither is probed by this script.

The check tests the network path **from inside the cluster** to the external database, which is the path KCS itself will use at runtime. It does **not** require any special Kubernetes permissions beyond the ability to schedule pods in `PROBE_NAMESPACE`.

**Prerequisites for the external PostgreSQL server:**

- Listen on an IP reachable from the pod network (set `listen_addresses = '*'` or the node IP in `postgresql.conf`).
- Allow connections from the pod CIDR in `pg_hba.conf`, e.g.:
  ```
  host  all  kcs_checker  10.244.0.0/16  md5
  ```
- The supplied user needs at least `LOGIN` privilege and `CONNECT` on the target database.

**Passwords with YAML-special characters** (`"`, `\`, `{`, `}`) are not currently escaped in the pod YAML — use a password that does not contain these characters, or set `EXTERNAL_DB_PASSWORD` via environment variable rather than `--external-db-password`.

### Notes on check L

**Check L — HashiCorp Vault** is only relevant when KCS is deployed with external secret storage. When `--vault` is provided, the check:

1. Reads Vault credentials from the `--vault-account` key file (see format below).
2. Schedules a short-lived `curlimages/curl` pod in `PROBE_NAMESPACE`.
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

### Notes on check M

**Check M — Container runtime** reads `nodeInfo.containerRuntimeVersion` directly from the Kubernetes API for every node. No SSH or privileged access is required.

| Runtime | Result |
|---|---|
| `containerd` | ✅ PASS |
| `cri-o` | ✅ PASS |
| `docker` | ❌ FAIL |
| anything else | ⚠️ WARN |

Docker (including Docker via `dockershim` or `cri-dockerd`) is not supported — the documentation lists only `containerd` and `CRI-O`. If any node reports a Docker runtime the check fails and the cluster is considered not ready.

### Notes on check N

**Check N — CNI plugin** probes for known CNI DaemonSets using the Kubernetes API, searching all namespaces by DaemonSet name. No pods are created.

Detection order:

1. **Calico** — DaemonSet `calico-node`. PASS for the tested **3.22.5, 3.28, 3.29, 3.30, 3.31**; any other version WARNs. The 3.22 line is pinned to the patch level, so 3.22.1 is *not* covered by the 3.22.5 entry.
2. **Flannel** — DaemonSet `kube-flannel-ds`. The documentation lists Flannel without a version constraint, so any version passes.
3. **Cilium** — DaemonSet `cilium`. Only minor versions **1.16**, **1.17**, and **1.18** are supported; any other version FAILs. Cilium 1.16 additionally requires `enableTCX=false`, which the check prints as a note.

If none of the above DaemonSets is found the check issues a WARN (not a FAIL) so that clusters with custom CNIs do not block the pre-check entirely — manual verification is still required.

### Notes on checks O and P

**Check O — Helm** reads `helm version --short` from the host running the script. Helm 2 FAILs (it cannot install the KCS chart at all); Helm 3.21.1 and 4.1 PASS; any other Helm 3 or 4 build WARNs. When `helm` is not on `PATH` the check records SKIP rather than failing, because the script is often run from a jump host that only carries `kubectl`.

**Check P — Agent resource headroom** sizes the agents from live cluster state. It counts pods across all namespaces and derives the kube-agent requirement (1 core per 2500 pods, 2 GB per 3000 pods, never less than 1 core / 2 GB), then checks every worker against the node-agent maximum footprint of 3 cores and 5 GB — the figure that applies once every optional feature is enabled (network-connection, process, reputation, file-operation and host-authorisation monitoring, container lifecycle control, and anti-malware protection in containers and on the host). A worker below that ceiling WARNs: KCS will install, but not every runtime feature will fit. The node-agent base footprint is 0.3 core and 300 MB per node.

These figures sit *on top of* the per-worker core requirements in checks B and C, and exclude the customer's own workloads.

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

The test suite runs unit tests (normalization helpers, `version_in_list` boundary cases, kernel version parsing and tiering, Kubernetes and OpenShift version tiering, per-worker CPU/memory/ephemeral thresholds, distribution detection, mock-kubectl pass/fail cases, python3-absence check, Gateway API ingress fallback, Calico/Cilium version tiering, Helm, external-DB version tiering, Vault, container runtime, agent sizing arithmetic, and probe-namespace routing) and integration tests against a real cluster. All **170** unit tests must pass; integration tests require `--kubeconfig=` and optionally `--external-db=` / `--vault=`.

Because WARN and SKIP both return 0, the exit status alone cannot distinguish them from PASS. The suite therefore asserts on the recorded verdict via an `_assert_status` helper that inspects `CHECK_RESULTS`.

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
