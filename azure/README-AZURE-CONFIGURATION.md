# Azure Configuration Details

This document explains the Azure configuration for the insurance claims application. It is written as a reference for what was created, how the resources are connected, and what each setting is doing.

The deployment is hosted in:

```text
Resource group: rg-insclaims-prod
Primary network region: East US
App Service region: West US 2
```

## Architecture

```text
Browser
  -> Public IP address
  -> Azure Application Gateway with WAF
  -> Azure App Service running the Node.js application
  -> Azure Functions for document OCR validation and email queue processing
  -> Azure Cosmos DB for application data
  -> Azure Blob Storage staging container for uploaded documents awaiting validation
  -> Azure Blob Storage final container for validated documents
  -> Azure Service Bus Queue for validation email messages
  -> Azure Key Vault for secrets
  -> Application Insights and Log Analytics for monitoring
```

The Application Gateway is the intended public entry point. The App Service runs the application code and stages uploaded documents. Azure Functions call OCR.Space, validate extracted data, promote approved documents to the final Blob container, delete staged blobs after processing, and enqueue email notifications. Cosmos DB stores user and claim records. Blob Storage stores staged and validated claim documents. Azure Service Bus uses a queue, not a topic/subscription model, for validation email messages. Key Vault stores secret values used by the application. Application Insights and Log Analytics collect telemetry, logs, and diagnostics.

## Resource Inventory

| Purpose | Resource name | Region |
| --- | --- | --- |
| Resource group | `rg-insclaims-prod` | East US |
| Virtual network | `vnet-insclaims-prod` | East US |
| Log Analytics workspace | `log-insclaims-prod` | East US |
| Application Insights | `appi-insclaims-prod` | East US |
| Cosmos DB account | `cosmos-insclaims-de6d42` | East US |
| Storage account | `stinsclaimsde6d42` | East US |
| Function App | `func-insclaims-prod` | East US |
| Service Bus namespace | `sb-insclaims-prod` | East US |
| Service Bus queue | `claim-validation-mails` | East US |
| Key Vault | `kv-insclaims-de6d42` | East US |
| App Service Plan | `asp-insclaims-prod` | West US 2 |
| App Service | `app-insclaims-de6d42` | West US 2 |
| Public IP | `pip-insclaims-prod` | East US |
| Application Gateway | `agw-insclaims-prod` | East US |
| WAF policy | `waf-insclaims-prod` | East US |

## Virtual Network

The virtual network is:

```text
Name: vnet-insclaims-prod
Address space: 10.42.0.0/16
Region: East US
```

It contains three subnets:

| Subnet | CIDR | Purpose |
| --- | --- | --- |
| `appgw-subnet` | `10.42.1.0/24` | Dedicated subnet for Application Gateway |
| `appservice-integration-subnet` | `10.42.2.0/24` | App Service outbound VNet integration |
| `private-endpoint-subnet` | `10.42.3.0/24` | Reserved for private endpoints |

The `appservice-integration-subnet` is delegated to:

```text
Microsoft.Web/serverFarms
```

That delegation allows App Service to integrate with the subnet for outbound network access.

The `appgw-subnet` has the following service endpoint enabled:

```text
Microsoft.Web
```

That service endpoint is useful when App Service access restrictions are configured to trust traffic from the Application Gateway subnet.

## Application Gateway

The Application Gateway is:

```text
Name: agw-insclaims-prod
SKU: WAF_v2
Capacity: 1
Region: East US
Operational state: Running
Provisioning state: Succeeded
```

It uses the public IP address:

```text
pip-insclaims-prod
```

The Application Gateway is placed in:

```text
Virtual network: vnet-insclaims-prod
Subnet: appgw-subnet
```

### Frontend Listeners

The Application Gateway has listeners for:

```text
HTTP on port 80
HTTPS on port 443
```

HTTP is useful for initial validation. HTTPS is present for secure listener configuration.

### Backend Pool

The backend pool points to the App Service hostname:

```text
app-insclaims-de6d42.azurewebsites.net
```

This means requests received by Application Gateway are routed to the Node.js app running in Azure App Service.

### Backend HTTP Settings

The backend settings use:

```text
Protocol: HTTPS
Port: 443
Pick host name from backend address: true
```

Picking the host name from the backend address is important for App Service. App Service expects requests to use its Azure website hostname unless a custom domain is configured.

