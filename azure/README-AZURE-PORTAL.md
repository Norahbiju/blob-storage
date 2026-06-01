# Azure Portal Deployment Guide

This guide explains how to configure the insurance claims application manually in the Azure Portal UI.

The target architecture is:

```text
Browser
  -> Azure Application Gateway with WAF v2
  -> Azure App Service running Node.js 20
  -> Azure Cosmos DB for users, claims, status, and feedback
  -> Azure Blob Storage for uploaded documents
  -> Azure Key Vault for secrets
  -> Application Insights and Log Analytics for monitoring
```

## 1. Create A Resource Group

1. Open the Azure Portal.
2. Search for **Resource groups**.
3. Select **Create**.
4. Use:

```text
Subscription: your subscription
Resource group: rg-insclaims-prod
Region: East US
```

5. Select **Review + create**.
6. Select **Create**.

## 2. Create The Virtual Network

1. Search for **Virtual networks**.
2. Select **Create**.
3. Basics:

```text
Resource group: rg-insclaims-prod
Name: vnet-insclaims-prod
Region: East US
Address space: 10.42.0.0/16
```

4. Add these subnets:

```text
appgw-subnet
10.42.1.0/24

appservice-integration-subnet
10.42.2.0/24
Delegation: Microsoft.Web/serverFarms

private-endpoint-subnet
10.42.3.0/24
```

5. Create the VNet.

After creation:

1. Open `vnet-insclaims-prod`.
2. Go to **Subnets**.
3. Open `appgw-subnet`.
4. Enable service endpoint:

```text
Microsoft.Web
```

This allows App Service access restrictions to trust the Application Gateway subnet.

## 3. Create Log Analytics Workspace

1. Search for **Log Analytics workspaces**.
2. Select **Create**.
3. Use:

```text
Resource group: rg-insclaims-prod
Name: log-insclaims-prod
Region: East US
```

4. Select **Review + create**.
5. Select **Create**.

## 4. Create Application Insights

1. Search for **Application Insights**.
2. Select **Create**.
3. Use:

```text
Resource group: rg-insclaims-prod
Name: appi-insclaims-prod
Region: East US
Application type: Web
Workspace: log-insclaims-prod
```

4. Select **Review + create**.
5. Select **Create**.

After it is created, open it and copy the **Connection String**. You will use it later in App Service settings.

## 5. Create Azure Cosmos DB

1. Search for **Azure Cosmos DB**.
2. Select **Create**.
3. Choose **Azure Cosmos DB for NoSQL**.
4. Basics:

```text
Resource group: rg-insclaims-prod
Account name: cosmos-insclaims-<unique-suffix>
Location: East US
Capacity mode: Provisioned throughput
Apply Free Tier Discount: optional, if available
Limit total account throughput: optional for cost control
```

5. Global Distribution:

```text
Geo-redundancy: optional
Multi-region writes: disabled for simple deployment
Availability zones: optional if available
```

6. Networking:

For the simplest deployment:

```text
Connectivity method: Public endpoint
```

For stricter production:

```text
Connectivity method: Private endpoint
```

If using private endpoint, create it in:

```text
VNet: vnet-insclaims-prod
Subnet: private-endpoint-subnet
Private DNS zone: privatelink.documents.azure.com
```

7. Backup Policy:

```text
Periodic backup
Backup interval: 240 minutes
Retention: 8 hours or higher
```

8. Select **Review + create**.
9. Select **Create**.

### Create Cosmos Database And Container

1. Open the Cosmos DB account.
2. Go to **Data Explorer**.
3. Select **New Database**.
4. Use:

```text
Database id: insurance-claims
Provision database throughput: No
```

5. Select **OK**.
6. Under the database, select **New Container**.
7. Use:

```text
Database id: insurance-claims
Container id: claims
Partition key: /partitionKey
Throughput: 400 RU/s
```

8. Select **OK**.

### Copy Cosmos Values

Open the Cosmos DB account and go to **Keys**.

Copy:

```text
URI
Primary Key
```

These become:

```text
COSMOS_DB_ENDPOINT
COSMOS_DB_KEY
```

## 6. Create Storage Account For Documents

1. Search for **Storage accounts**.
2. Select **Create**.
3. Basics:

