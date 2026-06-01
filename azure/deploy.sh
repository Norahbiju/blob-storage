#!/usr/bin/env bash
set -euo pipefail

# Deploys the insurance claims monolith to Azure App Service behind Application Gateway WAF.
# The app code is unchanged. Secrets are placed in Key Vault and referenced by App Service.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.azure"

log() { printf '\n[%s] %s\n' "$(date +'%H:%M:%S')" "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
has_command() { command -v "$1" >/dev/null 2>&1; }

load_env() {
  if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    set -a && source "${ENV_FILE}" && set +a
  else
    log "No azure/.env.azure file found. Defaults and generated names will be used."
  fi
}

stable_suffix() {
  local subscription_id
  subscription_id="$(az account show --query id -o tsv)"
  printf '%s' "${subscription_id//-/}" | cut -c1-6 | tr '[:upper:]' '[:lower:]'
}

require_login() {
  az account show >/dev/null 2>&1 || fail "Azure CLI is not logged in. Run az login first."
}

ensure_provider() {
  local namespace="$1"
  local state
  state="$(az provider show --namespace "${namespace}" --query registrationState -o tsv 2>/dev/null || true)"
  if [[ "${state}" != "Registered" ]]; then
    log "Registering provider ${namespace}"
    az provider register --namespace "${namespace}" --wait
  fi
}

resource_exists() {
  az resource show --ids "$1" >/dev/null 2>&1
}

main() {
  need az
  load_env
  require_login

  local suffix
  suffix="$(stable_suffix)"

  PROJECT_PREFIX="${PROJECT_PREFIX:-insclaims}"
  LOCATION="${LOCATION:-eastus}"
  APP_SERVICE_LOCATION="${APP_SERVICE_LOCATION:-${LOCATION}}"
  ENVIRONMENT="${ENVIRONMENT:-prod}"
  RESOURCE_GROUP="${RESOURCE_GROUP:-rg-${PROJECT_PREFIX}-${ENVIRONMENT}}"
  APP_NAME="${APP_NAME:-app-${PROJECT_PREFIX}-${suffix}}"
  APP_SERVICE_PLAN_NAME="${APP_SERVICE_PLAN_NAME:-asp-${PROJECT_PREFIX}-${ENVIRONMENT}}"
  STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-st${PROJECT_PREFIX}${suffix}}"
  STORAGE_ACCOUNT_NAME="$(echo "${STORAGE_ACCOUNT_NAME}" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c1-24)"
  COSMOS_ACCOUNT_NAME="${COSMOS_ACCOUNT_NAME:-cosmos-${PROJECT_PREFIX}-${suffix}}"
  KEY_VAULT_NAME="${KEY_VAULT_NAME:-kv-${PROJECT_PREFIX}-${suffix}}"
  KEY_VAULT_NAME="$(echo "${KEY_VAULT_NAME}" | tr -cd '[:alnum:]-' | cut -c1-24)"
  APP_INSIGHTS_NAME="${APP_INSIGHTS_NAME:-appi-${PROJECT_PREFIX}-${ENVIRONMENT}}"
  LOG_ANALYTICS_NAME="${LOG_ANALYTICS_NAME:-log-${PROJECT_PREFIX}-${ENVIRONMENT}}"
  APP_GATEWAY_NAME="${APP_GATEWAY_NAME:-agw-${PROJECT_PREFIX}-${ENVIRONMENT}}"
  WAF_POLICY_NAME="${WAF_POLICY_NAME:-waf-${PROJECT_PREFIX}-${ENVIRONMENT}}"
  PUBLIC_IP_NAME="${PUBLIC_IP_NAME:-pip-${PROJECT_PREFIX}-${ENVIRONMENT}}"
  VNET_NAME="${VNET_NAME:-vnet-${PROJECT_PREFIX}-${ENVIRONMENT}}"

  COSMOS_DB_DATABASE_NAME="${COSMOS_DB_DATABASE_NAME:-insurance-claims}"
  COSMOS_DB_CONTAINER_NAME="${COSMOS_DB_CONTAINER_NAME:-claims}"
  AZURE_STORAGE_CONTAINER_NAME="${AZURE_STORAGE_CONTAINER_NAME:-insurance-documents}"
  DEMO_USER_PASSWORD="${DEMO_USER_PASSWORD:-replace-with-user-demo-password}"
  DEMO_ADMIN_PASSWORD="${DEMO_ADMIN_PASSWORD:-replace-with-admin-demo-password}"
  SESSION_SECRET="${SESSION_SECRET:-replace-with-long-random-session-secret}"
  VNET_CIDR="${VNET_CIDR:-10.42.0.0/16}"
  APPGW_SUBNET_CIDR="${APPGW_SUBNET_CIDR:-10.42.1.0/24}"
  APP_SERVICE_INTEGRATION_SUBNET_CIDR="${APP_SERVICE_INTEGRATION_SUBNET_CIDR:-10.42.2.0/24}"
  PRIVATE_ENDPOINT_SUBNET_CIDR="${PRIVATE_ENDPOINT_SUBNET_CIDR:-10.42.3.0/24}"
  APP_SERVICE_SKU="${APP_SERVICE_SKU:-P1V3}"
  APP_GATEWAY_CAPACITY="${APP_GATEWAY_CAPACITY:-1}"
  COSMOS_THROUGHPUT="${COSMOS_THROUGHPUT:-400}"
  STORAGE_SKU="${STORAGE_SKU:-Standard_RAGZRS}"
  ENABLE_APP_SERVICE_RESTRICTION="${ENABLE_APP_SERVICE_RESTRICTION:-false}"

  log "Registering required Azure resource providers"
  ensure_provider Microsoft.Web
  ensure_provider Microsoft.Network
  ensure_provider Microsoft.Storage
  ensure_provider Microsoft.DocumentDB
  ensure_provider Microsoft.KeyVault
  ensure_provider Microsoft.Insights

  log "Creating resource group ${RESOURCE_GROUP}"
  az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" --tags app=insurance-claims env="${ENVIRONMENT}" >/dev/null

  log "Creating network"
  az network vnet create \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --name "${VNET_NAME}" \
    --address-prefix "${VNET_CIDR}" \
    --subnet-name appgw-subnet \
    --subnet-prefixes "${APPGW_SUBNET_CIDR}" >/dev/null

  az network vnet subnet create \
    --resource-group "${RESOURCE_GROUP}" \
    --vnet-name "${VNET_NAME}" \
    --name appservice-integration-subnet \
    --address-prefixes "${APP_SERVICE_INTEGRATION_SUBNET_CIDR}" \
    --delegations Microsoft.Web/serverFarms >/dev/null

  az network vnet subnet update \
    --resource-group "${RESOURCE_GROUP}" \
    --vnet-name "${VNET_NAME}" \
    --name appgw-subnet \
    --service-endpoints Microsoft.Web >/dev/null

  az network vnet subnet create \
    --resource-group "${RESOURCE_GROUP}" \
    --vnet-name "${VNET_NAME}" \
    --name private-endpoint-subnet \
    --address-prefixes "${PRIVATE_ENDPOINT_SUBNET_CIDR}" >/dev/null

  az network vnet subnet update \
    --resource-group "${RESOURCE_GROUP}" \
    --vnet-name "${VNET_NAME}" \
    --name private-endpoint-subnet \
    --disable-private-endpoint-network-policies true >/dev/null

  log "Creating Log Analytics and Application Insights"
  az monitor log-analytics workspace create \
    --resource-group "${RESOURCE_GROUP}" \
    --workspace-name "${LOG_ANALYTICS_NAME}" \
    --location "${LOCATION}" >/dev/null

  local workspace_id
  workspace_id="$(az monitor log-analytics workspace show --resource-group "${RESOURCE_GROUP}" --workspace-name "${LOG_ANALYTICS_NAME}" --query id -o tsv)"

  az resource create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${APP_INSIGHTS_NAME}" \
    --resource-type "Microsoft.Insights/components" \
    --api-version "2020-02-02" \
    --location "${LOCATION}" \
    --properties "{\"Application_Type\":\"web\",\"WorkspaceResourceId\":\"${workspace_id}\"}" >/dev/null

  local appinsights_connection_string
  appinsights_connection_string="$(az resource show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${APP_INSIGHTS_NAME}" \
    --resource-type "Microsoft.Insights/components" \
    --query properties.ConnectionString \
    -o tsv)"

  log "Creating Cosmos DB for NoSQL"
  if az cosmosdb show --name "${COSMOS_ACCOUNT_NAME}" --resource-group "${RESOURCE_GROUP}" >/dev/null 2>&1; then
    log "Cosmos DB account ${COSMOS_ACCOUNT_NAME} already exists"
  else
    az cosmosdb create \
      --name "${COSMOS_ACCOUNT_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --locations regionName="${LOCATION}" failoverPriority=0 isZoneRedundant=False \
      --default-consistency-level Session \
      --enable-automatic-failover true \
      --backup-policy-type Periodic \
      --backup-interval 240 \
      --backup-retention 8 >/dev/null
  fi

  if az cosmosdb sql database show \
    --account-name "${COSMOS_ACCOUNT_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${COSMOS_DB_DATABASE_NAME}" >/dev/null 2>&1; then
    log "Cosmos DB database ${COSMOS_DB_DATABASE_NAME} already exists"
  else
    az cosmosdb sql database create \
      --account-name "${COSMOS_ACCOUNT_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --name "${COSMOS_DB_DATABASE_NAME}" >/dev/null
  fi

  if az cosmosdb sql container show \
    --account-name "${COSMOS_ACCOUNT_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --database-name "${COSMOS_DB_DATABASE_NAME}" \
    --name "${COSMOS_DB_CONTAINER_NAME}" >/dev/null 2>&1; then
    log "Cosmos DB container ${COSMOS_DB_CONTAINER_NAME} already exists"
  else
    az cosmosdb sql container create \
      --account-name "${COSMOS_ACCOUNT_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --database-name "${COSMOS_DB_DATABASE_NAME}" \
      --name "${COSMOS_DB_CONTAINER_NAME}" \
      --partition-key-path "/partitionKey" \
      --throughput "${COSMOS_THROUGHPUT}" >/dev/null
  fi

  local cosmos_endpoint cosmos_key
  cosmos_endpoint="$(az cosmosdb show --name "${COSMOS_ACCOUNT_NAME}" --resource-group "${RESOURCE_GROUP}" --query documentEndpoint -o tsv)"
  cosmos_key="$(az cosmosdb keys list --name "${COSMOS_ACCOUNT_NAME}" --resource-group "${RESOURCE_GROUP}" --type keys --query primaryMasterKey -o tsv)"

  log "Creating Storage Account and private document container"
  az storage account create \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --name "${STORAGE_ACCOUNT_NAME}" \
    --sku "${STORAGE_SKU}" \
    --kind StorageV2 \
    --https-only true \
    --allow-blob-public-access false \
    --min-tls-version TLS1_2 >/dev/null

  az storage account blob-service-properties update \
    --resource-group "${RESOURCE_GROUP}" \
    --account-name "${STORAGE_ACCOUNT_NAME}" \
    --enable-delete-retention true \
    --delete-retention-days 30 \
    --enable-versioning true \
    --enable-container-delete-retention true \
    --container-delete-retention-days 30 >/dev/null

  local storage_connection_string
  storage_connection_string="$(az storage account show-connection-string --resource-group "${RESOURCE_GROUP}" --name "${STORAGE_ACCOUNT_NAME}" --query connectionString -o tsv)"

  local subscription_id
  subscription_id="$(az account show --query id -o tsv)"
  az rest \
    --method put \
    --url "https://management.azure.com/subscriptions/${subscription_id}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT_NAME}/blobServices/default/containers/${AZURE_STORAGE_CONTAINER_NAME}?api-version=2023-01-01" \
    --body '{"properties":{"publicAccess":"None"}}' >/dev/null

  log "Creating Key Vault and storing app secrets"
  if az keyvault show --name "${KEY_VAULT_NAME}" --resource-group "${RESOURCE_GROUP}" >/dev/null 2>&1; then
    log "Key Vault ${KEY_VAULT_NAME} already exists"
  else
    az keyvault create \
      --resource-group "${RESOURCE_GROUP}" \
      --location "${LOCATION}" \
      --name "${KEY_VAULT_NAME}" \
      --enable-rbac-authorization true \
      --enable-purge-protection true \
      --retention-days 90 >/dev/null
  fi

  local signed_in_object_id
  signed_in_object_id="$(az ad signed-in-user show --query id -o tsv)"
  az role assignment create \
    --assignee-object-id "${signed_in_object_id}" \
    --assignee-principal-type User \
    --role "Key Vault Secrets Officer" \
    --scope "$(az keyvault show --name "${KEY_VAULT_NAME}" --resource-group "${RESOURCE_GROUP}" --query id -o tsv)" >/dev/null 2>&1 || true

  sleep 20
  az keyvault secret set --vault-name "${KEY_VAULT_NAME}" --name cosmos-db-endpoint --value "${cosmos_endpoint}" >/dev/null
  az keyvault secret set --vault-name "${KEY_VAULT_NAME}" --name cosmos-db-key --value "${cosmos_key}" >/dev/null
  az keyvault secret set --vault-name "${KEY_VAULT_NAME}" --name azure-storage-connection-string --value "${storage_connection_string}" >/dev/null
  az keyvault secret set --vault-name "${KEY_VAULT_NAME}" --name session-secret --value "${SESSION_SECRET}" >/dev/null
  az keyvault secret set --vault-name "${KEY_VAULT_NAME}" --name demo-user-password --value "${DEMO_USER_PASSWORD}" >/dev/null
  az keyvault secret set --vault-name "${KEY_VAULT_NAME}" --name demo-admin-password --value "${DEMO_ADMIN_PASSWORD}" >/dev/null

  log "Creating App Service Plan and Web App"
  az appservice plan create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${APP_SERVICE_PLAN_NAME}" \
    --location "${APP_SERVICE_LOCATION}" \
    --is-linux \
    --sku "${APP_SERVICE_SKU}" >/dev/null

  az webapp create \
    --resource-group "${RESOURCE_GROUP}" \
    --plan "${APP_SERVICE_PLAN_NAME}" \
    --name "${APP_NAME}" \
    --runtime "NODE:22-lts" >/dev/null

  az webapp identity assign --resource-group "${RESOURCE_GROUP}" --name "${APP_NAME}" >/dev/null
  local webapp_principal_id
  webapp_principal_id="$(az webapp identity show --resource-group "${RESOURCE_GROUP}" --name "${APP_NAME}" --query principalId -o tsv)"

  az role assignment create \
    --assignee-object-id "${webapp_principal_id}" \
    --assignee-principal-type ServicePrincipal \
    --role "Key Vault Secrets User" \
    --scope "$(az keyvault show --name "${KEY_VAULT_NAME}" --resource-group "${RESOURCE_GROUP}" --query id -o tsv)" >/dev/null

  az webapp vnet-integration add \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${APP_NAME}" \
    --vnet "${VNET_NAME}" \
    --subnet appservice-integration-subnet >/dev/null || log "Skipping App Service VNet integration; App Service and VNet may be in different regions or SKU may not support it."

  az webapp config set \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${APP_NAME}" \
    --always-on true \
    --http20-enabled true \
    --min-tls-version 1.2 \
    --ftps-state Disabled \
    --startup-file "npm start" >/dev/null

  az webapp update \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${APP_NAME}" \
    --https-only true >/dev/null

  az webapp config appsettings set \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${APP_NAME}" \
    --settings \
      NODE_ENV=production \
      COSMOS_DB_DATABASE_NAME="${COSMOS_DB_DATABASE_NAME}" \
      COSMOS_DB_CONTAINER_NAME="${COSMOS_DB_CONTAINER_NAME}" \
      AZURE_STORAGE_CONTAINER_NAME="${AZURE_STORAGE_CONTAINER_NAME}" \
      COSMOS_DB_ENDPOINT="@Microsoft.KeyVault(VaultName=${KEY_VAULT_NAME};SecretName=cosmos-db-endpoint)" \
      COSMOS_DB_KEY="@Microsoft.KeyVault(VaultName=${KEY_VAULT_NAME};SecretName=cosmos-db-key)" \
      AZURE_STORAGE_CONNECTION_STRING="@Microsoft.KeyVault(VaultName=${KEY_VAULT_NAME};SecretName=azure-storage-connection-string)" \
      SESSION_SECRET="@Microsoft.KeyVault(VaultName=${KEY_VAULT_NAME};SecretName=session-secret)" \
      DEMO_USER_PASSWORD="@Microsoft.KeyVault(VaultName=${KEY_VAULT_NAME};SecretName=demo-user-password)" \
      DEMO_ADMIN_PASSWORD="@Microsoft.KeyVault(VaultName=${KEY_VAULT_NAME};SecretName=demo-admin-password)" \
      APPLICATIONINSIGHTS_CONNECTION_STRING="${appinsights_connection_string}" >/dev/null

  az webapp config appsettings set \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${APP_NAME}" \
    --settings WEBSITE_RUN_FROM_PACKAGE=1 WEBSITE_NODE_DEFAULT_VERSION=~22 >/dev/null

  log "Creating deployment package"
  local package_path="${SCRIPT_DIR}/app-package.zip"
  rm -f "${package_path}"
  create_package "${REPO_ROOT}" "${package_path}"

  log "Deploying application package to App Service"
  az webapp deploy \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${APP_NAME}" \
    --src-path "${package_path}" \
    --type zip \
    --async false >/dev/null

  log "Configuring App Service health check"
  az webapp config set \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${APP_NAME}" \
    --generic-configurations '{"healthCheckPath":"/health"}' >/dev/null

  log "Creating public Application Gateway with WAF v2"
  az network public-ip create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${PUBLIC_IP_NAME}" \
    --location "${LOCATION}" \
    --sku Standard \
    --allocation-method Static >/dev/null

  local webapp_host
  webapp_host="${APP_NAME}.azurewebsites.net"

  if az network application-gateway waf-policy show --resource-group "${RESOURCE_GROUP}" --name "${WAF_POLICY_NAME}" >/dev/null 2>&1; then
    log "WAF policy ${WAF_POLICY_NAME} already exists"
  else
    az network application-gateway waf-policy create \
      --resource-group "${RESOURCE_GROUP}" \
      --name "${WAF_POLICY_NAME}" \
      --location "${LOCATION}" \
      --type OWASP \
      --version 3.2 >/dev/null
    az network application-gateway waf-policy policy-setting update \
      --resource-group "${RESOURCE_GROUP}" \
      --policy-name "${WAF_POLICY_NAME}" \
      --mode Prevention \
      --state Enabled >/dev/null
  fi

  local waf_policy_id
  waf_policy_id="$(az network application-gateway waf-policy show --resource-group "${RESOURCE_GROUP}" --name "${WAF_POLICY_NAME}" --query id -o tsv)"

  az network application-gateway create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${APP_GATEWAY_NAME}" \
    --location "${LOCATION}" \
    --sku WAF_v2 \
    --waf-policy "${waf_policy_id}" \
    --capacity "${APP_GATEWAY_CAPACITY}" \
    --vnet-name "${VNET_NAME}" \
    --subnet appgw-subnet \
    --public-ip-address "${PUBLIC_IP_NAME}" \
    --http-settings-cookie-based-affinity Disabled \
    --http-settings-port 443 \
    --http-settings-protocol Https \
    --frontend-port 80 \
    --routing-rule-type Basic \
    --servers "${webapp_host}" \
    --priority 100 >/dev/null

  az network application-gateway http-settings update \
    --resource-group "${RESOURCE_GROUP}" \
    --gateway-name "${APP_GATEWAY_NAME}" \
    --name appGatewayBackendHttpSettings \
    --host-name-from-backend-pool true \
    --port 443 \
    --protocol Https >/dev/null

  az network application-gateway probe create \
    --resource-group "${RESOURCE_GROUP}" \
    --gateway-name "${APP_GATEWAY_NAME}" \
    --name app-health-probe \
    --protocol Https \
    --host-name-from-http-settings true \
    --path /health \
    --interval 30 \
    --timeout 30 \
    --threshold 3 >/dev/null

  az network application-gateway http-settings update \
    --resource-group "${RESOURCE_GROUP}" \
    --gateway-name "${APP_GATEWAY_NAME}" \
    --name appGatewayBackendHttpSettings \
    --probe app-health-probe >/dev/null

  az network application-gateway waf-config set \
    --resource-group "${RESOURCE_GROUP}" \
    --gateway-name "${APP_GATEWAY_NAME}" \
    --enabled true \
    --firewall-mode Prevention \
    --rule-set-type OWASP \
    --rule-set-version 3.2 >/dev/null

  local appgw_public_ip
  appgw_public_ip="$(az network public-ip show --resource-group "${RESOURCE_GROUP}" --name "${PUBLIC_IP_NAME}" --query ipAddress -o tsv)"

  if [[ "${ENABLE_APP_SERVICE_RESTRICTION}" == "true" ]]; then
    log "Restricting App Service to the Application Gateway subnet"
    az webapp config access-restriction add \
      --resource-group "${RESOURCE_GROUP}" \
      --name "${APP_NAME}" \
      --rule-name Allow-AppGateway \
      --action Allow \
      --vnet-name "${VNET_NAME}" \
      --subnet appgw-subnet \
      --priority 100 >/dev/null

    az webapp config access-restriction set \
      --resource-group "${RESOURCE_GROUP}" \
      --name "${APP_NAME}" \
      --default-action Deny >/dev/null
  else
    log "Leaving direct App Service access enabled. Set ENABLE_APP_SERVICE_RESTRICTION=true only after validating same-region App Gateway/App Service networking."
  fi

  log "Enabling diagnostics"
  local app_id agw_id cosmos_id storage_id
  app_id="$(az webapp show --resource-group "${RESOURCE_GROUP}" --name "${APP_NAME}" --query id -o tsv)"
  agw_id="$(az network application-gateway show --resource-group "${RESOURCE_GROUP}" --name "${APP_GATEWAY_NAME}" --query id -o tsv)"
  cosmos_id="$(az cosmosdb show --resource-group "${RESOURCE_GROUP}" --name "${COSMOS_ACCOUNT_NAME}" --query id -o tsv)"
  storage_id="$(az storage account show --resource-group "${RESOURCE_GROUP}" --name "${STORAGE_ACCOUNT_NAME}" --query id -o tsv)"

  az monitor diagnostic-settings create --name appservice-diagnostics --resource "${app_id}" --workspace "${workspace_id}" --logs '[{"category":"AppServiceHTTPLogs","enabled":true},{"category":"AppServiceConsoleLogs","enabled":true},{"category":"AppServiceAppLogs","enabled":true}]' --metrics '[{"category":"AllMetrics","enabled":true}]' >/dev/null 2>&1 || true
  az monitor diagnostic-settings create --name appgw-diagnostics --resource "${agw_id}" --workspace "${workspace_id}" --logs '[{"category":"ApplicationGatewayAccessLog","enabled":true},{"category":"ApplicationGatewayPerformanceLog","enabled":true},{"category":"ApplicationGatewayFirewallLog","enabled":true}]' --metrics '[{"category":"AllMetrics","enabled":true}]' >/dev/null 2>&1 || true
  az monitor diagnostic-settings create --name cosmos-diagnostics --resource "${cosmos_id}" --workspace "${workspace_id}" --logs '[{"category":"DataPlaneRequests","enabled":true},{"category":"QueryRuntimeStatistics","enabled":true}]' --metrics '[{"category":"Requests","enabled":true}]' >/dev/null 2>&1 || true
  az monitor diagnostic-settings create --name storage-diagnostics --resource "${storage_id}/blobServices/default" --workspace "${workspace_id}" --logs '[{"category":"StorageRead","enabled":true},{"category":"StorageWrite","enabled":true},{"category":"StorageDelete","enabled":true}]' --metrics '[{"category":"Transaction","enabled":true}]' >/dev/null 2>&1 || true

  log "Creating baseline alerts"
  az monitor metrics alert create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${APP_NAME}-http-5xx" \
    --scopes "${app_id}" \
    --condition "count Http5xx > 5" \
    --window-size 5m \
    --evaluation-frequency 1m \
    --description "App Service has more than 5 HTTP 5xx responses in 5 minutes." >/dev/null 2>&1 || true

  az monitor metrics alert create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${COSMOS_ACCOUNT_NAME}-throttles" \
    --scopes "${cosmos_id}" \
    --condition "total TotalRequests > 0 where StatusCode includes 429" \
    --window-size 5m \
    --evaluation-frequency 1m \
    --description "Cosmos DB throttling detected." >/dev/null 2>&1 || true

  log "Validating deployment"
  sleep 30
  local appgw_url="http://${appgw_public_ip}"
  local health_code
  health_code="$(curl -s -o /dev/null -w "%{http_code}" "${appgw_url}/health" || true)"
  if [[ "${health_code}" != "200" ]]; then
    log "Application Gateway health returned ${health_code}. Check backend health with:"
    log "az network application-gateway show-backend-health -g ${RESOURCE_GROUP} -n ${APP_GATEWAY_NAME}"
  else
    log "Application Gateway health validation returned 200."
  fi

  cat <<EOF

Deployment complete.

Resource group:       ${RESOURCE_GROUP}
App Service:          ${APP_NAME}
Application Gateway:  ${APP_GATEWAY_NAME}
Public URL:           ${appgw_url}
Health URL:           ${appgw_url}/health
Cosmos DB:            ${COSMOS_ACCOUNT_NAME}/${COSMOS_DB_DATABASE_NAME}/${COSMOS_DB_CONTAINER_NAME}
Storage account:      ${STORAGE_ACCOUNT_NAME}/${AZURE_STORAGE_CONTAINER_NAME}
Key Vault:            ${KEY_VAULT_NAME}
Log Analytics:        ${LOG_ANALYTICS_NAME}
Application Insights: ${APP_INSIGHTS_NAME}

Next steps:
1. Browse to ${appgw_url}
2. Check backend health:
   az network application-gateway show-backend-health -g ${RESOURCE_GROUP} -n ${APP_GATEWAY_NAME} -o table
3. Add a custom domain and HTTPS listener/certificate for production use.
EOF
}

