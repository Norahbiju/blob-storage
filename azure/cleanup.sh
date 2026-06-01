#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.azure"

log() { printf '\n[%s] %s\n' "$(date +'%H:%M:%S')" "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a && source "${ENV_FILE}" && set +a
fi

PROJECT_PREFIX="${PROJECT_PREFIX:-insclaims}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-${PROJECT_PREFIX}-${ENVIRONMENT}}"

az account show >/dev/null 2>&1 || fail "Azure CLI is not logged in. Run az login first."

cat <<EOF
This will delete the full resource group and all Azure resources for this deployment:
  ${RESOURCE_GROUP}

This includes App Service, Application Gateway, Cosmos DB, Storage Account, Key Vault,
Log Analytics, Application Insights, networking, data, and uploaded documents.
EOF

read -r -p "Type the resource group name to confirm deletion: " confirmation
if [[ "${confirmation}" != "${RESOURCE_GROUP}" ]]; then
  fail "Confirmation did not match. Cleanup cancelled."
fi

log "Deleting resource group ${RESOURCE_GROUP}"
az group delete --name "${RESOURCE_GROUP}" --yes --no-wait

log "Delete submitted. Resource removal continues asynchronously."