```text
Resource group: rg-insclaims-prod
Storage account name: stinsclaims<unique>
Region: East US
Performance: Standard
Redundancy: Read-access geo-zone-redundant storage (RA-GZRS)
```

If RA-GZRS is unavailable in your selected region, use:

```text
Read-access geo-redundant storage (RA-GRS)
```

4. Advanced:

```text
Require secure transfer: Enabled
Allow enabling anonymous access on individual containers: Disabled
Minimum TLS version: 1.2
```

5. Data protection:

Enable:

```text
Blob soft delete
Container soft delete
Versioning for blobs
```

Suggested retention:

```text
30 days
```

6. Networking:

For simple deployment:

```text
Public network access: Enabled from all networks
```

For stricter production, use private endpoint in:

```text
VNet: vnet-insclaims-prod
Subnet: private-endpoint-subnet
Private DNS zone: privatelink.blob.core.windows.net
```

7. Select **Review + create**.
8. Select **Create**.

### Create Blob Container

1. Open the Storage Account.
2. Go to **Data storage > Containers**.
3. Select **+ Container**.
4. Use:

```text
Name: insurance-documents
Anonymous access level: Private
```

5. Select **Create**.

### Copy Storage Connection String

1. Open the Storage Account.
2. Go to **Security + networking > Access keys**.
3. Select **Show**.
4. Copy a connection string.

This becomes:

```text
AZURE_STORAGE_CONNECTION_STRING
```

## 7. Create Key Vault

1. Search for **Key vaults**.
2. Select **Create**.
3. Basics:

```text
Resource group: rg-insclaims-prod
Key vault name: kv-insclaims-<unique>
Region: East US
Pricing tier: Standard
```

4. Access configuration:

```text
Permission model: Azure role-based access control
```

5. Recovery options:

```text
Soft delete: Enabled
Purge protection: Enabled
```

6. Networking:

For simple deployment:

```text
Public access: Enabled
```

For stricter production, use a private endpoint in:

```text
VNet: vnet-insclaims-prod
Subnet: private-endpoint-subnet
Private DNS zone: privatelink.vaultcore.azure.net
```

7. Select **Review + create**.
8. Select **Create**.

### Give Yourself Permission To Add Secrets

1. Open the Key Vault.
2. Go to **Access control (IAM)**.
3. Select **Add role assignment**.
4. Role:

```text
Key Vault Secrets Officer
```

5. Assign access to your signed-in user.
6. Select **Review + assign**.

### Add Secrets

Go to **Objects > Secrets** and create these secrets:

```text
cosmos-db-endpoint
cosmos-db-key
azure-storage-connection-string
session-secret
demo-user-password
demo-admin-password
```

Suggested values:

```text
cosmos-db-endpoint = Cosmos DB URI
cosmos-db-key = Cosmos DB Primary Key
azure-storage-connection-string = Storage Account connection string
session-secret = long random private value
demo-user-password = your demo user password
demo-admin-password = your demo admin password
```

## 8. Create App Service Plan

1. Search for **App Service plans**.
2. Select **Create**.
3. Use:

```text
Resource group: rg-insclaims-prod
Name: asp-insclaims-prod
Operating system: Linux
Region: East US
Pricing plan: Premium v3 P1V3
```

P1V3 is recommended because it supports production App Service features and VNet integration.

4. Select **Review + create**.
5. Select **Create**.

## 9. Create App Service

1. Search for **App Services**.
2. Select **Create**.
3. Basics:

```text
Resource group: rg-insclaims-prod
Name: app-insclaims-<unique>
Publish: Code
Runtime stack: Node 20 LTS
Operating System: Linux
Region: East US
App Service Plan: asp-insclaims-prod
```

4. Monitoring:

```text
Enable Application Insights: Yes
Application Insights: appi-insclaims-prod
```

5. Select **Review + create**.
6. Select **Create**.

## 10. Configure App Service Managed Identity

1. Open the App Service.
2. Go to **Identity**.
3. Under **System assigned**, turn status **On**.
4. Select **Save**.

Copy the Object ID if shown.

### Give App Service Access To Key Vault

1. Open Key Vault.
2. Go to **Access control (IAM)**.
3. Select **Add role assignment**.
4. Role:

```text
Key Vault Secrets User
```

