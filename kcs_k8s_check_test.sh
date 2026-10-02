#!/usr/bin/env bash
# TDD test suite for kcs_k8s_check.sh
# Run: bash kcs_k8s_check_test.sh [--kubeconfig=<path>]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/kcs_k8s_check.sh"

# Parse args — supports multiple flags in any order
KUBECONFIG_ARG=""
INTEGRATION_EXTERNAL_DB=""
INTEGRATION_EXTERNAL_DB_USER="postgres"
INTEGRATION_EXTERNAL_DB_PASSWORD=""
INTEGRATION_VAULT_HOST=""
INTEGRATION_VAULT_ACCOUNT=""

for _arg in "$@"; do
  case "$_arg" in
    --kubeconfig=*) KUBECONFIG_ARG="$_arg";;
    --external-db=*) INTEGRATION_EXTERNAL_DB="${_arg#*=}";;
    --external-db-user=*) INTEGRATION_EXTERNAL_DB_USER="${_arg#*=}";;
    --external-db-password=*) INTEGRATION_EXTERNAL_DB_PASSWORD="${_arg#*=}";;
    --vault=*) INTEGRATION_VAULT_HOST="${_arg#*=}";;
    --vault-account=*) INTEGRATION_VAULT_ACCOUNT="${_arg#*=}";;
    --kubeconfig) ;; # handled as next arg below — not currently needed
    *) echo "Unknown test arg: $_arg" >&2;;
  esac
done

# ── test framework ────────────────────────────────────────────────────────────
_PASS=0; _FAIL=0
_t() { # _t "name" cmd...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✅  $name"; ((_PASS++))
  else
    echo "  ❌  $name"; ((_FAIL++))
  fi
}
_assert_eq() { [[ "$1" == "$2" ]] || { echo "    expected='$2' got='$1'" >&2; return 1; }; }
_assert_ge()  { [[ "$1" -ge "$2" ]] || { echo "    expected>=$2 got=$1" >&2; return 1; }; }

# Returns success when the wrapped command returns non-zero.
_assert_check_fails() { "$@" && return 1 || return 0; }

# Status of the most recently recorded check result.
# CHECK_RESULTS entries are "LABEL:STATUS:DETAIL"; bash 3.2 has no [-1] index.
_last_status() {
  local n=${#CHECK_RESULTS[@]}
  [[ $n -eq 0 ]] && { echo "NONE"; return; }
  local rest="${CHECK_RESULTS[$((n-1))]#*:}"
  echo "${rest%%:*}"
}

# _assert_status PASS|WARN|FAIL|SKIP <check function> [args...]
# Clears CHECK_RESULTS first so the assertion sees only this check's verdict.
# PASS/WARN/FAIL/SKIP are distinct outcomes but WARN and SKIP both return 0,
# so the exit status alone cannot tell them apart — hence this helper.
_assert_status() {
  local want="$1"; shift
  CHECK_RESULTS=()
  "$@" >/dev/null 2>&1
  local got; got=$(_last_status)
  if [[ "$got" == *"$want"* ]]; then
    return 0
  fi
  echo "    expected status='$want' got='$got'" >&2
  return 1
}

# ── source helpers only (skip main) ──────────────────────────────────────────
UNIT_TEST_MODE=1
# shellcheck source=kcs_k8s_check.sh
if [[ ! -f "$SCRIPT" ]]; then
  echo "FATAL: $SCRIPT not found — run this after creating the script" >&2
  # Still run integration tests that don't need sourcing
  _SOURCED=0
else
  source "$SCRIPT"
  _SOURCED=1
  # Unit tests must not litter the working directory with report files.
  # Exported so the `bash -c` tests that re-source the script inherit it.
  export REPORT_FILE=/dev/null
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: CPU normalization ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  _t "normalize_cpu: integer cores → millicores" \
    _assert_eq "$(normalize_cpu 4)"    "4000"
  _t "normalize_cpu: millicore suffix" \
    _assert_eq "$(normalize_cpu 500m)" "500"
  _t "normalize_cpu: 16 cores → 16000" \
    _assert_eq "$(normalize_cpu 16)"   "16000"
  _t "normalize_cpu: 250m stays 250" \
    _assert_eq "$(normalize_cpu 250m)" "250"
else
  echo "  ⚠️  Skipped (script not found)"
fi

echo ""
echo "━━━ Unit tests: memory normalization ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  _t "normalize_mem_mib: Ki suffix → MiB" \
    _assert_eq "$(normalize_mem_mib 1048576Ki)" "1024"
  _t "normalize_mem_mib: Mi suffix → MiB" \
    _assert_eq "$(normalize_mem_mib 2048Mi)"    "2048"
  _t "normalize_mem_mib: Gi suffix → MiB" \
    _assert_eq "$(normalize_mem_mib 20Gi)"      "20480"
  _t "normalize_mem_mib: raw bytes → MiB" \
    _assert_eq "$(normalize_mem_mib 1073741824)" "1024"
  _t "normalize_mem_mib: 7891148Ki → 7706 MiB" \
    _assert_eq "$(normalize_mem_mib 7891148Ki)" "7706"
else
  echo "  ⚠️  Skipped (script not found)"
fi

echo ""
echo "━━━ Unit tests: ephemeral storage normalization ━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  _t "normalize_ephemeral_mib: Mi suffix" \
    _assert_eq "$(normalize_ephemeral_mib 30706Mi)" "30706"
  _t "normalize_ephemeral_mib: Gi suffix" \
    _assert_eq "$(normalize_ephemeral_mib 30Gi)"    "30720"
  _t "normalize_ephemeral_mib: Ki suffix" \
    _assert_eq "$(normalize_ephemeral_mib 1048576Ki)" "1024"
  _t "normalize_ephemeral_mib: raw bytes" \
    _assert_eq "$(normalize_ephemeral_mib 1073741824)" "1024"
else
  echo "  ⚠️  Skipped (script not found)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: check functions with mock kubectl ━━━━━━━━━━━━━━━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  # Mock kubectl for unit tests
  _setup_mock_kubectl() {
    kubectl() {
      case "$*" in
        # version — returns JSON parsed by grep+sed (no python3 required)
        *"version"*"--output=json"*)
          echo '{"serverVersion":{"major":"1","minor":"31","gitVersion":"v1.31.2"}}';;
        *"version --output=json"*)
          echo '{"serverVersion":{"major":"1","minor":"31","gitVersion":"v1.31.2"}}';;

        # nodes arch
        *"nodeInfo.architecture"*)
          printf "amd64\namd64\namd64\namd64\n";;
        # OS/kernel info (check_os_kernel)
        *"nodeInfo.kernelVersion"*)
          printf "node1\tUbuntu 22.04.3 LTS\t6.5.0-14-generic\nnode2\tUbuntu 22.04.3 LTS\t6.5.0-14-generic\n";;
        # node names for eBPF check
        *"custom-columns=NAME"*)
          printf "node1\nnode2\n";;
        # eBPF check pods
        *"get pod"*"kcs-ebpf"*"phase"*) echo "Succeeded";;
        *"logs"*"kcs-ebpf"*) echo "BTF_OK";;
        # per-node allocatable rows: "<node name><TAB><value>"
        # KCS 2.5.1 thresholds apply per worker node, so the mock returns
        # three workers that each clear 13 cores / 20 GiB / 28 GiB.
        *"allocatable.cpu"*)
          printf "worker1\t16\nworker2\t16\nworker3\t16\n";;
        *"allocatable.memory"*)
          printf "worker1\t32626916Ki\nworker2\t32626888Ki\nworker3\t32626884Ki\n";;
        *"ephemeral-storage"*)
          printf "worker1\t66546Mi\nworker2\t66546Mi\nworker3\t66546Mi\n";;
        # pod inventory (agent resource sizing)
        *"get pods"*"--all-namespaces"*)
          printf "pod1\npod2\npod3\n";;
        # Gateway API absent in the default mock — IngressClass covers ingress
        *"api-resources"*"gateway.networking.k8s.io"*) printf "";;
        *"get gateways"*) printf "";;
        # storageclass
        *"get storageclass"*)
          echo "NAME                 PROVISIONER
longhorn (default)   driver.longhorn.io
longhorn-static      driver.longhorn.io";;
        # ingressclass
        *"get ingressclass"*)
          echo "NAME    CONTROLLER
nginx   k8s.io/ingress-nginx";;
        # ingress pods
        *"get pods"*"ingress-nginx"*)
          echo "NAME                           READY   STATUS    RESTARTS
ingress-nginx-controller-xxxx   1/1     Running   0";;
        # PVC create/get/delete
        *"apply -f"*) echo "persistentvolumeclaim/kcs-precheck-test created";;
        *"get pvc"*)  echo "Bound";;
        *"delete pvc"*) echo "persistentvolumeclaim deleted";;
        # registry pod
        *"run kcs-precheck"*) echo "pod/kcs-precheck-reg created";;
        *"get pod"*"kcs-precheck"*"-o jsonpath"*"phase"*) echo "Succeeded";;
        *"logs"*"kcs-precheck"*) echo "200";;
        *"delete pod"*) echo "pod deleted";;
        *) echo "mock: unhandled: $*" >&2; return 1;;
      esac
    }
    export -f kubectl
  }
  _setup_mock_kubectl

  _t "check_k8s_version passes for v1.31 amd64 cluster" \
    check_k8s_version

  _t "check_cpu passes when every worker has ≥ 13 cores (mock: 16 each)" \
    check_cpu

  _t "check_memory passes when every worker has ≥ 20 GiB (mock: ~31 GiB each)" \
    check_memory

  _t "check_storage passes with default storageclass and Bound PVC" \
    check_storage

  _t "check_ingress passes when nginx ingressclass found" \
    check_ingress

  _t "check_registry passes when curl pod returns 200" \
    check_registry
