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

for _arg in "$@"; do
  case "$_arg" in
    --kubeconfig=*) KUBECONFIG_ARG="$_arg";;
    --external-db=*) INTEGRATION_EXTERNAL_DB="${_arg#*=}";;
    --external-db-user=*) INTEGRATION_EXTERNAL_DB_USER="${_arg#*=}";;
    --external-db-password=*) INTEGRATION_EXTERNAL_DB_PASSWORD="${_arg#*=}";;
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
        # CPU allocatable
        *"allocatable.cpu"*)
          printf "4\n16\n16\n16\n";;
        # memory allocatable
        *"allocatable.memory"*)
          printf "7891148Ki\n32626916Ki\n32626888Ki\n32626884Ki\n";;
        # ephemeral storage
        *"ephemeral-storage"*)
          printf "30706Mi\n66546Mi\n66546Mi\n66546Mi\n";;
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

  _t "check_cpu passes when total ≥ 10 cores (mock: 52 cores)" \
    check_cpu

  _t "check_memory passes when total ≥ 20 GiB (mock: ~102 GiB)" \
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
  _assert_check_fails() {
    # Returns success when the check function returns non-zero
    "$@" && return 1 || return 0
  }

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

  # Insufficient CPU (only 4 cores total)
  kubectl() {
    case "$*" in
      *"allocatable.cpu"*) printf "4\n";;
      *) echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_cpu FAILS when total < 10 cores (mock: 4 cores)" \
    _assert_check_fails check_cpu

  # Insufficient memory (only 8 GiB total)
  kubectl() {
    case "$*" in
      *"allocatable.memory"*) printf "8192Mi\n";;
      *) echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_memory FAILS when total < 20 GiB (mock: 8 GiB)" \
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
  _t "check_os_kernel passes when all nodes have kernel >= 5.8" \
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
  _t "check_os_kernel passes (with warn) when kernel >= 4.18 but < 5.8" \
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

  # check_external_db FAIL case — mock pod reports authentication failure
  kubectl() {
    case "$*" in
      *"apply -f"*)                          echo "pod/kcs-precheck-db created";;
      *"get pod"*"kcs-precheck-db"*)         echo "Succeeded";;
      *"logs"*"kcs-precheck-db"*)            echo "DB_CONNECT_FAIL";;
      *"delete pod"*)                        echo "pod deleted";;
      *)                                     echo "mock";;
    esac
  }
  export -f kubectl
  _t "check_external_db FAILS when pod reports DB_CONNECT_FAIL" \
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

  _t "total allocatable CPU ≥ 10 cores" bash -c "
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
    _t "external PostgreSQL reachable from cluster (pg_isready + psql SELECT 1)" bash -c "
      podname=\"kcs-db-inttest-\$RANDOM\"
      trap 'kubectl --kubeconfig=${_KUBE_PATH} delete pod \"\$podname\" \
        -n default --ignore-not-found=true --timeout=15s >/dev/null 2>&1 || true' EXIT
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
    command: [\"sh\", \"-c\", \"pg_isready -h ${INTEGRATION_EXTERNAL_DB} -p 5432 -U ${INTEGRATION_EXTERNAL_DB_USER} -t 10 2>/dev/null && psql -h ${INTEGRATION_EXTERNAL_DB} -p 5432 -U ${INTEGRATION_EXTERNAL_DB_USER} -c 'SELECT 1' postgres >/dev/null 2>&1 && echo DB_CONNECT_OK || echo DB_CONNECT_FAIL\"]
PODSPEC
      elapsed=0; phase=\"\"
      while [[ \$elapsed -lt 90 ]]; do
        phase=\$(kubectl --kubeconfig=${_KUBE_PATH} get pod \"\$podname\" -n default \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo \"\")
        [[ \"\$phase\" == Succeeded || \"\$phase\" == Failed ]] && break
        sleep 3; elapsed=\$((elapsed+3))
      done
      result=\$(kubectl --kubeconfig=${_KUBE_PATH} logs \"\$podname\" -n default 2>/dev/null | tail -1 || echo \"\")
      [[ \"\$result\" == DB_CONNECT_OK ]]
    "
  else
    echo "  ⚠️  External PostgreSQL test skipped (pass --external-db=HOST --external-db-user=USER --external-db-password=PASS)"
  fi
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
