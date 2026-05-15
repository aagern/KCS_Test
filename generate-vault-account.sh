#!/usr/bin/env bash
# Generate a vault-file.key for use with kcs_k8s_check.sh --vault-account
# Usage: bash generate-vault-account.sh [VAULT_ADDR] [VAULT_TOKEN] [output-file]
# Example:
#   bash generate-vault-account.sh http://10.160.6.210:8200 hvs.xxx vault-account.key

set -euo pipefail

VAULT_ADDR_ARG="${1:-}"
VAULT_TOKEN_ARG="${2:-}"
OUTPUT_FILE="${3:-vault-account.key}"

if [[ -z "$VAULT_ADDR_ARG" || -z "$VAULT_TOKEN_ARG" ]]; then
  echo "Usage: $0 <vault-addr> <vault-token> [output-file]"
  echo ""
  echo "Examples:"
  echo "  $0 http://10.160.6.210:8200 hvs.XXXXXXXXXX vault-account.key"
  echo "  $0 https://vault.corp.example.com:8200 hvs.XXXXXXXXXX vault-account.key"
  exit 1
fi

cat > "$OUTPUT_FILE" <<EOF
# HashiCorp Vault connection credentials for KCS pre-installation check
# Generated: $(date)
# Usage: kcs_k8s_check.sh --vault <HOST> --vault-account ${OUTPUT_FILE}

VAULT_ADDR=${VAULT_ADDR_ARG}
VAULT_TOKEN=${VAULT_TOKEN_ARG}
EOF

chmod 600 "$OUTPUT_FILE"
echo "Written to ${OUTPUT_FILE} (permissions: 600)"