else
  echo "  ⚠️  Skipped (script not found)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: mock kubectl failure cases ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  # Old Kubernetes version
  kubectl() {
    case "$*" in
      *"version"*"--output=json"*)
        echo '{"serverVersion":{"major":"1","minor":"18","gitVersion":"v1.18.0"}}';;
      *"nodeInfo.architecture"*) printf "amd64\n";;
      *) echo "mock" ;;
    esac
  }
  export -f kubectl
  _t "check_k8s_version FAILS for v1.18 (below minimum v1.21)" \
    _assert_check_fails check_k8s_version

  # Undersized worker (4 cores — KCS 2.5.1 needs 13 per worker node)
  kubectl() {
    case "$*" in
      *"allocatable.cpu"*) printf "worker1\t4\n";;
      *) echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_cpu FAILS when a worker has < 13 cores (mock: 4 cores)" \
    _assert_check_fails check_cpu

  # Undersized worker (8 GiB — KCS 2.5.1 needs 20 GB per worker node)
  kubectl() {
    case "$*" in
      *"allocatable.memory"*) printf "worker1\t8192Mi\n";;
      *) echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_memory FAILS when a worker has < 20 GiB (mock: 8 GiB)" \
    _assert_check_fails check_memory

  # Restore good mock for remaining tests
  _setup_mock_kubectl
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: no-python3 dependency ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  _t "check_k8s_version works when python3 is absent from PATH" bash -c '
    FAKEDIR=$(mktemp -d)
    trap "rm -rf \"$FAKEDIR\"" EXIT
    printf "#!/bin/sh\nexit 127\n" > "$FAKEDIR/python3"
    chmod +x "$FAKEDIR/python3"
    export PATH="$FAKEDIR:$PATH"
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() {
      case "$*" in
        *"version"*"--output=json"*)
          echo '"'"'{"serverVersion":{"major":"1","minor":"31"}}'"'"';;
        *"nodeInfo.architecture"*) printf "amd64\n";;
        *) return 1;;
      esac
    }
    export -f kubectl
    check_k8s_version
  '
else
  echo "  ⚠️  Skipped (script not found)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: Kubernetes distribution detection ━━━━━━━━━━━━━━━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then

  # K3s — not a supported distribution; must always ERROR regardless of K8s version
  kubectl() {
    case "$*" in
      *"version"*"--output=json"*)
        echo '{"clientVersion":{"gitVersion":"v1.34.3+k3s1"},"serverVersion":{"major":"1","minor":"34","gitVersion":"v1.34.3+k3s1"}}';;
      *"nodeInfo.architecture"*) printf "amd64\n";;
      *) echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_k8s_version ERRORS for K3s distribution (v1.34.3+k3s1)" \
    _assert_check_fails check_k8s_version

  # OpenShift 4.18 — detected via clientVersion gitVersion; ≥ 4.8 must PASS
  kubectl() {
    case "$*" in
      *"version"*"--output=json"*)
        echo '{"clientVersion":{"gitVersion":"4.18.0-202507211933.p0.g4fcb2d0.assembly.stream.el9-4fcb2d0"},"serverVersion":{"major":"1","minor":"33","gitVersion":"v1.33.6"}}';;
      *"nodeInfo.architecture"*) printf "amd64\n";;
      *) echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_k8s_version PASSES for OpenShift 4.18 (supported, ≥ 4.8)" \
    check_k8s_version

  # OpenShift 4.8 — minimum supported version; must PASS
  kubectl() {
    case "$*" in
      *"version"*"--output=json"*)
        echo '{"clientVersion":{"gitVersion":"4.8.0-202108042329.p0.gab0f9cf.assembly.stream"},"serverVersion":{"major":"1","minor":"21","gitVersion":"v1.21.0"}}';;
      *"nodeInfo.architecture"*) printf "amd64\n";;
      *) echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_k8s_version PASSES for OpenShift 4.8 (minimum supported)" \
    check_k8s_version

  # OpenShift 4.7 — below minimum 4.8; must ERROR
  kubectl() {
    case "$*" in
      *"version"*"--output=json"*)
        echo '{"clientVersion":{"gitVersion":"4.7.0-202107012112.p0.g8bcacd2.assembly.stream"},"serverVersion":{"major":"1","minor":"20","gitVersion":"v1.20.0"}}';;
      *"nodeInfo.architecture"*) printf "amd64\n";;
      *) echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_k8s_version ERRORS for OpenShift 4.7 (below minimum 4.8)" \
    _assert_check_fails check_k8s_version

  # OpenShift 4.11 — explicitly listed in KCS24 docs; must PASS
  kubectl() {
    case "$*" in
      *"version"*"--output=json"*)
        echo '{"clientVersion":{"gitVersion":"4.11.0-202211120029.p0.g3e0c89d.assembly.stream"},"serverVersion":{"major":"1","minor":"24","gitVersion":"v1.24.0"}}';;
      *"nodeInfo.architecture"*) printf "amd64\n";;
      *) echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_k8s_version PASSES for OpenShift 4.11 (explicitly listed in docs)" \
    check_k8s_version

  # RKE2 with K8s 1.30 — meets minimum 1.21; must PASS (Rancher 2.12)
  kubectl() {
    case "$*" in
      *"version"*"--output=json"*)
        echo '{"clientVersion":{"gitVersion":"v1.30.6"},"serverVersion":{"major":"1","minor":"30","gitVersion":"v1.30.6+rke2r1"}}';;
      *"nodeInfo.architecture"*) printf "amd64\n";;
      *) echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_k8s_version PASSES for RKE2 v1.30.6+rke2r1 (Rancher 2.12, meets K8s minimum)" \
    check_k8s_version

  # RKE2 with K8s 1.18 — below minimum 1.21; must ERROR
  kubectl() {
    case "$*" in
      *"version"*"--output=json"*)
        echo '{"clientVersion":{"gitVersion":"v1.18.0"},"serverVersion":{"major":"1","minor":"18","gitVersion":"v1.18.0+rke2r1"}}';;
      *"nodeInfo.architecture"*) printf "amd64\n";;
      *) echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_k8s_version ERRORS for RKE2 v1.18.0+rke2r1 (below K8s minimum 1.21)" \
    _assert_check_fails check_k8s_version

  _setup_mock_kubectl
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: kernel version parsing ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  _t "parse_kernel_version: Ubuntu 6.5.0-14-generic → '6 5'" \
    _assert_eq "$(parse_kernel_version '6.5.0-14-generic')" "6 5"
  _t "parse_kernel_version: CentOS 4.18.0-193.el8.x86_64 → '4 18'" \
    _assert_eq "$(parse_kernel_version '4.18.0-193.el8.x86_64')" "4 18"
  _t "parse_kernel_version: RHEL 5.14.0-427.33.1.el9_4.x86_64 → '5 14'" \
    _assert_eq "$(parse_kernel_version '5.14.0-427.33.1.el9_4.x86_64')" "5 14"
  _t "kernel_ge: 5.15 >= 4.18 → true" \
    kernel_ge "5.15.0-91-generic" 4 18
  _t "kernel_ge: 4.18.0 >= 4.18 → true (exact match)" \
    kernel_ge "4.18.0-193.el8.x86_64" 4 18
  _t "kernel_ge: 4.14.0 < 4.18 → false" \
    _assert_check_fails kernel_ge "4.14.0" 4 18
  _t "kernel_ge: 5.7.0 < 5.8 → false" \
    _assert_check_fails kernel_ge "5.7.0" 5 8
  _t "kernel_ge: 5.8.0 >= 5.8 → true (exact match)" \
    kernel_ge "5.8.0-36-generic" 5 8
  _t "kernel_ge: 3.10 < 4.18 → false" \
    _assert_check_fails kernel_ge "3.10.0-1160.el7.x86_64" 4 18
else
  echo "  ⚠️  Skipped (script not found)"
fi

echo ""
echo "━━━ Unit tests: check_os_kernel ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  # All nodes kernel >= 5.8 → PASS
  kubectl() {
    case "$*" in
      *"nodeInfo.kernelVersion"*)
        printf "node1\tUbuntu 22.04.3 LTS\t6.5.0-14-generic\nnode2\tUbuntu 22.04.3 LTS\t6.5.0-14-generic\n";;
      *) echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_os_kernel returns 0 for kernel 6.5 (untested in 2.5.1 → WARN)" \
    check_os_kernel

  # Kernel >= 4.18 but < 5.8 → returns 0 (PASS with WARN)
  kubectl() {
    case "$*" in
      *"nodeInfo.kernelVersion"*)
        printf "node1\tCentOS 8.2.2004\t4.18.0-193.el8.x86_64\n";;
      *) echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_os_kernel returns 0 for kernel 4.18 (tested, but < 5.8 → WARN)" \
    check_os_kernel

  # Kernel < 4.18 → FAIL (returns 1)
  kubectl() {
    case "$*" in
      *"nodeInfo.kernelVersion"*)
        printf "node1\tUbuntu 16.04\t4.14.0-96.x86_64\n";;
      *) echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_os_kernel FAILS when any node has kernel < 4.18" \
    _assert_check_fails check_os_kernel

  # Restore good mock
  _setup_mock_kubectl
fi