### Health Probe

The Application Gateway health probe is:

```text
Name: app-health-probe
Protocol: HTTPS
Path: /health
```

The app exposes `/health` so Application Gateway can determine whether the backend is healthy. If the probe fails repeatedly, Application Gateway marks the backend unhealthy and may return `502 Bad Gateway`.

## Web Application Firewall

The WAF policy is:

```text
Name: waf-insclaims-prod
State: Enabled
Rule set: OWASP 3.2
Mode: Detection
```

Detection mode logs suspicious requests but does not block them. This is useful during validation because it lets you review what the WAF would have blocked without interrupting normal traffic.

For a stricter production configuration, change the mode to:

```text
Prevention
```

Prevention mode actively blocks requests that match WAF rules. Before switching to prevention, review the WAF logs for false positives.

## App Service Plan

The App Service Plan is:

```text
Name: asp-insclaims-prod
Operating system: Linux
Region: West US 2
```

The plan hosts the App Service. The portal guide originally describes East US for the App Service Plan, but the live deployment is in West US 2.

## App Service

The App Service is:

```text
Name: app-insclaims-de6d42
Host name: app-insclaims-de6d42.azurewebsites.net
Region: West US 2
State: Running
HTTPS only: true
```

### Runtime And General Settings

The current runtime and platform settings are:

```text
Runtime: NODE|22-lts
Startup command: npm start
Always On: true
HTTP/2: true
Minimum TLS version: 1.2
FTPS state: Disabled
```

The portal guide describes Node.js 20, but the live App Service is configured for Node.js 22 LTS.

`Always On` keeps the application warm so it is less likely to sleep between requests. `HTTPS only` and minimum TLS 1.2 improve transport security. Disabling FTPS reduces an unnecessary management surface.

### Managed Identity

The App Service has a system-assigned managed identity:

```text
Type: SystemAssigned
Principal ID: 28ddbc58-426a-47f3-ae8c-d4f13d57dd37
```

This identity is used so the app can access Azure resources without storing Azure user credentials. It is especially important for Key Vault access.

### Application Settings

The App Service has settings for runtime behavior, database access, storage access, monitoring, and deployment behavior.

Runtime and app behavior:

```text
NODE_ENV
WEBSITE_NODE_DEFAULT_VERSION
```

Cosmos DB:

```text
COSMOS_DB_ENDPOINT
COSMOS_DB_KEY
COSMOS_DB_DATABASE_NAME
COSMOS_DB_CONTAINER_NAME
```

Blob Storage:

```text
AZURE_STORAGE_CONNECTION_STRING
AZURE_STORAGE_CONTAINER_NAME
AZURE_STORAGE_STAGING_CONTAINER_NAME
```

Authentication/session values:

```text
SESSION_SECRET
DEMO_USER_PASSWORD
DEMO_ADMIN_PASSWORD
```

Monitoring:

```text
APPLICATIONINSIGHTS_CONNECTION_STRING
```

Deployment settings:

```text
WEBSITE_RUN_FROM_PACKAGE
SCM_DO_BUILD_DURING_DEPLOYMENT
ENABLE_ORYX_BUILD
```

Sensitive values should be stored in Key Vault and referenced by App Service settings. The secret names currently present in Key Vault are listed in the Key Vault section below.

### Access Restrictions

The intended production pattern is:

```text
Allow inbound traffic from Application Gateway
Deny direct public access to App Service
```

The live access restriction state currently allows direct access:

```text
Default action: Allow
Rule: Allow all
```

To fully enforce the intended architecture, add an allow rule for the Application Gateway subnet and set unmatched traffic to deny:

```text
Allow:
  Name: Allow-AppGateway
  Type: Virtual Network
  Virtual network: vnet-insclaims-prod
  Subnet: appgw-subnet
  Priority: 100

Default unmatched action:
  Deny
```

After this change, users should access the app through Application Gateway rather than the direct `azurewebsites.net` URL.

## Cosmos DB

The Cosmos DB account is:

```text
Name: cosmos-insclaims-de6d42
API: NoSQL
Region: East US
```

The application database and container are:

```text
Database: insurance-claims
Container: claims
Partition key: /partitionKey
```

Cosmos DB stores application data such as:

```text
Users
Claims
Claim status
Admin feedback
Document metadata
```

