#!/usr/bin/env bash
# KCS 2.4 pre-installation checker — read-only, kubectl-based
# Exit 0 = all pass | Exit 1 = at least one FAIL | Exit 2 = kubectl unreachable
set -uo pipefail

# ── constants ────────────────────────────────────────────────────────────────
readonly MIN_K8S_MINOR=21
readonly MIN_CPU_MILLICORES=10000    # 10 cores
readonly MIN_MEM_MIB=20480           # 20 GiB
readonly MIN_EPHEMERAL_MIB=28672     # 28 GiB
readonly PVC_BIND_TIMEOUT=30
readonly POD_POLL_TIMEOUT=60
readonly POD_PENDING_WARN_SEC=20
readonly MIN_KERNEL_MAJOR=4          # kernel >= 4.18 required
readonly MIN_KERNEL_MINOR=18
readonly WARN_KERNEL_MAJOR=5         # kernel < 5.8 needs kcs-ih privileged mode
readonly WARN_KERNEL_MINOR=8

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="kcs-precheck-${TIMESTAMP}.md"

# ── env vars (overridable for non-interactive / CI use) ──────────────────────
TARGET_NAMESPACE="${TARGET_NAMESPACE:-kcs}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
DOMAIN="${DOMAIN:-}"
INGRESS_CLASS="${INGRESS_CLASS:-}"
REGISTRY_TEST_IMAGE="${REGISTRY_TEST_IMAGE:-curlimages/curl:latest}"
SKIP_DNS_CHECK="${SKIP_DNS_CHECK:-}"
SKIP_REGISTRY_CHECK="${SKIP_REGISTRY_CHECK:-}"

EXTERNAL_DB_HOST="${EXTERNAL_DB_HOST:-}"
EXTERNAL_DB_USER="${EXTERNAL_DB_USER:-postgres}"
EXTERNAL_DB_PASSWORD="${EXTERNAL_DB_PASSWORD:-}"
EXTERNAL_DB_PORT="${EXTERNAL_DB_PORT:-5432}"
DB_CHECK_TIMEOUT="${DB_CHECK_TIMEOUT:-60}"

# Filled by cleanup() trap
CLEANUP_NAMESPACE=""
CLEANUP_PVC_NAME=""
CLEANUP_POD_NAME=""

# CHECK_RESULTS array: "CHECK_LABEL:STATUS:DETAIL"
declare -a CHECK_RESULTS=()

# ── colours ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  _RED='\033[0;31m'; _GREEN='\033[0;32m'; _YELLOW='\033[1;33m'
  _CYAN='\033[0;36m'; _BOLD='\033[1m'; _RESET='\033[0m'
else
  _RED=''; _GREEN=''; _YELLOW=''; _CYAN=''; _BOLD=''; _RESET=''
fi

print_pass()   { echo -e "${_GREEN}  ✅ PASS${_RESET}  $*"; }
print_fail()   { echo -e "${_RED}  ❌ FAIL${_RESET}  $*"; }
print_warn()   { echo -e "${_YELLOW}  ⚠️  WARN${_RESET}  $*"; }
print_info()   { echo -e "${_CYAN}  ℹ️  ${_RESET}$*"; }
print_header() { echo -e "\n${_BOLD}━━━ $* ━━━${_RESET}"; }

# ── report helpers ───────────────────────────────────────────────────────────
append_report() { echo "$*" >> "$REPORT_FILE"; }

init_report() {
  cat > "$REPORT_FILE" <<HEADER
# KCS 2.4 Pre-Installation Check Report

**Generated:** $(date)
**Cluster context:** $(kubectl config current-context 2>/dev/null || echo "unknown")
**Target namespace:** ${TARGET_NAMESPACE}
**Storage class:** ${STORAGE_CLASS:-"(cluster default)"}
**Domain:** ${DOMAIN:-"(skipped)"}

---
HEADER
}

record_result() {
  local label="$1" status="$2" detail="$3"
  CHECK_RESULTS+=("${label}:${status}:${detail}")
  append_report ""
  append_report "## ${label}"
  append_report ""
  append_report "**Status:** ${status}"
  append_report ""
  append_report "${detail}"
  append_report ""
  append_report "---"
}