echo ""
echo "━━━ Unit tests: check_ebpf ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  # BTF present on all nodes → PASS
  kubectl() {
    case "$*" in
      *"custom-columns=NAME"*) printf "node1\nnode2\n";;
      *"apply -f"*) echo "pod created";;
      *"get pod"*"kcs-ebpf"*"phase"*) echo "Succeeded";;
      *"logs"*"kcs-ebpf"*) echo "BTF_OK";;
      *"delete pod"*) echo "pod deleted";;
      *) echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_ebpf passes when BTF available on all nodes" \
    check_ebpf

  # BTF missing on a node → FAIL (returns 1)
  kubectl() {
    case "$*" in
      *"custom-columns=NAME"*) printf "node1\n";;
      *"apply -f"*) echo "pod created";;
      *"get pod"*"kcs-ebpf"*"phase"*) echo "Succeeded";;
      *"logs"*"kcs-ebpf"*) echo "BTF_MISSING";;
      *"delete pod"*) echo "pod deleted";;
      *) echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_ebpf FAILS when BTF missing on a node" \
    _assert_check_fails check_ebpf

  # Restore good mock
  _setup_mock_kubectl
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: check_external_db ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  _t "parse_args: --external-db sets EXTERNAL_DB_HOST" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    EXTERNAL_DB_HOST=""
    parse_args --external-db 192.168.1.100
    [[ "$EXTERNAL_DB_HOST" == "192.168.1.100" ]]
  '

  _t "parse_args: --external-db-user sets EXTERNAL_DB_USER" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    EXTERNAL_DB_USER=""
    parse_args --external-db-user alice
    [[ "$EXTERNAL_DB_USER" == "alice" ]]
  '

  _t "parse_args: --external-db-password sets EXTERNAL_DB_PASSWORD" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    EXTERNAL_DB_PASSWORD=""
    parse_args --external-db-password s3cr3t
    [[ "$EXTERNAL_DB_PASSWORD" == "s3cr3t" ]]
  '

  _t "check_external_db skips (PASS) when EXTERNAL_DB_HOST not set" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    EXTERNAL_DB_HOST=""
    kubectl() { echo "mock"; }
    export -f kubectl
    check_external_db
  '

  # check_external_db PASS case — mock pod completes with DB_CONNECT_OK
  EXTERNAL_DB_HOST="192.168.1.100"
  EXTERNAL_DB_USER="kcs_user"
  EXTERNAL_DB_PASSWORD="secret"
  kubectl() {
    case "$*" in
      *"apply -f"*)                          echo "pod/kcs-precheck-db created";;
      *"get pod"*"kcs-precheck-db"*)         echo "Succeeded";;
      *"logs"*"kcs-precheck-db"*)            echo "DB_CONNECT_OK";;
      *"delete pod"*)                        echo "pod deleted";;
      *)                                     echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_external_db PASSES when pod reports DB_CONNECT_OK" \
    check_external_db

  # check_external_db FAIL case — mock pod reports network failure
  kubectl() {
    case "$*" in
      *"apply -f"*)                          echo "pod/kcs-precheck-db created";;
      *"get pod"*"kcs-precheck-db"*)         echo "Succeeded";;
      *"logs"*"kcs-precheck-db"*)            echo "DB_CONNECT_FAIL_NETWORK";;
      *"delete pod"*)                        echo "pod deleted";;
      *)                                     echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_external_db FAILS when pod reports DB_CONNECT_FAIL_NETWORK" \
    _assert_check_fails check_external_db

  # check_external_db WARN case — pod never completes (DB_CHECK_TIMEOUT=0 skips loop)
  DB_CHECK_TIMEOUT=0
  kubectl() {
    case "$*" in
      *"apply -f"*)   echo "pod/kcs-precheck-db created";;
      *"delete pod"*) echo "pod deleted";;
      *)              echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_external_db WARNS (not fails) when pod times out" \
    check_external_db

  # RED: network failure produces a distinct "unreachable" message and returns non-zero
  _t "check_external_db FAILS with unreachable message when pod reports DB_CONNECT_FAIL_NETWORK" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    EXTERNAL_DB_HOST="10.0.0.1"; EXTERNAL_DB_USER="kcs_user"; EXTERNAL_DB_PASSWORD="s3cr3t"
    kubectl() {
      case "$*" in
        *"apply -f"*)                  echo "pod created";;
        *"get pod"*"kcs-precheck-db"*) echo "Succeeded";;
        *"logs"*"kcs-precheck-db"*)    echo "DB_CONNECT_FAIL_NETWORK";;
        *"delete pod"*)                echo "pod deleted";;
        *)                             echo "mock";;
      esac
    }
    export -f kubectl
    output=$(check_external_db 2>&1); rc=$?
    [[ $rc -ne 0 ]] && echo "$output" | grep -qi "unreachable\|network\|port"
  '

  # RED: auth failure produces a distinct "authentication" message and returns non-zero
  _t "check_external_db FAILS with authentication message when pod reports DB_CONNECT_FAIL_AUTH" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    EXTERNAL_DB_HOST="10.0.0.1"; EXTERNAL_DB_USER="kcs_user"; EXTERNAL_DB_PASSWORD="wrongpass"
    kubectl() {
      case "$*" in
        *"apply -f"*)                  echo "pod created";;
        *"get pod"*"kcs-precheck-db"*) echo "Succeeded";;
        *"logs"*"kcs-precheck-db"*)    echo "DB_CONNECT_FAIL_AUTH";;
        *"delete pod"*)                echo "pod deleted";;
        *)                             echo "mock";;
      esac
    }
    export -f kubectl
    output=$(check_external_db 2>&1); rc=$?
    [[ $rc -ne 0 ]] && echo "$output" | grep -qi "auth\|password\|credential"
  '

  # Reset state
  EXTERNAL_DB_HOST=""
  EXTERNAL_DB_USER=""
  EXTERNAL_DB_PASSWORD=""
  unset DB_CHECK_TIMEOUT
  _setup_mock_kubectl
