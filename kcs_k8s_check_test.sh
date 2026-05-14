#!/usr/bin/env bash
# TDD test suite for kcs_k8s_check.sh
# Run: bash kcs_k8s_check_test.sh [--kubeconfig=<path>]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/kcs_k8s_check.sh"
KUBECONFIG_ARG="${1:-}"

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
        # version
        *"version --output=json"*)
          echo '{"serverVersion":{"major":"1","minor":"31","gitVersion":"v1.31.2"}}';;
        # nodes arch
        *"nodeInfo.architecture"*)
          printf "amd64\namd64\namd64\namd64\n";;
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
      *"version --output=json"*)
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
    minor=\$(kubectl --kubeconfig=${_KUBE_PATH} version --output=json \
      | python3 -c \"import sys,json; v=json.load(sys.stdin)['serverVersion']; print(v['minor'].rstrip('+'))\")
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