5. Assign access to the App Service managed identity.
6. Select **Review + assign**.

## 11. Configure App Service Settings

1. Open the App Service.
2. Go to **Settings > Environment variables**.
3. Add these app settings:

```text
NODE_ENV=production
COSMOS_DB_DATABASE_NAME=insurance-claims
COSMOS_DB_CONTAINER_NAME=claims
AZURE_STORAGE_CONTAINER_NAME=insurance-documents
WEBSITE_NODE_DEFAULT_VERSION=~20
```

Add these using Key Vault references:

```text
COSMOS_DB_ENDPOINT=@Microsoft.KeyVault(VaultName=<key-vault-name>;SecretName=cosmos-db-endpoint)
COSMOS_DB_KEY=@Microsoft.KeyVault(VaultName=<key-vault-name>;SecretName=cosmos-db-key)
AZURE_STORAGE_CONNECTION_STRING=@Microsoft.KeyVault(VaultName=<key-vault-name>;SecretName=azure-storage-connection-string)
SESSION_SECRET=@Microsoft.KeyVault(VaultName=<key-vault-name>;SecretName=session-secret)
DEMO_USER_PASSWORD=@Microsoft.KeyVault(VaultName=<key-vault-name>;SecretName=demo-user-password)
DEMO_ADMIN_PASSWORD=@Microsoft.KeyVault(VaultName=<key-vault-name>;SecretName=demo-admin-password)
```

If Application Insights did not add the setting automatically, add:

```text
APPLICATIONINSIGHTS_CONNECTION_STRING=<Application Insights connection string>
```

4. Select **Apply**.

## 12. Configure App Service General Settings

1. Open the App Service.
2. Go to **Settings > Configuration > General settings**.
3. Set:

```text
Startup Command: npm start
HTTP version: 2.0
Always On: On
HTTPS Only: On
Minimum TLS version: 1.2
FTPS state: Disabled
```

4. Save.

## 13. Configure App Service VNet Integration

1. Open the App Service.
2. Go to **Networking**.
3. Under **Outbound traffic configuration**, select **VNet integration**.
4. Add VNet integration:

```text
Virtual network: vnet-insclaims-prod
Subnet: appservice-integration-subnet
```

5. Save.

## 14. Deploy The Node.js App

You can deploy from VS Code, Zip Deploy, GitHub Actions, or Azure CLI.

For Portal-friendly deployment:

1. Create a zip of the app folder.
2. Exclude:

```text
node_modules
.local-storage
.env
azure/.env.azure
azure/app-package.zip
```

3. Open the App Service.
4. Go to **Deployment Center**.
5. Choose your source, for example GitHub, Local Git, or external Git.

For manual zip deployment, Azure Portal support varies. Azure CLI is usually simpler:

```bash
az webapp deploy \
  --resource-group rg-insclaims-prod \
  --name <app-service-name> \
  --src-path app-package.zip \
  --type zip
```

## 15. Configure Health Check

1. Open the App Service.
2. Go to **Monitoring > Health check**.
3. Enable health check.
4. Path:

```text
/health
```

5. Save.

## 16. Create Public IP For Application Gateway

1. Search for **Public IP addresses**.
2. Select **Create**.
3. Use:

```text
Resource group: rg-insclaims-prod
Name: pip-insclaims-prod
Region: East US
SKU: Standard
Assignment: Static
```

4. Create.

## 17. Create Application Gateway With WAF

1. Search for **Application gateways**.
2. Select **Create**.
3. Basics:

```text
Resource group: rg-insclaims-prod
Name: agw-insclaims-prod
Region: East US
Tier: WAF V2
Enable autoscaling: optional
Instance count: 1
```

4. Virtual network:

```text
Virtual network: vnet-insclaims-prod
Subnet: appgw-subnet
```

5. Frontends:

```text
Frontend IP address type: Public
Public IP address: pip-insclaims-prod
```

6. Backends:

Add backend pool:

```text
Name: appservice-backend
Target type: App Services or FQDN
Target: <app-service-name>.azurewebsites.net
```

7. Configuration:

Add routing rule:

```text
Rule name: app-rule
Listener: HTTP listener on port 80
Backend target: appservice-backend
Backend settings protocol: HTTPS
Backend port: 443
Override with new host name: Yes
Pick host name from backend target: Yes
```