The app connects to Cosmos DB using:

```text
COSMOS_DB_ENDPOINT
COSMOS_DB_KEY
COSMOS_DB_DATABASE_NAME
COSMOS_DB_CONTAINER_NAME
```

For stronger production security, the app should eventually use managed identity with Azure Cosmos DB role-based access control instead of account keys.

## Blob Storage

The Storage Account is:

```text
Name: stinsclaimsde6d42
Region: East US
```

The intended final blob container is:

```text
insurance-documents
```

The intended staging blob container is:

```text
insurance-documents-staging
```

The app uploads user documents to the staging container first. Uploaded staged files are expected to be organized under paths similar to:

```text
uploads/{userId}/{claimId}/
```

The document validation Function is triggered by staged blobs. If OCR extraction and validation pass, the Function uploads the document to the final `insurance-documents` container using the same `uploads/{userId}/{claimId}/...` blob name and updates the claim metadata. If validation fails, the document is not copied to the final container.

The Function deletes the staged blob after both passed and failed validation. Add a Storage lifecycle management rule for `insurance-documents-staging` to delete blobs older than 1 day as a safety net for interrupted executions.

The app connects to storage using:

```text
AZURE_STORAGE_CONNECTION_STRING
AZURE_STORAGE_CONTAINER_NAME
AZURE_STORAGE_STAGING_CONTAINER_NAME
```

For stronger production security, the app should eventually use managed identity with Blob Storage RBAC instead of a storage account connection string.

## Azure Functions

The Function App should run the code in the repository `functions` folder.

It contains:

```text
DocumentValidationFunction
MailQueueFunction
```

`DocumentValidationFunction` is triggered by staged blobs:

```text
insurance-documents-staging/uploads/{userId}/{claimId}/{fileName}
```

It performs this workflow:

```text
1. Load claim metadata from Cosmos DB.
2. Send the staged document to OCR.Space.
3. Validate extracted OCR text against the submitted claim data.
4. If validation passes, write the document to insurance-documents.
5. If validation fails, leave the final container unchanged.
6. Update the claim validation status in Cosmos DB.
7. Send one email notification message to the Service Bus queue.
8. Delete the staged blob.
```

The current validation checks:

```text
Readable OCR text
Supported MIME type: PDF, PNG, JPEG
Policy number present in OCR text
Claim amount present in OCR text
Contact number present in OCR text
```

`MailQueueFunction` is triggered by the Service Bus queue and sends the pass/fail email through SMTP.

Required Function App settings:

```text
AzureWebJobsStorage
FUNCTIONS_WORKER_RUNTIME=node
COSMOS_DB_ENDPOINT
COSMOS_DB_KEY
COSMOS_DB_DATABASE_NAME
COSMOS_DB_CONTAINER_NAME
AZURE_STORAGE_CONNECTION_STRING
AZURE_STORAGE_CONTAINER_NAME
AZURE_STORAGE_STAGING_CONTAINER_NAME
OCR_SPACE_API_KEY
OCR_SPACE_API_URL
SERVICE_BUS_CONNECTION
SERVICE_BUS_MAIL_QUEUE_NAME
SMTP_HOST
SMTP_PORT
SMTP_SECURE
SMTP_USER
SMTP_PASS
EMAIL_FROM
```

## Azure Service Bus

Use a queue-based model:

```text
Namespace: sb-insclaims-prod
Queue: claim-validation-mails
```

Do not create a Service Bus topic/subscription for this flow. The document validation Function sends a single message to `claim-validation-mails`, and the mail Function consumes from that same queue.

## Key Vault

The Key Vault is:

```text
Name: kv-insclaims-de6d42
Region: East US
```

The following secrets exist:

```text
azure-storage-connection-string
cosmos-db-endpoint
cosmos-db-key
demo-admin-password
demo-user-password
email-from
ocr-space-api-key
service-bus-connection
smtp-host
smtp-pass
smtp-user
session-secret
```

The App Service should read these secrets through Key Vault references in App Service application settings. This avoids placing raw secret values directly in code or deployment scripts.

The App Service managed identity needs the following Key Vault role:

```text
Key Vault Secrets User
```

Human operators who need to create or update secrets need a stronger role such as:

```text
Key Vault Secrets Officer
```

## Application Insights And Log Analytics

Application Insights is:

```text
Name: appi-insclaims-prod
Region: East US
Workspace: log-insclaims-prod
```

Log Analytics is:

```text
Name: log-insclaims-prod
Region: East US
```

Application Insights collects application telemetry such as requests, failures, dependencies, and performance data. Log Analytics stores diagnostic data and makes it queryable.

Application Gateway diagnostics are configured to send the following to Log Analytics:

```text
ApplicationGatewayAccessLog
ApplicationGatewayPerformanceLog
ApplicationGatewayFirewallLog
AllMetrics
```

Useful things to monitor include:

```text
App Service 5xx responses
Application Gateway backend health
Application Gateway WAF matches
Cosmos DB throttling
Storage failures
App Service CPU and memory
```

## Deployment Package

The application is deployed to App Service as a Node.js application. The App Service startup command is:

```text
npm start
```

The Azure folder contains deployment packages:

```text
azure/app-package.zip
azure/app-package-with-modules.zip
```

The app settings also include deployment-related values:

```text
WEBSITE_RUN_FROM_PACKAGE
SCM_DO_BUILD_DURING_DEPLOYMENT
ENABLE_ORYX_BUILD
```

These settings control whether Azure runs the app directly from a package and whether Azure's Oryx build system installs/builds application dependencies during deployment.

## Validation Checklist

Use these checks after deployment or configuration changes.

### App Service

Open:

```text
https://app-insclaims-de6d42.azurewebsites.net/health
```

Expected response:

```json
{"status":"ok"}
```

If App Service access restrictions are enabled, direct access to this URL may be blocked. In that case, validate through Application Gateway.

### Application Gateway

In the Azure Portal:

```text
Application Gateway -> Backend health
```

Expected backend status:

```text
Healthy
```

If it is unhealthy, check:

```text
Backend target hostname
Backend HTTPS settings
Health probe path /health
Host name override setting
App Service health endpoint
```

### Public App

Open the Application Gateway public endpoint:

```text
http://<application-gateway-public-ip>
```

Expected result:

```text
The application login page loads
```

### Application Flow

Validate the application itself:

```text
1. Login as a demo user.
2. Submit a claim.
3. Upload a document.
4. Confirm the claim initially shows PendingValidation.
5. Wait for the Azure Function to process the staged document.
6. Confirm validation changes to passed or failed.
7. If validation passed, confirm the document download link is visible.
8. Login as admin.
9. Confirm the claim and validation details are visible.
10. Add admin feedback.
11. Login as the user again.
12. Confirm the feedback is visible.
```

### Data Checks

Cosmos DB:

```text
cosmos-insclaims-de6d42
  -> Data Explorer
  -> insurance-claims
  -> claims
  -> Items
```

Blob Storage:

```text
stinsclaimsde6d42
  -> Containers
  -> insurance-documents
  -> insurance-documents-staging
```

Expected Blob state:

```text
Passed validation: final blob exists in insurance-documents, staged blob is deleted
Failed validation: no final blob exists, staged blob is deleted
Interrupted run: lifecycle policy deletes old staged blobs
```

## Current Gaps And Recommended Hardening

The core environment is in place, but these items should be reviewed before treating it as production hardened:

| Area | Current state | Recommended state |
| --- | --- | --- |
| WAF mode | `Detection` | Switch to `Prevention` after reviewing false positives |
| App Service inbound access | Allows direct public access | Restrict to Application Gateway subnet |
| App runtime | Node.js 22 LTS | Keep if tested, or align docs/scripts to Node.js 22 |
| App Service region | West US 2 | Accept as-is or align future docs to deployed region |
| Cosmos DB authentication | Account key | Move to managed identity and Cosmos DB RBAC |
| Storage authentication | Connection string | Move to managed identity and Storage Blob RBAC |
| Private endpoints | Subnet reserved | Add private endpoints for Cosmos DB, Storage, and Key Vault |
| Custom domain | Not documented as active | Add custom domain and certificate |
| HTTPS through gateway | Listener exists | Confirm certificate and redirect policy for production |

## Operational Notes

Application Gateway WAF v2 has a meaningful fixed cost, even when traffic is low. For demo environments, delete the resource group when it is no longer needed:

```text
rg-insclaims-prod
```

Deleting the resource group removes the App Service, Application Gateway, Cosmos DB account, Storage Account, Key Vault, networking resources, logs, and uploaded files.