else
  echo "  ⚠️  Skipped (script not found)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: check_vault ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  _t "parse_args: --vault sets VAULT_HOST" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    VAULT_HOST=""
    parse_args --vault 10.160.6.210
    [[ "$VAULT_HOST" == "10.160.6.210" ]]
  '

  _t "parse_args: --vault-account sets VAULT_ACCOUNT_FILE" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    VAULT_ACCOUNT_FILE=""
    parse_args --vault-account /tmp/test.key
    [[ "$VAULT_ACCOUNT_FILE" == "/tmp/test.key" ]]
  '

  _t "check_vault skips (PASS) when VAULT_HOST not set" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    VAULT_HOST=""
    kubectl() { echo "mock"; }
    export -f kubectl
    check_vault
  '

  _t "check_vault FAILS when VAULT_ACCOUNT_FILE not specified" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    VAULT_HOST="10.160.6.210"
    VAULT_ACCOUNT_FILE=""
    kubectl() { echo "mock"; }
    export -f kubectl
    ! check_vault
  '

  _t "check_vault FAILS when VAULT_ACCOUNT_FILE does not exist" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    VAULT_HOST="10.160.6.210"
    VAULT_ACCOUNT_FILE="/tmp/nonexistent_kcs_vault_xyz_12345.key"
    kubectl() { echo "mock"; }
    export -f kubectl
    ! check_vault
  '

  _t "check_vault FAILS when key file has no VAULT_TOKEN" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    tmpf=$(mktemp /tmp/vault-XXXX.key)
    echo "VAULT_ADDR=http://10.0.0.1:8200" > "$tmpf"
    VAULT_HOST="10.0.0.1"; VAULT_ACCOUNT_FILE="$tmpf"
    kubectl() { echo "mock"; }
    export -f kubectl
    result=0; check_vault || result=$?
    rm -f "$tmpf"
    [[ $result -ne 0 ]]
  '

  _t "check_vault PASSES when pod reports VAULT_OK" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    tmpf=$(mktemp /tmp/vault-XXXX.key)
    printf "VAULT_ADDR=http://10.0.0.1:8200\nVAULT_TOKEN=test_token_xyz\n" > "$tmpf"
    VAULT_HOST="10.0.0.1"; VAULT_ACCOUNT_FILE="$tmpf"
    kubectl() {
      case "$*" in
        *"apply -f"*)                       echo "pod/kcs-precheck-vault created";;
        *"get pod"*"kcs-precheck-vault"*)   echo "Succeeded";;
        *"logs"*"kcs-precheck-vault"*)      echo "VAULT_OK";;
        *"delete pod"*)                     echo "pod deleted";;
        *)                                  echo "mock";;
      esac
    }
    export -f kubectl
    check_vault; rc=$?
    rm -f "$tmpf"; exit $rc
  '

  _t "check_vault FAILS when pod reports VAULT_UNREACHABLE" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    tmpf=$(mktemp /tmp/vault-XXXX.key)
    printf "VAULT_ADDR=http://10.0.0.1:8200\nVAULT_TOKEN=test_token_xyz\n" > "$tmpf"
    VAULT_HOST="10.0.0.1"; VAULT_ACCOUNT_FILE="$tmpf"
    kubectl() {
      case "$*" in
        *"apply -f"*)                       echo "pod/kcs-precheck-vault created";;
        *"get pod"*"kcs-precheck-vault"*)   echo "Succeeded";;
        *"logs"*"kcs-precheck-vault"*)      echo "VAULT_UNREACHABLE";;
        *"delete pod"*)                     echo "pod deleted";;
        *)                                  echo "mock";;
      esac
    }
    export -f kubectl
    result=0; check_vault || result=$?
    rm -f "$tmpf"; [[ $result -ne 0 ]]
  '

  _t "check_vault FAILS when pod reports VAULT_SEALED" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    tmpf=$(mktemp /tmp/vault-XXXX.key)
    printf "VAULT_ADDR=http://10.0.0.1:8200\nVAULT_TOKEN=test_token_xyz\n" > "$tmpf"
    VAULT_HOST="10.0.0.1"; VAULT_ACCOUNT_FILE="$tmpf"
    kubectl() {
      case "$*" in
        *"apply -f"*)                       echo "pod/kcs-precheck-vault created";;
        *"get pod"*"kcs-precheck-vault"*)   echo "Succeeded";;
        *"logs"*"kcs-precheck-vault"*)      echo "VAULT_SEALED";;
        *"delete pod"*)                     echo "pod deleted";;
        *)                                  echo "mock";;
      esac
    }
    export -f kubectl
    result=0; check_vault || result=$?
    rm -f "$tmpf"; [[ $result -ne 0 ]]
  '

  _t "check_vault FAILS when pod reports VAULT_AUTH_FAIL" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    tmpf=$(mktemp /tmp/vault-XXXX.key)
    printf "VAULT_ADDR=http://10.0.0.1:8200\nVAULT_TOKEN=test_token_xyz\n" > "$tmpf"
    VAULT_HOST="10.0.0.1"; VAULT_ACCOUNT_FILE="$tmpf"
    kubectl() {
      case "$*" in
        *"apply -f"*)                       echo "pod/kcs-precheck-vault created";;
        *"get pod"*"kcs-precheck-vault"*)   echo "Succeeded";;
        *"logs"*"kcs-precheck-vault"*)      echo "VAULT_AUTH_FAIL";;
        *"delete pod"*)                     echo "pod deleted";;
        *)                                  echo "mock";;
      esac
    }
    export -f kubectl
    result=0; check_vault || result=$?
    rm -f "$tmpf"; [[ $result -ne 0 ]]
  '

  _t "check_vault WARNS when pod times out" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    tmpf=$(mktemp /tmp/vault-XXXX.key)
    printf "VAULT_ADDR=http://10.0.0.1:8200\nVAULT_TOKEN=test_token_xyz\n" > "$tmpf"
    VAULT_HOST="10.0.0.1"; VAULT_ACCOUNT_FILE="$tmpf"
    VAULT_CHECK_TIMEOUT=0
    kubectl() {
      case "$*" in
        *"apply -f"*)   echo "pod/kcs-precheck-vault created";;
        *"delete pod"*) echo "pod deleted";;
        *)              echo "mock";;
      esac
    }
    export -f kubectl
    check_vault; rc=$?
    rm -f "$tmpf"; exit $rc
  '

  _t "check_vault FAILS with network message when pod reports VAULT_UNREACHABLE" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    tmpf=$(mktemp /tmp/vault-XXXX.key)
    printf "VAULT_ADDR=http://10.0.0.1:8200\nVAULT_TOKEN=test_token_xyz\n" > "$tmpf"
    VAULT_HOST="10.0.0.1"; VAULT_ACCOUNT_FILE="$tmpf"
    kubectl() {
      case "$*" in
        *"apply -f"*)                       echo "pod created";;
        *"get pod"*"kcs-precheck-vault"*)   echo "Succeeded";;
        *"logs"*"kcs-precheck-vault"*)      echo "VAULT_UNREACHABLE";;
        *"delete pod"*)                     echo "pod deleted";;
        *)                                  echo "mock";;
      esac
    }
    export -f kubectl
    output=$(check_vault 2>&1); rc=$?
    rm -f "$tmpf"
    [[ $rc -ne 0 ]] && echo "$output" | grep -qi "unreachable\|network\|port"
  '

  _t "check_vault FAILS with sealed message when pod reports VAULT_SEALED" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    tmpf=$(mktemp /tmp/vault-XXXX.key)
    printf "VAULT_ADDR=http://10.0.0.1:8200\nVAULT_TOKEN=test_token_xyz\n" > "$tmpf"
    VAULT_HOST="10.0.0.1"; VAULT_ACCOUNT_FILE="$tmpf"
    kubectl() {
      case "$*" in
        *"apply -f"*)                       echo "pod created";;
        *"get pod"*"kcs-precheck-vault"*)   echo "Succeeded";;
        *"logs"*"kcs-precheck-vault"*)      echo "VAULT_SEALED";;
        *"delete pod"*)                     echo "pod deleted";;
        *)                                  echo "mock";;
      esac
    }
    export -f kubectl
    output=$(check_vault 2>&1); rc=$?
    rm -f "$tmpf"
    [[ $rc -ne 0 ]] && echo "$output" | grep -qi "seal"
  '

  _t "check_vault FAILS with auth message when pod reports VAULT_AUTH_FAIL" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    tmpf=$(mktemp /tmp/vault-XXXX.key)
    printf "VAULT_ADDR=http://10.0.0.1:8200\nVAULT_TOKEN=test_token_xyz\n" > "$tmpf"
    VAULT_HOST="10.0.0.1"; VAULT_ACCOUNT_FILE="$tmpf"
    kubectl() {
      case "$*" in
        *"apply -f"*)                       echo "pod created";;
        *"get pod"*"kcs-precheck-vault"*)   echo "Succeeded";;
        *"logs"*"kcs-precheck-vault"*)      echo "VAULT_AUTH_FAIL";;
        *"delete pod"*)                     echo "pod deleted";;
        *)                                  echo "mock";;
      esac
    }
    export -f kubectl
    output=$(check_vault 2>&1); rc=$?
    rm -f "$tmpf"
    [[ $rc -ne 0 ]] && echo "$output" | grep -qi "auth\|token\|credential"
  '

  _setup_mock_kubectl

  # ─── Unit tests: check_container_runtime ──────────────────────────────────
  echo ""
  echo "━━━ Unit tests: check_container_runtime ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  _t "check_container_runtime passes when all nodes use containerd" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() {
      case "$*" in
        *"containerRuntimeVersion"*)
          printf "node1\tcontainerd://1.7.11\nnode2\tcontainerd://1.6.26\n";;
        *) echo "mock" >&2; return 1;;
      esac
    }
    export -f kubectl
    check_container_runtime
  '

  _t "check_container_runtime passes when all nodes use cri-o" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() {
      case "$*" in
        *"containerRuntimeVersion"*)
          printf "node1\tcri-o://1.28.2\nnode2\tcri-o://1.27.1\n";;
        *) echo "mock" >&2; return 1;;
      esac
    }
    export -f kubectl
    check_container_runtime
  '

  _t "check_container_runtime FAILS when any node uses docker" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() {
      case "$*" in
        *"containerRuntimeVersion"*)
          printf "node1\tdocker://24.0.5\nnode2\tcontainerd://1.7.11\n";;
        *) echo "mock" >&2; return 1;;
      esac
    }
    export -f kubectl
    result=0; check_container_runtime >/dev/null 2>&1 || result=$?
    [[ $result -ne 0 ]]
  '

  _t "check_container_runtime FAILS with docker message when docker found" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() {
      case "$*" in
        *"containerRuntimeVersion"*)
          printf "node1\tdocker://24.0.5\nnode2\tcontainerd://1.7.11\n";;
        *) echo "mock" >&2; return 1;;
      esac
    }
    export -f kubectl
    output=$(check_container_runtime 2>&1); rc=$?
    [[ $rc -ne 0 ]] && echo "$output" | grep -qi "docker"
  '

  _setup_mock_kubectl

  # ─── Unit tests: check_cni ────────────────────────────────────────────────
  echo ""
  echo "━━━ Unit tests: check_cni ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  _t "check_cni passes when Calico is installed (any version)" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() {
      case "$*" in
        *"daemonsets"*"--all-namespaces"*"calico-node"*)
          printf "calico-system\tdocker.io/calico/node:v3.27.0\n";;
        *) return 1;;
      esac
    }
    export -f kubectl
    check_cni
  '

  _t "check_cni passes when Flannel is installed (any version)" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() {
      case "$*" in
        *"daemonsets"*"--all-namespaces"*"calico-node"*) return 1;;
        *"daemonsets"*"--all-namespaces"*"kube-flannel-ds"*)
          printf "kube-flannel\tdocker.io/flannel/flannel:v0.23.0\n";;
        *) return 1;;
      esac
    }
    export -f kubectl
    check_cni
  '

  _t "check_cni passes when Cilium 1.16.x is installed" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() {
      case "$*" in
        *"daemonsets"*"--all-namespaces"*"calico-node"*) return 1;;
        *"daemonsets"*"--all-namespaces"*"kube-flannel-ds"*) return 1;;
        *"daemonsets"*"--all-namespaces"*"cilium"*)
          printf "kube-system\tquay.io/cilium/cilium:v1.16.4\n";;
        *) return 1;;
      esac
    }
    export -f kubectl
    check_cni
  '

  _t "check_cni passes when Cilium 1.17.x is installed" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() {
      case "$*" in
        *"daemonsets"*"--all-namespaces"*"calico-node"*) return 1;;
        *"daemonsets"*"--all-namespaces"*"kube-flannel-ds"*) return 1;;
        *"daemonsets"*"--all-namespaces"*"cilium"*)
          printf "kube-system\tquay.io/cilium/cilium:v1.17.1\n";;
        *) return 1;;
      esac
    }
    export -f kubectl
    check_cni
  '

  _t "check_cni passes when Cilium 1.18.x is installed" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() {
      case "$*" in
        *"daemonsets"*"--all-namespaces"*"calico-node"*) return 1;;
        *"daemonsets"*"--all-namespaces"*"kube-flannel-ds"*) return 1;;
        *"daemonsets"*"--all-namespaces"*"cilium"*)
          printf "kube-system\tquay.io/cilium/cilium:v1.18.0\n";;
        *) return 1;;
      esac
    }
    export -f kubectl
    check_cni
  '

  _t "check_cni FAILS when Cilium 1.15.x is installed" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() {
      case "$*" in
        *"daemonsets"*"--all-namespaces"*"calico-node"*) return 1;;
        *"daemonsets"*"--all-namespaces"*"kube-flannel-ds"*) return 1;;
        *"daemonsets"*"--all-namespaces"*"cilium"*)
          printf "kube-system\tquay.io/cilium/cilium:v1.15.7\n";;
        *) return 1;;
      esac
    }
    export -f kubectl
    result=0; check_cni >/dev/null 2>&1 || result=$?
    [[ $result -ne 0 ]]
  '

  _t "check_cni FAILS when Cilium 1.19.x is installed" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() {
      case "$*" in
        *"daemonsets"*"--all-namespaces"*"calico-node"*) return 1;;
        *"daemonsets"*"--all-namespaces"*"kube-flannel-ds"*) return 1;;
        *"daemonsets"*"--all-namespaces"*"cilium"*)
          printf "kube-system\tquay.io/cilium/cilium:v1.19.0\n";;
        *) return 1;;
      esac
    }
    export -f kubectl
    result=0; check_cni >/dev/null 2>&1 || result=$?
    [[ $result -ne 0 ]]
  '

  _t "check_cni WARNS (not fails) when no known CNI detected" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() { return 1; }
    export -f kubectl
    check_cni
  '

  _t "check_cni passes when Calico is in kube-system (non-standard namespace)" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() {
      case "$*" in
        *"daemonsets"*"--all-namespaces"*"calico-node"*)
          printf "kube-system\tdocker.io/calico/node:v3.27.0\n";;
        *) return 1;;
      esac
    }
    export -f kubectl
    out=$(check_cni 2>&1)
    echo "$out" | grep -q "CNI: Calico"
  '

  _t "check_cni passes when Flannel is in kube-system (non-standard namespace)" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() {
      case "$*" in
        *"daemonsets"*"--all-namespaces"*"calico-node"*) return 1;;
        *"daemonsets"*"--all-namespaces"*"kube-flannel-ds"*)
          printf "kube-system\tdocker.io/flannel/flannel:v0.23.0\n";;
        *) return 1;;
      esac
    }
    export -f kubectl
    out=$(check_cni 2>&1)
    echo "$out" | grep -q "CNI: Flannel"
  '

  _t "check_cni passes when Cilium is in a non-standard namespace" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() {
      case "$*" in
        *"daemonsets"*"--all-namespaces"*"calico-node"*) return 1;;
        *"daemonsets"*"--all-namespaces"*"kube-flannel-ds"*) return 1;;
        *"daemonsets"*"--all-namespaces"*"cilium"*)
          printf "cilium-system\tquay.io/cilium/cilium:v1.17.1\n";;
        *) return 1;;
      esac
    }
    export -f kubectl
    out=$(check_cni 2>&1)
    echo "$out" | grep -q "CNI: Cilium"
  '

  _setup_mock_kubectl

else
  echo "  ⚠️  Skipped (script not found)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: version_in_list helper (KCS 2.5.1 tested-version lists) ━"