8. Health probe:

```text
Protocol: HTTPS
Path: /health
Use host name from backend HTTP settings: Yes
Interval: 30
Timeout: 30
Unhealthy threshold: 3
```

9. WAF policy:

```text
Mode: Prevention
Rule set: OWASP 3.2
```

10. Create the Application Gateway.

## 18. Restrict App Service To Application Gateway

1. Open the App Service.
2. Go to **Networking**.
3. Under **Inbound traffic configuration**, open **Access restrictions**.
4. Add allow rule:

```text
Name: Allow-AppGateway
Action: Allow
Type: Virtual Network
Virtual network: vnet-insclaims-prod
Subnet: appgw-subnet
Priority: 100
```

5. Set unmatched rule action:

```text
Deny
```

6. Save.

Now users should access the app through Application Gateway, not directly through the App Service URL.

## 19. Configure Diagnostic Settings

Configure diagnostics to send logs to `log-insclaims-prod`.

### App Service

1. Open App Service.
2. Go to **Monitoring > Diagnostic settings**.
3. Add diagnostic setting.
4. Send to Log Analytics.
5. Enable:

```text
AppServiceHTTPLogs
AppServiceConsoleLogs
AppServiceAppLogs
AllMetrics
```

### Application Gateway

Enable:

```text
ApplicationGatewayAccessLog
ApplicationGatewayPerformanceLog
ApplicationGatewayFirewallLog
AllMetrics
```

### Cosmos DB

Enable:

```text
DataPlaneRequests
QueryRuntimeStatistics
Requests metrics
```

### Storage Account Blob Service

Enable blob diagnostics:

```text
StorageRead
StorageWrite
StorageDelete
Transaction metrics
```

## 20. Create Alerts

In **Azure Monitor > Alerts**, create alert rules for:

```text
App Service HTTP 5xx > threshold
Application Gateway unhealthy backend count > 0
Application Gateway WAF blocked request spike
Cosmos DB 429 throttled requests > threshold
Storage availability below threshold
App Service CPU > 80%
App Service memory > 80%
```

Create an **Action Group** for email/SMS/Teams/ITSM notifications.

## 21. Validate The Deployment

### App Service Health

Open:

```text
https://<app-service-name>.azurewebsites.net/health
```

Before access restrictions, it should return:

```json
{"status":"ok"}
```

After access restrictions, direct App Service access may be blocked. Use Application Gateway instead.

### Application Gateway Health

1. Open Application Gateway.
2. Go to **Backend health**.
3. Confirm backend status is **Healthy**.

### Public App URL

Open:

```text
http://<application-gateway-public-ip>
```

You should see the login page.

### Login Test

Use your configured demo credentials:

```text
user / <demo-user-password>
admin / <demo-admin-password>
```

### Claim Test

1. Login as user.
2. Submit a claim.
3. Upload a document.
4. Login as admin.
5. Confirm the claim appears.
6. Add feedback.
7. Login as user again and confirm feedback is visible.

### Data Validation

Cosmos DB:

1. Open Cosmos DB.
2. Go to **Data Explorer**.
3. Open:

```text
insurance-claims > claims > Items
```

You should see user and claim documents.

Blob Storage:

1. Open Storage Account.
2. Go to:

```text
Containers > insurance-documents
```

You should see uploaded files under:

```text
uploads/{userId}/{claimId}/
```

## 22. Production Hardening Checklist

- Replace demo password login with Microsoft Entra ID.
- Add HTTPS listener and certificate on Application Gateway.
- Add custom domain.
- Use private endpoints for Cosmos DB, Blob Storage, and Key Vault.
- Consider App Service private endpoint for stricter inbound isolation.
- Move application code from keys/connection strings to managed identity SDK authentication.
- Add alert action groups.
- Review WAF logs for false positives.
- Run restore tests for Cosmos DB and Blob Storage.
- Define RTO and RPO.
- Review costs after deployment.

## 23. Cleanup From Portal

For a demo environment:

1. Open **Resource groups**.
2. Select:

```text
rg-insclaims-prod
```

3. Select **Delete resource group**.
4. Type the resource group name to confirm.
5. Delete.

This deletes the app, database, storage account, uploaded files, Key Vault, networking, logs, and Application Gateway.