create_package() {
  local repo_root="$1"
  local package_path="$2"

  if has_command zip; then
    (
      cd "${repo_root}"
      zip -qr "${package_path}" package.json package-lock.json src public node_modules
    )
    return
  fi

  if has_command powershell.exe; then
    log "zip was not found. Using PowerShell ZipArchive fallback."
    local repo_root_win package_path_win
    if has_command cygpath; then
      repo_root_win="$(cygpath -w "${repo_root}")"
      package_path_win="$(cygpath -w "${package_path}")"
    else
      repo_root_win="${repo_root}"
      package_path_win="${package_path}"
    fi

    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "\
      \$ErrorActionPreference = 'Stop'; \
      Add-Type -AssemblyName System.IO.Compression; \
      Add-Type -AssemblyName System.IO.Compression.FileSystem; \
      \$repo = '${repo_root_win}'; \
      \$package = '${package_path_win}'; \
      if (Test-Path -LiteralPath \$package) { Remove-Item -LiteralPath \$package -Force; } \
      \$zip = [System.IO.Compression.ZipFile]::Open(\$package, [System.IO.Compression.ZipArchiveMode]::Create); \
      try { \
        foreach (\$rootName in @('src','public','node_modules')) { \
          \$rootPath = Join-Path \$repo \$rootName; \
          if (Test-Path -LiteralPath \$rootPath) { \
            Get-ChildItem -LiteralPath \$rootPath -Recurse -File | ForEach-Object { \
              \$entryName = \$_.FullName.Substring(\$repo.Length + 1).Replace('\', '/'); \
              [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(\$zip, \$_.FullName, \$entryName, [System.IO.Compression.CompressionLevel]::Fastest) | Out-Null; \
            }; \
          }; \
        }; \
        foreach (\$fileName in @('package.json','package-lock.json')) { \
          \$filePath = Join-Path \$repo \$fileName; \
          if (Test-Path -LiteralPath \$filePath) { \
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(\$zip, \$filePath, \$fileName, [System.IO.Compression.CompressionLevel]::Fastest) | Out-Null; \
          }; \
        }; \
      } finally { \
        \$zip.Dispose(); \
      }"
    return
  fi

  fail "Neither zip nor powershell.exe was found. Install zip for Git Bash or run from a Windows shell with PowerShell available."
}

main "$@"