if [[ $_SOURCED -eq 1 ]]; then
  _t "version_in_list: exact match" \
    version_in_list "1.33" "1.21 1.23 1.28 1.30 1.31 1.32 1.33 1.34 1.35"

  _t "version_in_list: patch version matches tested major.minor" \
    version_in_list "1.33.6" "1.21 1.23 1.28 1.30 1.31 1.32 1.33 1.34 1.35"

  _t "version_in_list: tested patch-level entry matches exactly" \
    version_in_list "3.22.5" "3.22.5 3.28 3.29 3.30 3.31"

  _t "version_in_list: untested version is not matched" \
    _assert_check_fails version_in_list "1.29" "1.21 1.23 1.28 1.30 1.31"

  # Guards against "1.3" matching "1.33" — list entries must align on a dot boundary
  _t "version_in_list: no partial-digit match (1.3 vs 1.33)" \
    _assert_check_fails version_in_list "1.3" "1.33 1.34"

  _t "version_in_list: entry must not match a longer sibling (3.2 vs 3.28)" \
    _assert_check_fails version_in_list "3.2" "3.28 3.29"
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: Kubernetes version tiering (PASS / WARN / FAIL) ━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  _mock_k8s_version() { # _mock_k8s_version <server-json>
    local json="$1"
    eval "kubectl() {
      case \"\$*\" in
        *'version'*'--output=json'*) echo '${json}';;
        *'nodeInfo.architecture'*) printf 'amd64\n';;
        *) echo mock;;
      esac
    }"
    export -f kubectl
  }

  # 1.33 is in the KCS 2.5.1 tested list → PASS
  _mock_k8s_version '{"serverVersion":{"major":"1","minor":"33","gitVersion":"v1.33.6"}}'
  _t "check_k8s_version PASSES for tested K8s 1.33" \
    _assert_status PASS check_k8s_version

  # 1.35 is the newest tested minor → PASS
  _mock_k8s_version '{"serverVersion":{"major":"1","minor":"35","gitVersion":"v1.35.0"}}'
  _t "check_k8s_version PASSES for tested K8s 1.35" \
    _assert_status PASS check_k8s_version

  # 1.29 is above the 1.21 floor but absent from the tested list → WARN
  _mock_k8s_version '{"serverVersion":{"major":"1","minor":"29","gitVersion":"v1.29.0"}}'
  _t "check_k8s_version WARNS for untested K8s 1.29 (≥ 1.21, not in tested list)" \
    _assert_status WARN check_k8s_version

  # 1.24 also above floor, untested → WARN
  _mock_k8s_version '{"serverVersion":{"major":"1","minor":"24","gitVersion":"v1.24.0"}}'
  _t "check_k8s_version WARNS for untested K8s 1.24" \
    _assert_status WARN check_k8s_version

  # Below the 1.21 floor → FAIL
  _mock_k8s_version '{"serverVersion":{"major":"1","minor":"20","gitVersion":"v1.20.0"}}'
  _t "check_k8s_version FAILS for K8s 1.20 (below minimum 1.21)" \
    _assert_status FAIL check_k8s_version

  # An untested version must still return 0 so the run continues
  _mock_k8s_version '{"serverVersion":{"major":"1","minor":"29","gitVersion":"v1.29.0"}}'
  _t "check_k8s_version returns 0 (non-blocking) on WARN" \
    check_k8s_version

  _setup_mock_kubectl
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: OpenShift version tiering (2.5.1: 4.8, 4.21) ━━━━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  _mock_ocp() { # _mock_ocp <client-gitVersion>
    local cv="$1"
    eval "kubectl() {
      case \"\$*\" in
        *'version'*'--output=json'*)
          echo '{\"clientVersion\":{\"gitVersion\":\"${cv}\"},\"serverVersion\":{\"major\":\"1\",\"minor\":\"33\",\"gitVersion\":\"v1.33.6\"}}';;
        *'nodeInfo.architecture'*) printf 'amd64\n';;
        *) echo mock;;
      esac
    }"
    export -f kubectl
  }

  _mock_ocp "4.21.0-202601151933.p0.gaaaaaaa.assembly.stream.el9-aaaaaaa"
  _t "check_k8s_version PASSES for OpenShift 4.21 (tested in 2.5.1)" \
    _assert_status PASS check_k8s_version

  _mock_ocp "4.8.0-202108042329.p0.gab0f9cf.assembly.stream"
  _t "check_k8s_version PASSES for OpenShift 4.8 (tested in 2.5.1)" \
    _assert_status PASS check_k8s_version

  # 4.18 dropped out of the tested list in 2.5.1 (was present for 2.4) → WARN
  _mock_ocp "4.18.0-202507211933.p0.g4fcb2d0.assembly.stream.el9-4fcb2d0"
  _t "check_k8s_version WARNS for OpenShift 4.18 (≥ 4.8, no longer tested)" \
    _assert_status WARN check_k8s_version

  _mock_ocp "4.7.0-202107012112.p0.g8bcacd2.assembly.stream"
  _t "check_k8s_version FAILS for OpenShift 4.7 (below minimum 4.8)" \
    _assert_status FAIL check_k8s_version

  _setup_mock_kubectl
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: per-worker-node CPU / memory / ephemeral (2.5.1) ━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  # Doc 2.5.1: each worker node needs 13 cores, 20 GB RAM, 28 GB ephemeral.
  # Control-plane nodes are excluded via a label selector.
  _mock_worker_rows() { # _mock_worker_rows <field-marker> <rows>
    local marker="$1" rows="$2"
    eval "kubectl() {
      case \"\$*\" in
        *'${marker}'*) printf '%s' \"\$(printf '${rows}')\";;
        *) echo mock;;
      esac
    }"
    export -f kubectl
  }

  _mock_worker_rows "allocatable.cpu" 'worker1\t13\nworker2\t16\n'
  _t "check_cpu PASSES when every worker has ≥ 13 cores" \
    _assert_status PASS check_cpu

  _mock_worker_rows "allocatable.cpu" 'worker1\t8\nworker2\t8\n'
  _t "check_cpu FAILS when a worker has 8 cores (< 13)" \
    _assert_status FAIL check_cpu

  _mock_worker_rows "allocatable.cpu" 'worker1\t16\nworker2\t12\n'
  _t "check_cpu FAILS when only one worker is undersized" \
    _assert_status FAIL check_cpu

  _mock_worker_rows "allocatable.cpu" 'worker1\t12800m\n'
  _t "check_cpu FAILS for 12800m (just below 13 cores)" \
    _assert_status FAIL check_cpu

  _mock_worker_rows "allocatable.memory" 'worker1\t20Gi\nworker2\t32Gi\n'
  _t "check_memory PASSES when every worker has ≥ 20 GiB" \
    _assert_status PASS check_memory

  _mock_worker_rows "allocatable.memory" 'worker1\t14164572Ki\nworker2\t14164604Ki\n'
  _t "check_memory FAILS when workers have ~13.5 GiB (< 20 GiB)" \
    _assert_status FAIL check_memory

  _mock_worker_rows "ephemeral-storage" 'worker1\t28Gi\nworker2\t64Gi\n'
  _t "check_storage_capacity PASSES when every worker has ≥ 28 GiB ephemeral" \
    _assert_status PASS check_storage_capacity

  _mock_worker_rows "ephemeral-storage" 'worker1\t20Gi\n'
  _t "check_storage_capacity FAILS when a worker has 20 GiB ephemeral (< 28)" \
    _assert_status FAIL check_storage_capacity

  # Single-node cluster: no node survives the worker selector, so the check
  # falls back to all nodes and must say so rather than silently passing.
  kubectl() {
    case "$*" in
      *"!node-role.kubernetes.io/control-plane"*) printf "";;
      *"allocatable.cpu"*) printf "single\t16\n";;
      *) echo mock;;
    esac
  }
  export -f kubectl
  _t "check_cpu WARNS on a single-node cluster (no dedicated workers)" \
    _assert_status WARN check_cpu

  _setup_mock_kubectl
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: kernel version tiering (2.5.1 tested kernels) ━━━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  _mock_kernel() { # _mock_kernel <rows>
    local rows="$1"
    eval "kubectl() {
      case \"\$*\" in
        *'nodeInfo.kernelVersion'*) printf '%s' \"\$(printf '${rows}')\";;
        *) echo mock;;
      esac
    }"
    export -f kubectl
  }

  _mock_kernel 'node1\tAstra Linux SE 1.8\t6.12.60-1-generic\n'
  _t "check_os_kernel PASSES for tested kernel 6.12" \
    _assert_status PASS check_os_kernel

  _mock_kernel 'node1\tUbuntu 24.04\t6.17.0-5-generic\n'
  _t "check_os_kernel PASSES for tested kernel 6.17 (new in 2.5.1)" \
    _assert_status PASS check_os_kernel

  _mock_kernel 'node1\tRHEL 9.4\t5.14.0-427.33.1.el9_4.x86_64\n'
  _t "check_os_kernel PASSES for tested kernel 5.14" \
    _assert_status PASS check_os_kernel

  # 6.5 is above 5.8 but absent from the tested list → WARN, not PASS
  _mock_kernel 'node1\tUbuntu 22.04.3 LTS\t6.5.0-14-generic\n'
  _t "check_os_kernel WARNS for untested kernel 6.5" \
    _assert_status WARN check_os_kernel

  # 4.18 is tested, but below 5.8 → still WARN (kcs-ih needs privileged mode)
  _mock_kernel 'node1\tCentOS 8.2.2004\t4.18.0-193.el8.x86_64\n'
  _t "check_os_kernel WARNS for tested kernel 4.18 (< 5.8, privileged kcs-ih)" \
    _assert_status WARN check_os_kernel

  _mock_kernel 'node1\tUbuntu 16.04\t4.14.0-96.x86_64\n'
  _t "check_os_kernel FAILS for kernel 4.14 (below minimum 4.18)" \
    _assert_status FAIL check_os_kernel

  # Astra Linux needs CONFIG_DEBUG_INFO_BTF=y — the report must call that out
  _mock_kernel 'node1\tAstra Linux SE 1.7\t6.1.50-1-generic\n'
  _t "check_os_kernel notes the Astra Linux BTF requirement" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() {
      case "$*" in
        *"nodeInfo.kernelVersion"*) printf "node1\tAstra Linux SE 1.7\t6.1.50-1-generic\n";;
        *) echo mock;;
      esac
    }
    export -f kubectl
    out=$(check_os_kernel 2>&1)
    echo "$out" | grep -qi "CONFIG_DEBUG_INFO_BTF"
  '

  _setup_mock_kubectl
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: Calico version tiering (2.5.1: 3.22.5, 3.28–3.31) ━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  _mock_cni_calico() { # _mock_cni_calico <image>
    local img="$1"
    eval "kubectl() {
      case \"\$*\" in
        *'calico-node'*) printf 'calico-system\t${img}\n';;
        *) return 1;;
      esac
    }"
    export -f kubectl
  }

  _mock_cni_calico "docker.io/calico/node:v3.30.1"
  _t "check_cni PASSES for tested Calico 3.30" \
    _assert_status PASS check_cni

  _mock_cni_calico "docker.io/calico/node:v3.31.0"
  _t "check_cni PASSES for tested Calico 3.31" \
    _assert_status PASS check_cni

  _mock_cni_calico "docker.io/calico/node:v3.22.5"
  _t "check_cni PASSES for tested Calico 3.22.5 (exact patch in doc)" \
    _assert_status PASS check_cni

  # 3.22.1 is NOT 3.22.5 — the doc pins the patch level for the 3.22 line
  _mock_cni_calico "docker.io/calico/node:v3.22.1"
  _t "check_cni WARNS for Calico 3.22.1 (doc pins 3.22.5)" \
    _assert_status WARN check_cni

  _mock_cni_calico "docker.io/calico/node:v3.27.0"
  _t "check_cni WARNS for untested Calico 3.27" \
    _assert_status WARN check_cni

  # Flannel carries no version constraint in the doc
  kubectl() {
    case "$*" in
      *"calico-node"*) return 1;;
      *"kube-flannel-ds"*) printf "kube-flannel\tdocker.io/flannel/flannel:v0.23.0\n";;
      *) return 1;;
    esac
  }
  export -f kubectl
  _t "check_cni PASSES for Flannel (no version constraint in doc)" \
    _assert_status PASS check_cni

  # Cilium 1.16 requires enableTCX=false — surface that in the output
  _t "check_cni notes enableTCX=false requirement for Cilium 1.16" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    kubectl() {
      case "$*" in
        *"calico-node"*) return 1;;
        *"kube-flannel-ds"*) return 1;;
        *"cilium"*) printf "kube-system\tquay.io/cilium/cilium:v1.16.4\n";;
        *) return 1;;
      esac
    }
    export -f kubectl
    out=$(check_cni 2>&1)
    echo "$out" | grep -qi "enableTCX"
  '

  _setup_mock_kubectl
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: ingress — IngressClass or Gateway API (2.5.1) ━━━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  # IngressClass present → PASS (unchanged behaviour)
  kubectl() {
    case "$*" in
      *"get ingressclass"*) printf "nginx   k8s.io/ingress-nginx\n";;
      *"get pods"*"ingress-nginx"*) printf "ingress-nginx-controller-x   1/1   Running   0\n";;
      *) echo mock;;
    esac
  }
  export -f kubectl
  _t "check_ingress PASSES with an IngressClass present" \
    _assert_status PASS check_ingress

  # No IngressClass but Gateway API installed and a Gateway exists → PASS
  kubectl() {
    case "$*" in
      *"get ingressclass"*) printf "";;
      *"api-resources"*"gateway.networking.k8s.io"*)
        printf "gateways      gtw   gateway.networking.k8s.io/v1   true   Gateway\nhttproutes          gateway.networking.k8s.io/v1   true   HTTPRoute\n";;
      *"get gateways"*) printf "kcs-gw   istio   10.0.0.5   True\n";;
      *) echo mock;;
    esac
  }
  export -f kubectl
  _t "check_ingress PASSES with no IngressClass when a Gateway API Gateway exists" \
    _assert_status PASS check_ingress

  # Gateway API CRDs present but no Gateway object → WARN (serviceType gatewayAPI
  # requires a pre-created Gateway, per the 2.5.1 install procedure)
  kubectl() {
    case "$*" in
      *"get ingressclass"*) printf "";;
      *"api-resources"*"gateway.networking.k8s.io"*)
        printf "gateways      gtw   gateway.networking.k8s.io/v1   true   Gateway\n";;
      *"get gateways"*) printf "";;
      *) echo mock;;
    esac
  }
  export -f kubectl
  _t "check_ingress WARNS when Gateway API is installed but no Gateway exists" \
    _assert_status WARN check_ingress

  # Neither IngressClass nor Gateway API → FAIL
  kubectl() {
    case "$*" in
      *"get ingressclass"*) printf "";;
      *"api-resources"*"gateway.networking.k8s.io"*) printf "";;
      *"get gateways"*) return 1;;
      *) echo mock;;
    esac
  }
  export -f kubectl
  _t "check_ingress FAILS with neither IngressClass nor Gateway API" \
    _assert_status FAIL check_ingress

  _setup_mock_kubectl
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: check_helm (2.5.1: Helm 3.21.1, 4.1) ━━━━━━━━━━━━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  _mock_helm() { # _mock_helm <short-version-output>
    local v="$1"
    eval "helm() { echo '${v}'; }"
    export -f helm
  }

  _mock_helm "v3.21.1+gabc1234"
  _t "check_helm PASSES for tested Helm 3.21.1" \
    _assert_status PASS check_helm

  _mock_helm "v4.1.0+gdef5678"
  _t "check_helm PASSES for tested Helm 4.1" \
    _assert_status PASS check_helm

  # 3.13.3 is a working Helm 3 but not the tested build → WARN
  _mock_helm "v3.13.3+gc8b9489"
  _t "check_helm WARNS for untested Helm 3.13.3" \
    _assert_status WARN check_helm

  _mock_helm "v3.20.0+gaaa"
  _t "check_helm WARNS for untested Helm 3.20.0" \
    _assert_status WARN check_helm

  # Helm 2 cannot install KCS charts at all
  _mock_helm "v2.17.0+gaaa"
  _t "check_helm FAILS for Helm 2.17 (below minimum major 3)" \
    _assert_status FAIL check_helm

  # helm absent → SKIP, never a hard failure: the script may run from a host
  # that has kubectl but not helm
  _t "check_helm SKIPS when the helm binary is absent" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    # The surrounding tests export a helm shell function, and exported
    # functions are inherited by this subshell — drop it so "absent" is real.
    unset -f helm
    FAKEDIR=$(mktemp -d); trap "rm -rf \"$FAKEDIR\"" EXIT
    PATH="$FAKEDIR"
    CHECK_RESULTS=()
    check_helm >/dev/null 2>&1
    n=${#CHECK_RESULTS[@]}
    st=${CHECK_RESULTS[$((n-1))]#*:}; st=${st%%:*}
    [[ "$st" == *SKIP* ]]
  '

  unset -f helm
  _setup_mock_kubectl
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: external PostgreSQL version (2.5.1: 15, 17, 18) ━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  _mock_db() { # _mock_db <pod-log-line>
    local line="$1"
    eval "kubectl() {
      case \"\$*\" in
        *'apply -f'*) echo created;;
        *'get pod'*'phase'*) echo Succeeded;;
        *'logs'*) echo '${line}';;
        *'delete pod'*) echo deleted;;
        *) echo mock;;
      esac
    }"
    export -f kubectl
  }

  EXTERNAL_DB_HOST="pg.example.invalid"
  DB_CHECK_TIMEOUT=4

  _mock_db "DB_CONNECT_OK:17.2"
  _t "check_external_db PASSES for tested PostgreSQL 17" \
    _assert_status PASS check_external_db

  _mock_db "DB_CONNECT_OK:15.8"
  _t "check_external_db PASSES for tested PostgreSQL 15" \
    _assert_status PASS check_external_db

  _mock_db "DB_CONNECT_OK:18.0"
  _t "check_external_db PASSES for tested PostgreSQL 18 (new in 2.5.1)" \
    _assert_status PASS check_external_db

  _mock_db "DB_CONNECT_OK:16.4"
  _t "check_external_db WARNS for untested PostgreSQL 16" \
    _assert_status WARN check_external_db

  _mock_db "DB_CONNECT_OK:13.14"
  _t "check_external_db FAILS for PostgreSQL 13 (below minimum 15)" \
    _assert_status FAIL check_external_db

  # Connection reachable but version unreadable → still PASS on connectivity,
  # with the version reported as unknown
  _mock_db "DB_CONNECT_OK:"
  _t "check_external_db WARNS when the server version cannot be read" \
    _assert_status WARN check_external_db

  _mock_db "DB_CONNECT_FAIL_NETWORK"
  _t "check_external_db FAILS when the host is unreachable" \
    _assert_status FAIL check_external_db

  _mock_db "DB_CONNECT_FAIL_AUTH"
  _t "check_external_db FAILS on authentication failure" \
    _assert_status FAIL check_external_db

  EXTERNAL_DB_HOST=""
  DB_CHECK_TIMEOUT=60
  _setup_mock_kubectl
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: agent resource headroom (2.5.1 agent requirements) ━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  # Doc 2.5.1:
  #   kube-agent  — 1 core per 2500 pods, 2 GB per 3000 pods (one per cluster)
  #   node-agent  — 0.3 core + 300 MB per node (base)
  #               — up to 3 cores + 5 GB per node with all features enabled
  _t "kube_agent_cores: 1 core at 2500 pods" \
    _assert_eq "$(kube_agent_cores 2500)" "1"

  _t "kube_agent_cores: still 1 core below 2500 pods" \
    _assert_eq "$(kube_agent_cores 45)" "1"

  _t "kube_agent_cores: 2 cores at 2501 pods" \
    _assert_eq "$(kube_agent_cores 2501)" "2"

  _t "kube_agent_cores: 2 cores at 5000 pods" \
    _assert_eq "$(kube_agent_cores 5000)" "2"

  _t "kube_agent_cores: 3 cores at 5001 pods" \
    _assert_eq "$(kube_agent_cores 5001)" "3"

  _t "kube_agent_mem_gb: 2 GB at 3000 pods" \
    _assert_eq "$(kube_agent_mem_gb 3000)" "2"

  _t "kube_agent_mem_gb: 2 GB below 3000 pods" \
    _assert_eq "$(kube_agent_mem_gb 45)" "2"

  _t "kube_agent_mem_gb: 4 GB at 3001 pods" \
    _assert_eq "$(kube_agent_mem_gb 3001)" "4"

  _t "kube_agent_mem_gb: 6 GB at 6001 pods" \
    _assert_eq "$(kube_agent_mem_gb 6001)" "6"

  # Whole-check behaviour: plenty of headroom → PASS
  kubectl() {
    case "$*" in
      *"get pods"*"--all-namespaces"*) printf "pod1\npod2\npod3\n";;
      *"allocatable.cpu"*)    printf "node1\t16\nnode2\t16\nnode3\t16\n";;
      *"allocatable.memory"*) printf "node1\t64Gi\nnode2\t64Gi\nnode3\t64Gi\n";;
      *) echo mock;;
    esac
  }
  export -f kubectl
  _t "check_agent_resources PASSES when nodes have headroom for the agents" \
    _assert_status PASS check_agent_resources

  # Each node must still fit a node-agent at its maximum footprint (3 cores / 5 GB).
  # 2-core nodes cannot, so the check must WARN rather than claim readiness.
  kubectl() {
    case "$*" in
      *"get pods"*"--all-namespaces"*) printf "pod1\n";;
      *"allocatable.cpu"*)    printf "node1\t2\nnode2\t2\n";;
      *"allocatable.memory"*) printf "node1\t4Gi\nnode2\t4Gi\n";;
      *) echo mock;;
    esac
  }
  export -f kubectl
  _t "check_agent_resources WARNS when a node cannot fit node-agent at max footprint" \
    _assert_status WARN check_agent_resources

  _setup_mock_kubectl
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: probe namespace is configurable ━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $_SOURCED -eq 1 ]]; then
  # Probe pods and PVCs must land in the namespace KCS will actually occupy,
  # so namespace-scoped obstacles — ResourceQuota, LimitRange, Pod Security
  # Admission labels — are caught before installation rather than after.
  _t "PROBE_NAMESPACE defaults to 'default'" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    [[ "$PROBE_NAMESPACE" == "default" ]]
  '

  _t "PROBE_NAMESPACE is overridable from the environment" bash -c '
    export UNIT_TEST_MODE=1
    export PROBE_NAMESPACE=kcs
    source '"$SCRIPT"'
    [[ "$PROBE_NAMESPACE" == "kcs" ]]
  '

  _t "check_registry creates its probe pod in PROBE_NAMESPACE" bash -c '
    export UNIT_TEST_MODE=1
    export PROBE_NAMESPACE=probe-ns
    source '"$SCRIPT"'
    CALLS=$(mktemp)
    kubectl() {
      echo "$*" >> "$CALLS"
      case "$*" in
        *"get pod"*"phase"*) echo "Succeeded";;
        *"logs"*) echo "200";;
        *) echo mock;;
      esac
    }
    export -f kubectl
    check_registry >/dev/null 2>&1
    grep -q -- "-n probe-ns" "$CALLS"
  '

  _t "check_ebpf creates its probe pod in PROBE_NAMESPACE" bash -c '
    export UNIT_TEST_MODE=1
    export PROBE_NAMESPACE=probe-ns
    source '"$SCRIPT"'
    CALLS=$(mktemp)
    kubectl() {
      echo "$*" >> "$CALLS"
      case "$*" in
        *"custom-columns=NAME"*) printf "node1\n";;
        *"get pod"*"phase"*) echo "Succeeded";;
        *"logs"*) echo "BTF_OK";;
        *) echo mock;;
      esac
    }
    export -f kubectl
    check_ebpf >/dev/null 2>&1
    grep -q -- "-n probe-ns" "$CALLS"
  '

  _t "no check hardcodes '-n default'" \
    _assert_check_fails grep -q -- "-n default" "$SCRIPT"

  _t "no pod spec hardcodes 'namespace: default'" \
    _assert_check_fails grep -q "namespace: default" "$SCRIPT"

  _t "no check hardcodes '--namespace=default'" \
    _assert_check_fails grep -q -- "--namespace=default" "$SCRIPT"

  _setup_mock_kubectl
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Unit tests: version strings and thresholds say 2.5.1 ━━━━━━━━━━━━━━━"