# ── cleanup trap ─────────────────────────────────────────────────────────────
cleanup() {
  local ns="${CLEANUP_NAMESPACE:-default}"
  if [[ -n "${CLEANUP_PVC_NAME:-}" ]]; then
    kubectl delete pvc "$CLEANUP_PVC_NAME" -n "$ns" --ignore-not-found=true \
      --timeout=15s >/dev/null 2>&1 || true
  fi
  if [[ -n "${CLEANUP_POD_NAME:-}" ]]; then
    kubectl delete pod "$CLEANUP_POD_NAME" -n "$ns" --ignore-not-found=true \
      --timeout=15s >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ── normalization helpers ─────────────────────────────────────────────────────
# Exported so tests can source and call them directly.
normalize_cpu() {
  local v="$1"
  if [[ "$v" == *m ]]; then
    echo "${v%m}"
  else
    echo $(( v * 1000 ))
  fi
}
export -f normalize_cpu

normalize_mem_mib() {
  local v="$1"
  if [[ "$v" == *Ki ]]; then
    echo $(( ${v%Ki} / 1024 ))
  elif [[ "$v" == *Mi ]]; then
    echo "${v%Mi}"
  elif [[ "$v" == *Gi ]]; then
    echo $(( ${v%Gi} * 1024 ))
  else
    # raw bytes
    echo $(( v / 1024 / 1024 ))
  fi
}
export -f normalize_mem_mib

normalize_ephemeral_mib() {
  local v="$1"
  if [[ "$v" == *Mi ]]; then
    echo "${v%Mi}"
  elif [[ "$v" == *Gi ]]; then
    echo $(( ${v%Gi} * 1024 ))
  elif [[ "$v" == *Ki ]]; then
    echo $(( ${v%Ki} / 1024 ))
  else
    echo $(( v / 1024 / 1024 ))
  fi
}
export -f normalize_ephemeral_mib

# parse_kernel_version "5.15.0-91-generic" → prints "5 15" (major minor)
parse_kernel_version() {
  local ver="$1"
  local major minor
  major=$(echo "$ver" | sed 's/^\([0-9]*\).*/\1/')
  minor=$(echo "$ver" | sed 's/^[0-9]*\.\([0-9]*\).*/\1/')
  echo "$major $minor"
}
export -f parse_kernel_version

# kernel_ge "5.15.0-91-generic" 4 18 → returns 0 if kernel >= major.minor
kernel_ge() {
  local ver="$1" req_major="$2" req_minor="$3"
  local kv k_major k_minor
  kv=$(parse_kernel_version "$ver")
  k_major="${kv% *}"
  k_minor="${kv#* }"
  if [[ "$k_major" -gt "$req_major" ]]; then return 0
  elif [[ "$k_major" -eq "$req_major" ]] && [[ "$k_minor" -ge "$req_minor" ]]; then return 0
  else return 1; fi
}
export -f kernel_ge

# ── preflight ────────────────────────────────────────────────────────────────
preflight_check() {
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo -e "${_RED}FATAL: kubectl cannot reach the cluster. Check kubeconfig / context.${_RESET}" >&2
    exit 2
  fi
}

# ── interactive inputs ────────────────────────────────────────────────────────
gather_inputs() {
  if [[ -z "$TARGET_NAMESPACE" ]]; then
    read -rp "  Target namespace for KCS [kcs]: " TARGET_NAMESPACE
    TARGET_NAMESPACE="${TARGET_NAMESPACE:-kcs}"
  fi

  if [[ -z "$STORAGE_CLASS" ]]; then
    print_info "Available StorageClasses:"
    kubectl get storageclass --no-headers 2>/dev/null \
      | awk '{print "    " $1}' || true
    read -rp "  StorageClass to test (leave blank = cluster default): " STORAGE_CLASS
  fi

  if [[ -z "$DOMAIN" ]] && [[ -z "$SKIP_DNS_CHECK" ]]; then
    read -rp "  KCS domain to verify (leave blank to skip DNS check): " DOMAIN
  fi

  if [[ -z "$INGRESS_CLASS" ]]; then
    read -rp "  Expected IngressClass name (leave blank = any): " INGRESS_CLASS
  fi
}

# ── CLI argument parsing ──────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --external-db)
        EXTERNAL_DB_HOST="$2"; shift 2;;
      --external-db-user)
        EXTERNAL_DB_USER="$2"; shift 2;;
      --external-db-password)
        EXTERNAL_DB_PASSWORD="$2"; shift 2;;
      *)
        echo "Unknown option: $1" >&2
        echo "Usage: $0 [--external-db HOST] [--external-db-user USER] [--external-db-password PASS]" >&2
        exit 1;;
    esac
  done
}
export -f parse_args

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK A — Kubernetes version
# ═══════════════════════════════════════════════════════════════════════════════
check_k8s_version() {
  print_header "A. Kubernetes version"

  local minor arch_list fail=0 detail=""
  local major minor_raw ver_json

  ver_json=$(kubectl version --output=json 2>/dev/null) || true
  # Parse serverVersion from JSON using grep+sed — no python3 required
  major=$(printf '%s\n' "$ver_json" | grep -A20 '"serverVersion"' | grep '"major"' | head -1 \
    | sed 's/[^0-9]*\([0-9]*\).*/\1/')
  minor_raw=$(printf '%s\n' "$ver_json" | grep -A20 '"serverVersion"' | grep '"minor"' | head -1 \
    | sed 's/.*"minor"[^"]*"\([^"]*\)".*/\1/')
  [[ -z "$major" ]]     && major="?"
  [[ -z "$minor_raw" ]] && minor_raw="?"
  # strip non-numeric suffix ("28+" → "28")
  minor="${minor_raw//[^0-9]/}"

  detail+="**Server version:** ${major}.${minor_raw}\n"

  if [[ "$major" != "1" ]] || [[ -z "$minor" ]] || [[ "$minor" -lt "$MIN_K8S_MINOR" ]]; then
    print_fail "Server version ${major}.${minor} — minimum 1.${MIN_K8S_MINOR} required"
    detail+="**Result:** FAIL — version below minimum (1.${MIN_K8S_MINOR})\n"
    fail=1
  else
    print_pass "Server version ${major}.${minor} ≥ 1.${MIN_K8S_MINOR}"
    detail+="**Result:** PASS\n"
  fi

  # architecture check
  arch_list=$(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' 2>/dev/null)
  detail+="\n**Node architectures:**\n\`\`\`\n${arch_list}\n\`\`\`\n"

  local non_amd64
  non_amd64=$(echo "$arch_list" | grep -v "^amd64$" | grep -v "^$" || true)
  if [[ -n "$non_amd64" ]]; then
    print_warn "Non-amd64 nodes found: ${non_amd64} — KCS requires x86_64 (amd64)"
    detail+="**Architecture:** WARN — non-amd64 nodes detected\n"
    fail=1
  else
    print_pass "All nodes are amd64"
    detail+="**Architecture:** PASS — all nodes amd64\n"
  fi

  if [[ $fail -eq 0 ]]; then
    record_result "A. Kubernetes version" "✅ PASS" "$detail"
    return 0
  else
    record_result "A. Kubernetes version" "❌ FAIL" "$detail"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK B — CPU capacity
# ═══════════════════════════════════════════════════════════════════════════════
check_cpu() {
  print_header "B. CPU capacity"

  local total_mc=0 raw_values detail=""

  raw_values=$(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\n"}{end}' 2>/dev/null)

  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    total_mc=$(( total_mc + $(normalize_cpu "$v") ))
  done <<< "$raw_values"

  local total_cores=$(( total_mc / 1000 ))
  detail="**Allocatable CPU per node:**\n\`\`\`\n${raw_values}\n\`\`\`\n"
  detail+="**Total:** ${total_mc} millicores (${total_cores} cores)\n"
  detail+="**Threshold:** ≥ ${MIN_CPU_MILLICORES} millicores ($(( MIN_CPU_MILLICORES / 1000 )) cores)\n"

  if [[ "$total_mc" -ge "$MIN_CPU_MILLICORES" ]]; then
    print_pass "Total CPU: ${total_cores} cores (${total_mc}m) ≥ $(( MIN_CPU_MILLICORES / 1000 )) cores"
    record_result "B. CPU capacity" "✅ PASS" "$detail"
    return 0
  else
    print_fail "Total CPU: ${total_cores} cores — minimum $(( MIN_CPU_MILLICORES / 1000 )) cores required"
    detail+="**Result:** FAIL\n"
    record_result "B. CPU capacity" "❌ FAIL" "$detail"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK C — Memory capacity
# ═══════════════════════════════════════════════════════════════════════════════
check_memory() {
  print_header "C. Memory capacity"

  local total_ki=0 raw_values detail=""

  raw_values=$(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null)

  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    local mib
    mib=$(normalize_mem_mib "$v")
    total_ki=$(( total_ki + mib * 1024 ))
  done <<< "$raw_values"

  local total_mib=$(( total_ki / 1024 ))
  local total_gib=$(( total_mib / 1024 ))

  detail="**Allocatable memory per node:**\n\`\`\`\n${raw_values}\n\`\`\`\n"
  detail+="**Total:** ${total_mib} MiB (~${total_gib} GiB)\n"
  detail+="**Threshold:** ≥ ${MIN_MEM_MIB} MiB ($(( MIN_MEM_MIB / 1024 )) GiB)\n"

  if [[ "$total_mib" -ge "$MIN_MEM_MIB" ]]; then
    print_pass "Total memory: ${total_gib} GiB (${total_mib} MiB) ≥ $(( MIN_MEM_MIB / 1024 )) GiB"
    record_result "C. Memory capacity" "✅ PASS" "$detail"
    return 0
  else
    print_fail "Total memory: ${total_gib} GiB — minimum $(( MIN_MEM_MIB / 1024 )) GiB required"
    detail+="**Result:** FAIL\n"
    record_result "C. Memory capacity" "❌ FAIL" "$detail"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK D — Storage
# ═══════════════════════════════════════════════════════════════════════════════
check_storage() {
  print_header "D. Storage"

  local fail=0 detail=""

  # D1: StorageClass
  local sc_list default_sc
  sc_list=$(kubectl get storageclass --no-headers 2>/dev/null || echo "")
  default_sc=$(echo "$sc_list" | grep "(default)" | awk '{print $1}' || true)

  detail+="**StorageClasses:**\n\`\`\`\n${sc_list}\n\`\`\`\n"

  if [[ -z "$STORAGE_CLASS" ]]; then
    if [[ -z "$default_sc" ]]; then
      print_fail "No default StorageClass found and none specified"
      detail+="**D1 StorageClass:** FAIL — no default SC\n"
      fail=1
    else
      print_pass "Default StorageClass: ${default_sc}"
      STORAGE_CLASS="$default_sc"
      detail+="**D1 StorageClass:** PASS — default: ${default_sc}\n"
    fi
  else
    if echo "$sc_list" | grep -q "^${STORAGE_CLASS}"; then
      print_pass "StorageClass '${STORAGE_CLASS}' found"
      detail+="**D1 StorageClass:** PASS — '${STORAGE_CLASS}' exists\n"
    else
      print_fail "StorageClass '${STORAGE_CLASS}' not found"
      detail+="**D1 StorageClass:** FAIL — '${STORAGE_CLASS}' missing\n"
      fail=1
    fi
  fi

  # D2: Ephemeral storage
  local total_eph_mi=0 eph_values
  eph_values=$(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.status.allocatable.ephemeral-storage}{"\n"}{end}' 2>/dev/null)

  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    total_eph_mi=$(( total_eph_mi + $(normalize_ephemeral_mib "$v") ))
  done <<< "$eph_values"

  local total_eph_gib=$(( total_eph_mi / 1024 ))
  detail+="\n**Ephemeral storage per node:**\n\`\`\`\n${eph_values}\n\`\`\`\n"
  detail+="**Total ephemeral:** ${total_eph_mi} MiB (~${total_eph_gib} GiB)\n"
  detail+="**Threshold:** ≥ $(( MIN_EPHEMERAL_MIB / 1024 )) GiB\n"

  if [[ "$total_eph_mi" -ge "$MIN_EPHEMERAL_MIB" ]]; then
    print_pass "Ephemeral storage: ${total_eph_gib} GiB ≥ $(( MIN_EPHEMERAL_MIB / 1024 )) GiB"
    detail+="**D2 Ephemeral:** PASS\n"
  else
    print_fail "Ephemeral storage: ${total_eph_gib} GiB — minimum $(( MIN_EPHEMERAL_MIB / 1024 )) GiB required"
    detail+="**D2 Ephemeral:** FAIL\n"
    fail=1
  fi

  # D3: Test PVC bind
  local pvc_name="kcs-precheck-test-pvc-${RANDOM}"
  CLEANUP_NAMESPACE="default"
  CLEANUP_PVC_NAME="$pvc_name"
  local sc_field=""
  [[ -n "$STORAGE_CLASS" ]] && sc_field="  storageClassName: ${STORAGE_CLASS}"

  # WaitForFirstConsumer SCs don't bind until a consumer pod is scheduled
  local binding_mode=""
  if [[ -n "$STORAGE_CLASS" ]]; then
    binding_mode=$(kubectl get storageclass "$STORAGE_CLASS" \
      -o jsonpath='{.volumeBindingMode}' 2>/dev/null || echo "")
  fi
  detail+="\n**StorageClass binding mode:** ${binding_mode:-Immediate}\n"

  print_info "Creating test PVC '${pvc_name}' in namespace 'default'..."
  kubectl apply -f - >/dev/null 2>&1 <<PVCYAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
${sc_field}
PVCYAML

  local pvc_consumer_pod=""
  local pvc_timeout=$PVC_BIND_TIMEOUT
  if [[ "$binding_mode" == "WaitForFirstConsumer" ]]; then
    pvc_consumer_pod="kcs-precheck-pvc-pod-${RANDOM}"
    pvc_timeout=$POD_POLL_TIMEOUT
    print_info "StorageClass uses WaitForFirstConsumer — creating consumer pod '${pvc_consumer_pod}'..."
    kubectl apply -f - >/dev/null 2>&1 <<PODSPEC
apiVersion: v1
kind: Pod
metadata:
  name: ${pvc_consumer_pod}
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: pvc-test
    image: busybox:1.36
    command: ["sh", "-c", "true"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ${pvc_name}
PODSPEC
  fi

  local bound=0 elapsed=0
  while [[ $elapsed -lt $pvc_timeout ]]; do
    local phase
    phase=$(kubectl get pvc "$pvc_name" -n default \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$phase" == "Bound" ]]; then
      bound=1; break
    fi
    sleep 2; elapsed=$(( elapsed + 2 ))
  done

  # Consumer pod cleanup is handled inline — CLEANUP_POD_NAME is reserved for check_registry
  if [[ -n "$pvc_consumer_pod" ]]; then
    kubectl delete pod "$pvc_consumer_pod" -n default \
      --ignore-not-found=true --timeout=15s >/dev/null 2>&1 || true
  fi

  if [[ $bound -eq 1 ]]; then
    print_pass "Test PVC bound (StorageClass '${STORAGE_CLASS:-default}')"
    detail+="\n**D3 PVC bind test:** PASS\n"
  else
    print_fail "Test PVC did not bind within ${pvc_timeout}s"
    detail+="\n**D3 PVC bind test:** FAIL — PVC stuck pending after ${pvc_timeout}s\n"
    fail=1
  fi

  # worker count warning for ClickHouse cold PVC
  local worker_count
  worker_count=$(kubectl get nodes --no-headers 2>/dev/null \
    | grep -c "worker" || true)
  if [[ "$worker_count" -gt 40 ]]; then
    print_warn "Worker node count (${worker_count}) > 40 — verify ClickHouse cold PVC size ≥ worker count"
    detail+="\n**ClickHouse cold PVC:** WARN — ${worker_count} workers, ensure pvc-clickhouse-cold ≥ ${worker_count}Gi\n"
  fi

  if [[ $fail -eq 0 ]]; then
    record_result "D. Storage" "✅ PASS" "$detail"
    return 0
  else
    record_result "D. Storage" "❌ FAIL" "$detail"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK E — Ingress controller
# ═══════════════════════════════════════════════════════════════════════════════
check_ingress() {
  print_header "E. Ingress controller"

  local fail=0 detail=""

  local ic_list
  ic_list=$(kubectl get ingressclass --no-headers 2>/dev/null || echo "")
  detail+="**IngressClasses:**\n\`\`\`\n${ic_list}\n\`\`\`\n"

  if [[ -z "$ic_list" ]]; then
    print_fail "No IngressClass resources found"
    detail+="**Result:** FAIL — no IngressClass\n"
    record_result "E. Ingress controller" "❌ FAIL" "$detail"
    return 1
  fi

  print_pass "IngressClass(es) found: $(echo "$ic_list" | awk '{print $1}' | tr '\n' ' ')"
  detail+="**IngressClass:** PASS\n"

  # Check for running controller pods
  local found_pods=0
  for ns in ingress-nginx kube-system app-routing-system; do
    local pods
    pods=$(kubectl get pods -n "$ns" \
      -l 'app.kubernetes.io/name=ingress-nginx' \
      --no-headers 2>/dev/null | grep -c "Running" || true)
    if [[ "$pods" -gt 0 ]]; then
      print_pass "Ingress controller pods running in namespace '${ns}' (${pods} pod(s))"
      detail+="**Controller pods (${ns}):** ${pods} Running\n"
      found_pods=1
    fi
  done

  if [[ $found_pods -eq 0 ]]; then
    print_warn "No ingress-nginx controller pods found in standard namespaces"
    detail+="**Controller pods:** WARN — none found in ingress-nginx/kube-system/app-routing-system\n"
    # Warn but don't fail — controller might use different labels
  fi

  record_result "E. Ingress controller" "✅ PASS" "$detail"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK F — DNS domain
# ═══════════════════════════════════════════════════════════════════════════════
check_dns() {
  print_header "F. DNS domain"

  if [[ -z "$DOMAIN" ]]; then
    print_info "DNS check skipped (no domain configured)"
    record_result "F. DNS domain" "⚠️ SKIP" "Domain not provided — check skipped."
    return 0
  fi

  local detail="" resolved_ip=""

  # Collect ALL LoadBalancer IPs — using head -1 would pick the wrong service
  # when multiple LB services exist (e.g. ingress + mailhog)
  local all_lb_ips
  all_lb_ips=$(kubectl get svc -A \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' \
    2>/dev/null | grep -v "^$" | sort -u || true)

  if [[ -z "$all_lb_ips" ]]; then
    # No direct IPs — try to resolve LB hostnames (e.g. AWS ELB)
    local lb_hosts
    lb_hosts=$(kubectl get svc -A \
      -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].hostname}{"\n"}{end}' \
      2>/dev/null | grep -v "^$" || true)
    if [[ -n "$lb_hosts" ]]; then
      while IFS= read -r h; do
        local resolved=""
        if command -v dig >/dev/null 2>&1; then
          resolved=$(dig +short "$h" | grep -E '^[0-9]+\.' | head -1 || true)
        elif command -v nslookup >/dev/null 2>&1; then
          resolved=$(nslookup "$h" 2>/dev/null | awk '/^Address: /{print $2}' | head -1 || true)
        fi
        [[ -n "$resolved" ]] && all_lb_ips+="${resolved}"$'\n'
      done <<< "$lb_hosts"
    fi
  fi

  detail+="**Cluster LB IPs:** $(echo "$all_lb_ips" | grep -v "^$" | tr '\n' ' ' || echo 'none')\n"

  # Resolve domain
  if command -v dig >/dev/null 2>&1; then
    resolved_ip=$(dig +short "$DOMAIN" | grep -E '^[0-9]+\.' | head -1 || true)
  elif command -v nslookup >/dev/null 2>&1; then
    resolved_ip=$(nslookup "$DOMAIN" 2>/dev/null \
      | awk '/^Address: /{print $2}' | head -1 || true)
  fi

  detail+="**Domain:** ${DOMAIN}\n"
  detail+="**Resolved IP:** ${resolved_ip:-unresolved}\n"

  if [[ -z "$resolved_ip" ]]; then
    print_warn "Domain '${DOMAIN}' does not resolve — DNS may not be configured yet"
    record_result "F. DNS domain" "⚠️ WARN" "$detail"
    return 0
  fi

  if [[ -n "$all_lb_ips" ]] && ! echo "$all_lb_ips" | grep -qFx "$resolved_ip"; then
    print_warn "Domain '${DOMAIN}' resolves to ${resolved_ip} but doesn't match any cluster LB IP ($(echo "$all_lb_ips" | grep -v "^$" | tr '\n' ' '))"
    detail+="**Match:** WARN — ${resolved_ip} not among cluster LB IPs\n"
    record_result "F. DNS domain" "⚠️ WARN" "$detail"
  else
    print_pass "Domain '${DOMAIN}' resolves to ${resolved_ip}"
    detail+="**Match:** PASS\n"
    record_result "F. DNS domain" "✅ PASS" "$detail"
  fi
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK G — Registry reachability
# ═══════════════════════════════════════════════════════════════════════════════
check_registry() {
  print_header "G. Registry reachability"

  local pod_name="kcs-precheck-reg-${RANDOM}"
  CLEANUP_NAMESPACE="default"
  CLEANUP_POD_NAME="$pod_name"
  local detail="" fail=0

  print_info "Launching test pod '${pod_name}' with image '${REGISTRY_TEST_IMAGE}'..."

  kubectl run "$pod_name" \
    --image="$REGISTRY_TEST_IMAGE" \
    --restart=Never \
    --namespace=default \
    --overrides='{
      "spec": {
        "securityContext": {"runAsNonRoot": true, "runAsUser": 1000},
        "containers": [{
          "name": "'"$pod_name"'",
          "image": "'"$REGISTRY_TEST_IMAGE"'",
          "command": ["curl","-s","--max-time","10","-o","/dev/null","-w","%{http_code}","https://repo.kcs.kaspersky.com"],
          "securityContext": {"runAsNonRoot": true, "runAsUser": 1000}
        }]
      }
    }' >/dev/null 2>&1

  local elapsed=0 phase="" warned_pending=0
  while [[ $elapsed -lt $POD_POLL_TIMEOUT ]]; do
    phase=$(kubectl get pod "$pod_name" -n default \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    case "$phase" in
      Succeeded|Failed) break ;;
      Pending)
        if [[ $elapsed -ge $POD_PENDING_WARN_SEC ]] && [[ $warned_pending -eq 0 ]]; then
          print_warn "Pod still Pending after ${POD_PENDING_WARN_SEC}s — '${REGISTRY_TEST_IMAGE}' may not be pullable; try REGISTRY_TEST_IMAGE=alpine"
          warned_pending=1
        fi ;;
    esac
    sleep 3; elapsed=$(( elapsed + 3 ))
  done

  detail+="**Registry URL:** https://repo.kcs.kaspersky.com\n"
  detail+="**Test image:** ${REGISTRY_TEST_IMAGE}\n"
  detail+="**Pod phase:** ${phase}\n"

  if [[ "$phase" == "Succeeded" ]]; then
    local http_code
    http_code=$(kubectl logs "$pod_name" -n default 2>/dev/null || echo "000")
    detail+="**HTTP code:** ${http_code}\n"

    case "$http_code" in
      2??|3??|401|403)
        print_pass "Registry reachable — HTTP ${http_code}"
        record_result "G. Registry reachability" "✅ PASS" "$detail"
        return 0 ;;
      *)
        print_fail "Registry returned HTTP ${http_code}"
        detail+="**Result:** FAIL\n"
        record_result "G. Registry reachability" "❌ FAIL" "$detail"
        return 1 ;;
    esac
  elif [[ "$phase" == "Failed" ]]; then
    local http_code
    http_code=$(kubectl logs "$pod_name" -n default 2>/dev/null || echo "000")
    detail+="**HTTP code:** ${http_code:-000}\n"
    print_fail "Registry unreachable — pod failed, HTTP ${http_code:-000}"
    detail+="**Result:** FAIL\n"
    record_result "G. Registry reachability" "❌ FAIL" "$detail"
    return 1
  else
    print_warn "Pod did not complete within ${POD_POLL_TIMEOUT}s (phase: ${phase:-unknown})"
    detail+="**Result:** WARN — timed out\n"
    record_result "G. Registry reachability" "⚠️ WARN" "$detail"
    return 0
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK H — OS distribution and kernel version
# ═══════════════════════════════════════════════════════════════════════════════
check_os_kernel() {
  print_header "H. OS distribution and kernel version"

  local fail=0 detail=""

  local node_info
  node_info=$(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.osImage}{"\t"}{.status.nodeInfo.kernelVersion}{"\n"}{end}' \
    2>/dev/null)

  detail+="**Node OS and kernel info:**\n\`\`\`\n${node_info}\n\`\`\`\n"

  local has_warn=0
  while IFS=$'\t' read -r node_name os_image kernel_ver; do
    [[ -z "$node_name" ]] && continue

    if ! kernel_ge "$kernel_ver" "$MIN_KERNEL_MAJOR" "$MIN_KERNEL_MINOR"; then
      print_fail "Node ${node_name}: kernel ${kernel_ver} (${os_image}) — minimum ${MIN_KERNEL_MAJOR}.${MIN_KERNEL_MINOR} required"
      detail+="**${node_name}:** FAIL — kernel ${kernel_ver} < ${MIN_KERNEL_MAJOR}.${MIN_KERNEL_MINOR}\n"
      fail=1
    elif ! kernel_ge "$kernel_ver" "$WARN_KERNEL_MAJOR" "$WARN_KERNEL_MINOR"; then
      print_warn "Node ${node_name}: kernel ${kernel_ver} (${os_image}) — kernel < ${WARN_KERNEL_MAJOR}.${WARN_KERNEL_MINOR}, kcs-ih must run in privileged mode"
      detail+="**${node_name}:** WARN — kernel ${kernel_ver} ≥ ${MIN_KERNEL_MAJOR}.${MIN_KERNEL_MINOR} but < ${WARN_KERNEL_MAJOR}.${WARN_KERNEL_MINOR}, privileged mode required for kcs-ih\n"
      has_warn=1
    else
      print_pass "Node ${node_name}: kernel ${kernel_ver} (${os_image})"
      detail+="**${node_name}:** PASS — kernel ${kernel_ver} ≥ ${WARN_KERNEL_MAJOR}.${WARN_KERNEL_MINOR}\n"
    fi
  done <<< "$node_info"

  if [[ $fail -eq 0 ]] && [[ $has_warn -eq 1 ]]; then
    record_result "H. OS and kernel version" "⚠️ WARN" "$detail"
    return 0
  elif [[ $fail -eq 0 ]]; then
    record_result "H. OS and kernel version" "✅ PASS" "$detail"
    return 0
  else
    record_result "H. OS and kernel version" "❌ FAIL" "$detail"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK I — eBPF capabilities (BTF support)
# ═══════════════════════════════════════════════════════════════════════════════
check_ebpf() {
  print_header "I. eBPF capabilities (BTF support)"

  local fail=0 detail=""
  detail+="**Checking /sys/kernel/btf/vmlinux on each node (requires privileged pod)...**\n"

  local node_names
  node_names=$(kubectl get nodes --no-headers \
    -o custom-columns=NAME:.metadata.name 2>/dev/null)

  while IFS= read -r node_name; do
    [[ -z "$node_name" ]] && continue

    local pod_name="kcs-ebpf-${RANDOM}"
    kubectl apply -f - >/dev/null 2>&1 <<PODSPEC
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: default
spec:
  nodeName: ${node_name}
  restartPolicy: Never
  tolerations:
  - operator: Exists
  containers:
  - name: check
    image: busybox:1.36
    command: [sh, -c, test -f /sys/kernel/btf/vmlinux && echo BTF_OK || echo BTF_MISSING]
    securityContext:
      privileged: true
    volumeMounts:
    - name: sys
      mountPath: /sys
      readOnly: true
  volumes:
  - name: sys
    hostPath:
      path: /sys
PODSPEC

    local elapsed=0 phase=""
    while [[ $elapsed -lt 90 ]]; do
      phase=$(kubectl get pod "$pod_name" -n default \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
      sleep 2; elapsed=$(( elapsed + 2 ))
    done

    local btf_result=""
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && \
      btf_result=$(kubectl logs "$pod_name" -n default 2>/dev/null || echo "")

    kubectl delete pod "$pod_name" -n default \
      --ignore-not-found=true --timeout=15s >/dev/null 2>&1 || true

    if [[ "$btf_result" == "BTF_OK" ]]; then
      print_pass "Node ${node_name}: BTF available (/sys/kernel/btf/vmlinux found)"
      detail+="**${node_name}:** PASS — CONFIG_DEBUG_INFO_BTF=y, eBPF CO-RE supported\n"
    elif [[ "$btf_result" == "BTF_MISSING" ]]; then
      print_fail "Node ${node_name}: BTF NOT available (/sys/kernel/btf/vmlinux missing) — CONFIG_DEBUG_INFO_BTF=y required for eBPF CO-RE"
      detail+="**${node_name}:** FAIL — BTF missing, eBPF CO-RE not supported\n"
      fail=1
    else
      print_warn "Node ${node_name}: eBPF check inconclusive (pod phase: ${phase:-unknown})"
      detail+="**${node_name}:** WARN — check pod did not complete (phase: ${phase:-unknown})\n"
    fi
  done <<< "$node_names"

  if [[ $fail -eq 0 ]]; then
    record_result "I. eBPF capabilities" "✅ PASS" "$detail"
    return 0
  else
    record_result "I. eBPF capabilities" "❌ FAIL" "$detail"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK J — External PostgreSQL database
# ═══════════════════════════════════════════════════════════════════════════════
check_external_db() {
  print_header "J. External PostgreSQL database"

  if [[ -z "${EXTERNAL_DB_HOST:-}" ]]; then
    print_info "External DB check skipped (--external-db not provided)"
    record_result "J. External PostgreSQL" "⚠️ SKIP" "No external DB host specified — check skipped."
    return 0
  fi

  local pod_name="kcs-precheck-db-${RANDOM}"
  local host="${EXTERNAL_DB_HOST}"
  local port="${EXTERNAL_DB_PORT:-5432}"
  local user="${EXTERNAL_DB_USER:-postgres}"
  local pass="${EXTERNAL_DB_PASSWORD:-}"
  local detail=""
  detail+="**Host:** ${host}:${port}\n"
  detail+="**User:** ${user}\n"

  print_info "Testing PostgreSQL connectivity to ${host}:${port} (user: ${user}) via cluster pod '${pod_name}'..."

  kubectl apply -f - >/dev/null 2>&1 <<PODSPEC
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: check
    image: postgres:15-alpine
    env:
    - name: PGPASSWORD
      value: "${pass}"
    command: ["sh", "-c", "pg_isready -h ${host} -p ${port} -U ${user} -t 10 2>/dev/null && psql -h ${host} -p ${port} -U ${user} -c 'SELECT 1' postgres >/dev/null 2>&1 && echo DB_CONNECT_OK || echo DB_CONNECT_FAIL"]
PODSPEC

  local timeout="${DB_CHECK_TIMEOUT:-60}"
  local elapsed=0 phase=""
  while [[ $elapsed -lt $timeout ]]; do
    phase=$(kubectl get pod "$pod_name" -n default \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 2; elapsed=$(( elapsed + 2 ))
  done

  local result=""
  [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && \
    result=$(kubectl logs "$pod_name" -n default 2>/dev/null | tail -1 || echo "")

  kubectl delete pod "$pod_name" -n default \
    --ignore-not-found=true --timeout=15s >/dev/null 2>&1 || true

  detail+="**Pod phase:** ${phase:-timeout}\n"

  if [[ "$result" == "DB_CONNECT_OK" ]]; then
    print_pass "PostgreSQL at ${host}:${port} reachable, user '${user}' authenticated"
    record_result "J. External PostgreSQL" "✅ PASS" "$detail"
    return 0
  elif [[ "$result" == "DB_CONNECT_FAIL" ]]; then
    print_fail "Cannot connect to PostgreSQL at ${host}:${port} as user '${user}' — host unreachable or authentication failed"
    detail+="**Connection:** FAIL\n"
    record_result "J. External PostgreSQL" "❌ FAIL" "$detail"
    return 1
  else
    print_warn "PostgreSQL check inconclusive — pod did not complete within ${timeout}s (phase: ${phase:-unknown})"
    detail+="**Connection:** WARN — pod timed out or image pull failed\n"
    record_result "J. External PostgreSQL" "⚠️ WARN" "$detail"
    return 0
  fi
}
export -f check_external_db

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
print_summary() {
  echo ""
  echo -e "${_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_RESET}"
  echo -e "${_BOLD}  KCS 2.4 Pre-installation Check Summary${_RESET}"
  echo -e "${_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_RESET}"

  local has_fail=0 has_warn=0
  printf "  %-35s %s\n" "Check" "Status"
  printf "  %-35s %s\n" "─────────────────────────────────" "──────"

  for entry in "${CHECK_RESULTS[@]}"; do
    local label="${entry%%:*}"
    local rest="${entry#*:}"
    local status="${rest%%:*}"
    printf "  %-35s %s\n" "$label" "$status"
    [[ "$status" == *FAIL* ]] && has_fail=1
    [[ "$status" == *WARN* ]] && has_warn=1
  done

  echo ""
  if [[ $has_fail -eq 1 ]]; then
    print_fail "Cluster is NOT ready for KCS installation — fix FAIL items above"
  elif [[ $has_warn -eq 1 ]]; then
    print_warn "Cluster has warnings — review before installing KCS"
  else
    print_pass "Cluster is ready for KCS installation"
  fi

  echo ""
  print_info "Full report: ${REPORT_FILE}"

  # Write summary table to report
  {
    echo ""
    echo "## Summary"
    echo ""
    echo "| Check | Status |"
    echo "|---|---|"
    for entry in "${CHECK_RESULTS[@]}"; do
      local label="${entry%%:*}"
      local status="${entry#*:}"; status="${status%%:*}"
      echo "| ${label} | ${status} |"
    done
    echo ""
  } >> "$REPORT_FILE"
}

finalize() {
  local has_fail=0
  for entry in "${CHECK_RESULTS[@]}"; do
    local status="${entry#*:}"; status="${status%%:*}"
    [[ "$status" == *FAIL* ]] && has_fail=1
  done
  [[ $has_fail -eq 0 ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
main() {
  parse_args "$@"

  echo -e "${_BOLD}"
  echo "  ╔══════════════════════════════════════════════════╗"
  echo "  ║   KCS 2.4 Kubernetes Pre-Installation Checker   ║"
  echo "  ╚══════════════════════════════════════════════════╝"
  echo -e "${_RESET}"

  preflight_check
  gather_inputs
  init_report

  check_k8s_version || true
  check_cpu         || true
  check_memory      || true
  check_storage     || true
  check_ingress     || true
  check_dns         || true
  [[ -z "$SKIP_REGISTRY_CHECK" ]] && { check_registry || true; }
  check_os_kernel   || true
  check_ebpf        || true
  check_external_db || true

  print_summary

  finalize
}

# Allow sourcing for unit tests without running main
if [[ "${UNIT_TEST_MODE:-0}" != "1" ]]; then
  main "$@"
fi
