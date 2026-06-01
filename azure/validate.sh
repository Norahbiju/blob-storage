#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.azure"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a && source "${ENV_FILE}" && set +a
fi

PROJECT_PREFIX="${PROJECT_PREFIX:-insclaims}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-${PROJECT_PREFIX}-${ENVIRONMENT}}"
APP_NAME="${APP_NAME:-}"
APP_GATEWAY_NAME="${APP_GATEWAY_NAME:-agw-${PROJECT_PREFIX}-${ENVIRONMENT}}"
PUBLIC_IP_NAME="${PUBLIC_IP_NAME:-pip-${PROJECT_PREFIX}-${ENVIRONMENT}}"
COSMOS_DB_DATABASE_NAME="${COSMOS_DB_DATABASE_NAME:-insurance-claims}"
COSMOS_DB_CONTAINER_NAME="${COSMOS_DB_CONTAINER_NAME:-claims}"
AZURE_STORAGE_CONTAINER_NAME="${AZURE_STORAGE_CONTAINER_NAME:-insurance-documents}"

echo "Validating resource group: ${RESOURCE_GROUP}"
az group show --name "${RESOURCE_GROUP}" --query "{name:name,location:location}" -o table

if [[ -z "${APP_NAME}" ]]; then
  APP_NAME="$(az webapp list --resource-group "${RESOURCE_GROUP}" --query "[?starts_with(name, 'app-${PROJECT_PREFIX}')].name | [0]" -o tsv)"
fi

COSMOS_ACCOUNT_NAME="$(az cosmosdb list --resource-group "${RESOURCE_GROUP}" --query "[0].name" -o tsv)"
STORAGE_ACCOUNT_NAME="$(az storage account list --resource-group "${RESOURCE_GROUP}" --query "[0].name" -o tsv)"
APPGW_PUBLIC_IP="$(az network public-ip show --resource-group "${RESOURCE_GROUP}" --name "${PUBLIC_IP_NAME}" --query ipAddress -o tsv)"

echo
echo "App Service:"
az webapp show --resource-group "${RESOURCE_GROUP}" --name "${APP_NAME}" --query "{name:name,state:state,host:defaultHostName,httpsOnly:httpsOnly}" -o table

echo
echo "Application Gateway WAF:"
az network application-gateway waf-config show --resource-group "${RESOURCE_GROUP}" --gateway-name "${APP_GATEWAY_NAME}" -o table

echo
echo "Application Gateway backend health:"
az network application-gateway show-backend-health --resource-group "${RESOURCE_GROUP}" --name "${APP_GATEWAY_NAME}" -o table

echo
echo "Cosmos DB database and container:"
az cosmosdb sql database show --account-name "${COSMOS_ACCOUNT_NAME}" --resource-group "${RESOURCE_GROUP}" --name "${COSMOS_DB_DATABASE_NAME}" --query "{name:name}" -o table
az cosmosdb sql container show --account-name "${COSMOS_ACCOUNT_NAME}" --resource-group "${RESOURCE_GROUP}" --database-name "${COSMOS_DB_DATABASE_NAME}" --name "${COSMOS_DB_CONTAINER_NAME}" --query "{name:name,partitionKey:resource.partitionKey.paths[0]}" -o table

echo
echo "Blob container public access:"
CONNECTION_STRING="$(az storage account show-connection-string --resource-group "${RESOURCE_GROUP}" --name "${STORAGE_ACCOUNT_NAME}" --query connectionString -o tsv)"
az storage container show --name "${AZURE_STORAGE_CONTAINER_NAME}" --connection-string "${CONNECTION_STRING}" --query "{name:name,publicAccess:properties.publicAccess}" -o table

echo
echo "App settings with Key Vault references:"
az webapp config appsettings list --resource-group "${RESOURCE_GROUP}" --name "${APP_NAME}" --query "[?name=='COSMOS_DB_ENDPOINT' || name=='COSMOS_DB_KEY' || name=='AZURE_STORAGE_CONNECTION_STRING' || name=='SESSION_SECRET' || name=='NODE_ENV'].{name:name,value:value}" -o table

echo
echo "Health endpoint through Application Gateway:"
curl -i "http://${APPGW_PUBLIC_IP}/health"

echo
echo "Expected result: HTTP/1.1 200 and JSON body {\"status\":\"ok\"}."