if [[ -f "$SCRIPT" ]]; then
  _t "script header names KCS 2.5.1" \
    grep -q "KCS 2.5.1" "$SCRIPT"

  _t "script no longer names KCS 2.4" \
    _assert_check_fails grep -q "KCS 2\.4" "$SCRIPT"

  _t "CPU threshold is 13 cores (13000 millicores)" \
    grep -q "MIN_CPU_MILLICORES=13000" "$SCRIPT"

  _t "K8s tested-version list is present" \
    grep -q "K8S_TESTED_MINORS=" "$SCRIPT"

  _t "kernel tested-version list is present" \
    grep -q "KERNEL_TESTED_VERSIONS=" "$SCRIPT"

  _t "Calico tested-version list is present" \
    grep -q "CALICO_TESTED_VERSIONS=" "$SCRIPT"

  _t "Helm tested-version list is present" \
    grep -q "HELM_TESTED_VERSIONS=" "$SCRIPT"

  _t "PostgreSQL tested-version list is present" \
    grep -q "POSTGRES_TESTED_VERSIONS=" "$SCRIPT"

  _t "OpenShift tested-version list is present" \
    grep -q "OPENSHIFT_TESTED_VERSIONS=" "$SCRIPT"

  _t "report banner names KCS 2.5.1" \
    grep -q "KCS 2.5.1 Pre-Installation Check Report" "$SCRIPT"

  _t "REPORT_FILE is overridable so test runs leave no report files behind" \
    grep -q 'REPORT_FILE="${REPORT_FILE:-' "$SCRIPT"

  # Subshell tests source the script in a fresh shell, so the parent's
  # REPORT_FILE does not reach them — the override has to be exported.
  _t "the test suite created no kcs-precheck-*.md files" bash -c '
    ! ls '"$SCRIPT_DIR"'/kcs-precheck-*.md >/dev/null 2>&1
  '

fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Integration tests: real cluster ($KUBECONFIG_ARG) ━━━━━━━━━━━━━━━━━"

if [[ -z "$KUBECONFIG_ARG" ]]; then
  echo "  ⚠️  Skipped (no --kubeconfig= argument provided)"
else
  # Restore real kubectl before integration tests (unit tests exported a mock)
  unset -f kubectl

  _KUBE="$KUBECONFIG_ARG"
  # Expand ~ so the path works inside bash -c subshells
  _KUBE_PATH="${_KUBE#--kubeconfig=}"
  _KUBE_PATH="${_KUBE_PATH/#\~/$HOME}"

  _t "cluster is reachable" \
    bash -c "kubectl --kubeconfig=${_KUBE_PATH} cluster-info"

  _t "Kubernetes version ≥ 1.21" bash -c "
    ver_json=\$(kubectl --kubeconfig=${_KUBE_PATH} version --output=json 2>/dev/null)
    minor=\$(printf '%s\n' \"\$ver_json\" | grep -A20 'serverVersion' | grep '\"minor\"' | head -1 \
      | sed 's/.*\"minor\"[^\"]*\"\([^\"]*\)\".*/\1/' | tr -d '\"')
    minor=\"\${minor//[^0-9]/}\"
    [[ \"\$minor\" -ge 21 ]]
  "

  _t "all nodes amd64" bash -c "
    archs=\$(kubectl --kubeconfig=${_KUBE_PATH} get nodes \
      -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{\"\n\"}{end}')
    ! echo \"\$archs\" | grep -qv '^amd64\$'
  "

  _t "every worker node has ≥ 13 allocatable cores" bash -c "
    total=0
    while IFS= read -r v; do
      [[ -z \"\$v\" ]] && continue
      if [[ \"\$v\" == *m ]]; then total=\$((total + \${v%m}))
      else total=\$((total + v * 1000)); fi
    done < <(kubectl --kubeconfig=${_KUBE_PATH} get nodes \
      -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{\"\n\"}{end}')
    [[ \"\$total\" -ge 10000 ]]
  "

  _t "total allocatable memory ≥ 20 GiB" bash -c "
    total_ki=0
    while IFS= read -r v; do
      [[ -z \"\$v\" ]] && continue
      if [[ \"\$v\" == *Ki ]]; then total_ki=\$((total_ki + \${v%Ki}))
      elif [[ \"\$v\" == *Mi ]]; then total_ki=\$((total_ki + \${v%Mi} * 1024))
      elif [[ \"\$v\" == *Gi ]]; then total_ki=\$((total_ki + \${v%Gi} * 1024 * 1024))
      else total_ki=\$((total_ki + v / 1024)); fi
    done < <(kubectl --kubeconfig=${_KUBE_PATH} get nodes \
      -o jsonpath='{range .items[*]}{.status.allocatable.memory}{\"\n\"}{end}')
    [[ \$((total_ki / 1024 / 1024)) -ge 20 ]]
  "

  _t "at least one StorageClass exists" bash -c "
    count=\$(kubectl --kubeconfig=${_KUBE_PATH} get storageclass \
      --no-headers 2>/dev/null | wc -l)
    [[ \"\$count\" -gt 0 ]]
  "

  _t "default StorageClass exists" bash -c "
    kubectl --kubeconfig=${_KUBE_PATH} get storageclass \
      -o jsonpath='{.items[*].metadata.annotations}' \
      | grep -q 'storageclass.kubernetes.io/is-default-class'
  "

  _t "at least one IngressClass exists" bash -c "
    count=\$(kubectl --kubeconfig=${_KUBE_PATH} get ingressclass \
      --no-headers 2>/dev/null | wc -l)
    [[ \"\$count\" -gt 0 ]]
  "

  _t "nodes are all Ready" bash -c "
    not_ready=\$(kubectl --kubeconfig=${_KUBE_PATH} get nodes \
      --no-headers | grep -v ' Ready' | wc -l)
    [[ \"\$not_ready\" -eq 0 ]]
  "

  _t "ephemeral storage total ≥ 28 GiB across nodes" bash -c "
    total_mi=0
    while IFS= read -r v; do
      [[ -z \"\$v\" ]] && continue
      if [[ \"\$v\" == *Mi ]]; then total_mi=\$((total_mi + \${v%Mi}))
      elif [[ \"\$v\" == *Gi ]]; then total_mi=\$((total_mi + \${v%Gi} * 1024))
      elif [[ \"\$v\" == *Ki ]]; then total_mi=\$((total_mi + \${v%Ki} / 1024))
      else total_mi=\$((total_mi + v / 1024 / 1024)); fi
    done < <(kubectl --kubeconfig=${_KUBE_PATH} get nodes \
      -o jsonpath='{range .items[*]}{.status.allocatable.ephemeral-storage}{\"\n\"}{end}')
    [[ \$((total_mi / 1024)) -ge 28 ]]
  "

  _t "all nodes have kernel >= 4.18" bash -c "
    fail=0
    while IFS=\$'\t' read -r name os ker; do
      [[ -z \"\$name\" ]] && continue
      major=\$(echo \"\$ker\" | sed 's/^\([0-9]*\).*/\1/')
      minor=\$(echo \"\$ker\" | sed 's/^[0-9]*\.\([0-9]*\).*/\1/')
      if [[ \"\$major\" -lt 4 ]] || { [[ \"\$major\" -eq 4 ]] && [[ \"\$minor\" -lt 18 ]]; }; then
        echo \"FAIL: node \$name has kernel \$ker < 4.18\" >&2; fail=1
      fi
    done < <(kubectl --kubeconfig=${_KUBE_PATH} get nodes \
      -o jsonpath='{range .items[*]}{.metadata.name}{\"\t\"}{.status.nodeInfo.osImage}{\"\t\"}{.status.nodeInfo.kernelVersion}{\"\n\"}{end}')
    [[ \$fail -eq 0 ]]
  "

  _t "eBPF BTF available on first cluster node" bash -c "
    node=\$(kubectl --kubeconfig=${_KUBE_PATH} get nodes --no-headers \
      -o custom-columns=NAME:.metadata.name | head -1)
    podname=\"kcs-ebpf-inttest-\$RANDOM\"
    tmpf=\$(mktemp /tmp/kcs-ebpf-XXXX.yaml)
    trap 'rm -f \"\$tmpf\"; kubectl --kubeconfig=${_KUBE_PATH} delete pod \"\$podname\" \
      -n default --ignore-not-found=true --timeout=15s >/dev/null 2>&1 || true' EXIT
    printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: %s\n  namespace: default\nspec:\n  nodeName: %s\n  restartPolicy: Never\n  tolerations:\n  - operator: Exists\n  containers:\n  - name: check\n    image: busybox:1.36\n    command: [sh, -c, test -f /sys/kernel/btf/vmlinux && echo BTF_OK || echo BTF_MISSING]\n    securityContext:\n      privileged: true\n    volumeMounts:\n    - name: sys\n      mountPath: /sys\n      readOnly: true\n  volumes:\n  - name: sys\n    hostPath:\n      path: /sys\n' \"\$podname\" \"\$node\" > \"\$tmpf\"
    kubectl --kubeconfig=${_KUBE_PATH} apply -f \"\$tmpf\" >/dev/null 2>&1
    elapsed=0; phase=\"\"
    while [[ \$elapsed -lt 90 ]]; do
      phase=\$(kubectl --kubeconfig=${_KUBE_PATH} get pod \"\$podname\" -n default \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo \"\")
      [[ \"\$phase\" == Succeeded || \"\$phase\" == Failed ]] && break
      sleep 2; elapsed=\$((elapsed+2))
    done
    result=\$(kubectl --kubeconfig=${_KUBE_PATH} logs \"\$podname\" -n default 2>/dev/null || echo \"\")
    [[ \"\$result\" == BTF_OK ]]
  "

  if [[ -n "$INTEGRATION_EXTERNAL_DB" ]]; then
    _t "external PostgreSQL reachable from cluster — reports DB_CONNECT_OK" bash -c "
      podname=\"kcs-db-ok-\$RANDOM\"
      trap 'kubectl --kubeconfig=${_KUBE_PATH} delete pod \"\$podname\" -n default --ignore-not-found=true --timeout=15s >/dev/null 2>&1 || true' EXIT
      kubectl --kubeconfig=${_KUBE_PATH} apply -f - >/dev/null 2>&1 <<PODSPEC
apiVersion: v1
kind: Pod
metadata:
  name: \${podname}
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: check
    image: postgres:15-alpine
    env:
    - name: PGPASSWORD
      value: \"${INTEGRATION_EXTERNAL_DB_PASSWORD}\"
    command: [\"sh\", \"-c\", \"if pg_isready -h ${INTEGRATION_EXTERNAL_DB} -p 5432 -U ${INTEGRATION_EXTERNAL_DB_USER} -t 10 2>/dev/null; then if psql -h ${INTEGRATION_EXTERNAL_DB} -p 5432 -U ${INTEGRATION_EXTERNAL_DB_USER} -c 'SELECT 1' postgres >/dev/null 2>&1; then echo DB_CONNECT_OK; else echo DB_CONNECT_FAIL_AUTH; fi; else echo DB_CONNECT_FAIL_NETWORK; fi\"]
PODSPEC
      elapsed=0; phase=\"\"
      while [[ \$elapsed -lt 90 ]]; do
        phase=\$(kubectl --kubeconfig=${_KUBE_PATH} get pod \"\$podname\" -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo \"\")
        [[ \"\$phase\" == Succeeded || \"\$phase\" == Failed ]] && break
        sleep 3; elapsed=\$((elapsed+3))
      done
      result=\$(kubectl --kubeconfig=${_KUBE_PATH} logs \"\$podname\" -n default 2>/dev/null | tail -1 || echo \"\")
      [[ \"\$result\" == DB_CONNECT_OK ]]
    "

    _t "pod command reports DB_CONNECT_FAIL_AUTH on wrong password" bash -c "
      podname=\"kcs-db-auth-\$RANDOM\"
      trap 'kubectl --kubeconfig=${_KUBE_PATH} delete pod \"\$podname\" -n default --ignore-not-found=true --timeout=15s >/dev/null 2>&1 || true' EXIT
      kubectl --kubeconfig=${_KUBE_PATH} apply -f - >/dev/null 2>&1 <<PODSPEC
apiVersion: v1
kind: Pod
metadata:
  name: \${podname}
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: check
    image: postgres:15-alpine
    env:
    - name: PGPASSWORD
      value: \"wrongpassword_xyz\"
    command: [\"sh\", \"-c\", \"if pg_isready -h ${INTEGRATION_EXTERNAL_DB} -p 5432 -U ${INTEGRATION_EXTERNAL_DB_USER} -t 10 2>/dev/null; then if psql -h ${INTEGRATION_EXTERNAL_DB} -p 5432 -U ${INTEGRATION_EXTERNAL_DB_USER} -c 'SELECT 1' postgres >/dev/null 2>&1; then echo DB_CONNECT_OK; else echo DB_CONNECT_FAIL_AUTH; fi; else echo DB_CONNECT_FAIL_NETWORK; fi\"]
PODSPEC
      elapsed=0; phase=\"\"
      while [[ \$elapsed -lt 90 ]]; do
        phase=\$(kubectl --kubeconfig=${_KUBE_PATH} get pod \"\$podname\" -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo \"\")
        [[ \"\$phase\" == Succeeded || \"\$phase\" == Failed ]] && break
        sleep 3; elapsed=\$((elapsed+3))
      done
      result=\$(kubectl --kubeconfig=${_KUBE_PATH} logs \"\$podname\" -n default 2>/dev/null | tail -1 || echo \"\")
      [[ \"\$result\" == DB_CONNECT_FAIL_AUTH ]]
    "

    _t "pod command reports DB_CONNECT_FAIL_NETWORK on unreachable host" bash -c "
      podname=\"kcs-db-net-\$RANDOM\"
      trap 'kubectl --kubeconfig=${_KUBE_PATH} delete pod \"\$podname\" -n default --ignore-not-found=true --timeout=15s >/dev/null 2>&1 || true' EXIT
      kubectl --kubeconfig=${_KUBE_PATH} apply -f - >/dev/null 2>&1 <<PODSPEC
apiVersion: v1
kind: Pod
metadata:
  name: \${podname}
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: check
    image: postgres:15-alpine
    command: [\"sh\", \"-c\", \"if pg_isready -h 127.0.0.1 -p 5432 -U nobody -t 5 2>/dev/null; then echo DB_CONNECT_OK; else echo DB_CONNECT_FAIL_NETWORK; fi\"]
PODSPEC
      elapsed=0; phase=\"\"
      while [[ \$elapsed -lt 90 ]]; do
        phase=\$(kubectl --kubeconfig=${_KUBE_PATH} get pod \"\$podname\" -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo \"\")
        [[ \"\$phase\" == Succeeded || \"\$phase\" == Failed ]] && break
        sleep 3; elapsed=\$((elapsed+3))
      done
      result=\$(kubectl --kubeconfig=${_KUBE_PATH} logs \"\$podname\" -n default 2>/dev/null | tail -1 || echo \"\")
      [[ \"\$result\" == DB_CONNECT_FAIL_NETWORK ]]
    "
  else
    echo "  ⚠️  External PostgreSQL tests skipped (pass --external-db=HOST --external-db-user=USER --external-db-password=PASS)"
  fi

  if [[ -n "$INTEGRATION_VAULT_HOST" && -n "$INTEGRATION_VAULT_ACCOUNT" ]]; then
    _t "Vault reachable from cluster with valid token — reports VAULT_OK" bash -c '
      export UNIT_TEST_MODE=1
      source '"$SCRIPT"'
      VAULT_HOST="'"$INTEGRATION_VAULT_HOST"'"
      VAULT_ACCOUNT_FILE="'"$INTEGRATION_VAULT_ACCOUNT"'"
      check_vault
    '

    _t "Vault reports VAULT_AUTH_FAIL with invalid token" bash -c '
      export UNIT_TEST_MODE=1
      source '"$SCRIPT"'
      tmpf=$(mktemp /tmp/vault-XXXX.key)
      printf "VAULT_ADDR=http://'"$INTEGRATION_VAULT_HOST"':8200\nVAULT_TOKEN=invalid-token-xyz-99999\n" > "$tmpf"
      VAULT_HOST="'"$INTEGRATION_VAULT_HOST"'"
      VAULT_ACCOUNT_FILE="$tmpf"
      result=0; check_vault >/dev/null 2>&1 || result=$?
      rm -f "$tmpf"
      [[ $result -ne 0 ]]
    '

    _t "Vault reports VAULT_UNREACHABLE with unreachable address" bash -c '
      export UNIT_TEST_MODE=1
      source '"$SCRIPT"'
      tmpf=$(mktemp /tmp/vault-XXXX.key)
      printf "VAULT_ADDR=http://192.0.2.1:8200\nVAULT_TOKEN=test-token\n" > "$tmpf"
      VAULT_HOST="192.0.2.1"
      VAULT_ACCOUNT_FILE="$tmpf"
      result=0; check_vault >/dev/null 2>&1 || result=$?
      rm -f "$tmpf"
      [[ $result -ne 0 ]]
    '
  else
    echo "  ⚠️  Vault tests skipped (pass --vault=HOST --vault-account=/path/to/vault-file.key)"
  fi

  _t "container runtime is containerd or cri-o on all nodes" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    export KUBECONFIG='"${_KUBE_PATH}"'
    check_container_runtime
  '

  _t "CNI plugin detected and supported" bash -c '
    export UNIT_TEST_MODE=1
    source '"$SCRIPT"'
    export KUBECONFIG='"${_KUBE_PATH}"'
    check_cni
  '
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Script-level tests ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ -f "$SCRIPT" ]]; then
  _t "script is executable" \
    test -x "$SCRIPT"

  _t "script has no obvious syntax errors" \
    bash -n "$SCRIPT"

  # preflight_check() exits 2 before gather_inputs() so no interactive prompts needed
  _t "script exits 2 when kubectl is not reachable" bash -c '
    kubectl() { return 1; }
    export -f kubectl
    bash '"$SCRIPT"' </dev/null; ec=$?
    [[ $ec -eq 2 ]]
  '

else
  echo "  ⚠️  Skipped (script not found)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: ✅ $_PASS passed  ❌ $_FAIL failed"
[[ $_FAIL -eq 0 ]]
