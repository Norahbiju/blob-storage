# Azure From-Scratch Setup

This guide describes the Azure resources needed for the insurance claims app with OCR validation, temporary Blob staging, Azure Functions, Azure Service Bus Queue email notifications, Cosmos DB, and final Blob Storage.

## Actual Norah Deployment

Created in:

```text
Azure user: norahelizabethbiju15@gmail.com
Subscription ID: de6d42ab-61dd-4743-a7de-166cd3281198
Tenant ID: e273e7a6-0676-4113-8575-ca2b6f3dd2ad
Region: Central India
Resource group: rg-insurance-prod-cin
Unique suffix: 4rwl6d
```

Created resources:

```text
Storage account: stinsurance4rwl6d
Blob containers: insurance-documents, insurance-documents-staging
Cosmos DB account: cosmos-insurance-4rwl6d
Cosmos database/container: insurance-claims / claims
Service Bus namespace: sb-insurance-4rwl6d
Service Bus queue: claim-validation-mails
Key Vault: kv-insurance-4rwl6d
Log Analytics workspace: log-insurance-prod-cin
Application Insights: appi-insurance-prod-cin
App Service Plan: asp-insurance-prod-cin
Web App: app-insurance-4rwl6d
Function App: func-insurance-4rwl6d
Virtual network: vnet-insurance-prod-cin
Public IP: pip-insurance-prod-cin
Application Gateway public IP: 4.213.179.123
WAF policy: waf-insurance-prod-cin
Application Gateway: agw-insurance-prod-cin
```

Configuration completed:

```text
Secrets were stored in Key Vault.
Web App and Function App system-assigned identities were enabled.
Both identities were granted Key Vault secret get/list permissions.
Web App settings were configured with Key Vault references.
Function App settings were configured with Key Vault references, except AzureWebJobsStorage, which is a direct app setting because Azure Functions deployment/runtime must parse it as a storage connection string.
Staging Blob lifecycle cleanup deletes old staged uploads after 1 day.
Application Gateway backend points to app-insurance-4rwl6d.azurewebsites.net.
Application Gateway backend HTTP settings use HTTPS 443 and pick host name from backend address.
Application Gateway health probe uses /health.
WAF policy is enabled in Detection mode.
```

Deployment note:

```text
The local machine's proxy/TLS certificate chain blocked Kudu zip deployment to App Service and Function App.
The infrastructure is created and configured. GitHub Actions workflows are included for deployment.
Generated local deployment packages:
  azure/webapp-norah.zip
  azure/functions-norah.zip
```

## GitHub Actions Deployment

The repository includes:

```text
.github/workflows/deploy-webapp.yml
.github/workflows/deploy-functions.yml
```

Add these GitHub repository secrets:

```text
AZURE_WEBAPP_PUBLISH_PROFILE
AZURE_FUNCTIONAPP_PUBLISH_PROFILE
```

To get the Web App publish profile:

```text
Azure Portal
-> App Services
-> app-insurance-4rwl6d
-> Overview
-> Download publish profile
```

Copy the full XML file content into the GitHub secret:

```text
AZURE_WEBAPP_PUBLISH_PROFILE
```

To get the Function App publish profile:

```text
Azure Portal
-> Function App
-> func-insurance-4rwl6d
-> Overview
-> Download publish profile
```

Copy the full XML file content into the GitHub secret:

```text
AZURE_FUNCTIONAPP_PUBLISH_PROFILE
```

After both secrets are added, pushing to `master` or manually running the workflows from the GitHub Actions tab deploys:

```text
Web App: app-insurance-4rwl6d
Function App: func-insurance-4rwl6d
```

## Naming Convention

Use one short environment code and one short app code consistently.

Recommended values:

```text
App code: insurance
Environment: prod
Region: centralindia
Unique suffix: <6 lowercase letters/numbers>
```

Example names:

```text
Resource group: rg-insurance-prod-cin
Storage account: stinsurance<suffix>
Cosmos DB account: cosmos-insurance-<suffix>
Key Vault: kv-insurance-<suffix>
App Service Plan: asp-insurance-prod-cin
App Service: app-insurance-<suffix>
Function App: func-insurance-<suffix>
Service Bus namespace: sb-insurance-<suffix>
Service Bus queue: claim-validation-mails
Application Insights: appi-insurance-prod-cin
Log Analytics workspace: log-insurance-prod-cin
Virtual network: vnet-insurance-prod-cin
Application Gateway: agw-insurance-prod-cin
WAF policy: waf-insurance-prod-cin
Public IP: pip-insurance-prod-cin
```

Storage account names must be globally unique, lowercase, and contain only letters and numbers.

## Credentials And Values Needed

Do not share your Azure password directly. Run `az login` interactively when CLI access is needed.

Values needed from you:

```text
Azure subscription ID
Azure tenant ID, if you have more than one tenant
Preferred Azure region, or confirm eastus/westus2
Unique suffix for globally unique resource names, or permission for me to choose one
OCR.Space API key
SMTP host
SMTP port
SMTP secure flag: true for implicit TLS, false for STARTTLS
SMTP username
SMTP password or app password
Verified sender email address for EMAIL_FROM
Demo user recipient email for DEMO_USER_EMAIL
Demo admin recipient email for DEMO_ADMIN_EMAIL
Demo user password, if replacing user123
Demo admin password, if replacing admin123
Session secret, or permission for me to generate one
Custom domain name, optional
TLS certificate source for Application Gateway HTTPS, optional
```

If using Azure Communication Services Email instead of SMTP, provide:

```text
Azure Communication Services connection string
Verified sender address/domain
```

The current Function implementation uses SMTP through Nodemailer.

## Resource Creation In Azure Portal

### 1. Resource Group

1. Open Azure Portal.
2. Search for `Resource groups`.
3. Select `Create`.
4. Set:

```text
Subscription: your subscription
Resource group: rg-insurance-prod-cin
Region: Central India
```

5. Select `Review + create`.
6. Select `Create`.

### 2. Log Analytics Workspace

1. Search for `Log Analytics workspaces`.
2. Select `Create`.
3. Set:

```text
Resource group: rg-insurance-prod-cin
Name: log-insurance-prod-cin
Region: Central India
```

4. Select `Review + create`.
5. Select `Create`.

### 3. Application Insights

1. Search for `Application Insights`.
2. Select `Create`.
3. Set:

```text
Resource group: rg-insurance-prod-cin
Name: appi-insurance-prod-cin
Region: Central India
Resource mode: Workspace-based
Log Analytics workspace: log-insurance-prod-cin
```

4. Select `Review + create`.
5. Select `Create`.

### 4. Storage Account

1. Search for `Storage accounts`.
2. Select `Create`.
3. Set:

```text
Resource group: rg-insurance-prod-cin
Storage account name: stinsurance<suffix>
Region: Central India
Performance: Standard
Redundancy: RA-GRS or GRS
```

4. Select `Review + create`.
5. Select `Create`.
6. Open the storage account.
7. Go to `Data storage` -> `Containers`.
8. Create these private containers:

```text
insurance-documents
insurance-documents-staging
```

9. Go to `Data management` -> `Lifecycle management`.
10. Add a rule for `insurance-documents-staging`:

```text
If base blobs were last modified more than 1 day ago:
Delete blob
```

This is a safety net. The Function deletes staged blobs immediately after processing.

### 5. Cosmos DB

1. Search for `Azure Cosmos DB`.
2. Select `Create`.
3. Choose `Azure Cosmos DB for NoSQL`.
4. Set:

```text
Resource group: rg-insurance-prod-cin
Account name: cosmos-insurance-<suffix>
Region: Central India
Capacity mode: Serverless or Provisioned throughput
```

5. Select `Review + create`.
6. Select `Create`.
7. Open the Cosmos DB account.
8. Go to `Data Explorer`.
9. Create database:

```text
Database id: insurance-claims
```

10. Create container:

```text
Container id: claims
Partition key: /partitionKey
```

### 6. Service Bus Queue

1. Search for `Service Bus`.
2. Select `Create`.
3. Set:

```text
Resource group: rg-insurance-prod-cin
Namespace name: sb-insurance-<suffix>
Location: Central India
Pricing tier: Basic or Standard
```

4. Select `Review + create`.
5. Select `Create`.
6. Open the namespace.
7. Go to `Entities` -> `Queues`.
8. Select `+ Queue`.
9. Set:

```text
Name: claim-validation-mails
Lock duration: 30 seconds
Max delivery count: 10
```

10. Select `Create`.

Use a queue only. Do not create a topic/subscription for this flow.

### 7. Key Vault

1. Search for `Key vaults`.
2. Select `Create`.
3. Set:

```text
Resource group: rg-insurance-prod-cin
Key vault name: kv-insurance-<suffix>
Region: Central India
Permission model: Azure role-based access control
```

4. Select `Review + create`.
5. Select `Create`.
6. Add secrets:

```text
azure-storage-connection-string
cosmos-db-endpoint
cosmos-db-key
ocr-space-api-key
service-bus-connection
smtp-host
smtp-user
smtp-pass
email-from
demo-user-email
demo-admin-email
session-secret
demo-user-password
demo-admin-password
```

### 8. App Service Plan

1. Search for `App Service plans`.
2. Select `Create`.
3. Set:

```text
Resource group: rg-insurance-prod-cin
Name: asp-insurance-prod-cin
Operating system: Linux
Region: Central India
Pricing plan: Basic B1 or higher
```

4. Select `Review + create`.
5. Select `Create`.

### 9. App Service

1. Search for `App Services`.
2. Select `Create`.
3. Set:

```text
Resource group: rg-insurance-prod-cin
Name: app-insurance-<suffix>
Publish: Code
Runtime stack: Node 22 LTS
Operating system: Linux
Region: Central India
App Service Plan: asp-insurance-prod-cin
```

4. Select `Review + create`.
5. Select `Create`.
6. Open the App Service.
7. Go to `Identity`.
8. Turn on `System assigned managed identity`.
9. Go to `Environment variables`.
10. Add:

```text
NODE_ENV=production
WEBSITE_NODE_DEFAULT_VERSION=22-lts
COSMOS_DB_ENDPOINT=<cosmos endpoint or Key Vault reference>
COSMOS_DB_KEY=<cosmos key or Key Vault reference>
COSMOS_DB_DATABASE_NAME=insurance-claims
COSMOS_DB_CONTAINER_NAME=claims
AZURE_STORAGE_CONNECTION_STRING=<storage connection string or Key Vault reference>
AZURE_STORAGE_CONTAINER_NAME=insurance-documents
AZURE_STORAGE_STAGING_CONTAINER_NAME=insurance-documents-staging
SESSION_SECRET=<session secret or Key Vault reference>
DEMO_USER_PASSWORD=<demo user password or Key Vault reference>
DEMO_ADMIN_PASSWORD=<demo admin password or Key Vault reference>
DEMO_USER_EMAIL=<user notification email or Key Vault reference>
DEMO_ADMIN_EMAIL=<admin email or Key Vault reference>
APPLICATIONINSIGHTS_CONNECTION_STRING=<app insights connection string>
```

11. Set startup command:

```text
npm start
```

### 10. Function App

1. Search for `Function App`.
2. Select `Create`.
3. Set:

```text
Resource group: rg-insurance-prod-cin
Function App name: func-insurance-<suffix>
Runtime stack: Node.js
Version: 20 or 22
Region: Central India
Hosting option: Consumption or App Service plan
Storage account: stinsurance<suffix>
```

4. Select `Review + create`.
5. Select `Create`.
6. Open the Function App.
7. Go to `Identity`.
8. Turn on `System assigned managed identity`.
9. Go to `Environment variables`.
10. Add:

```text
AzureWebJobsStorage=<storage connection string>
FUNCTIONS_WORKER_RUNTIME=node
COSMOS_DB_ENDPOINT=<cosmos endpoint or Key Vault reference>
COSMOS_DB_KEY=<cosmos key or Key Vault reference>
COSMOS_DB_DATABASE_NAME=insurance-claims
COSMOS_DB_CONTAINER_NAME=claims
AZURE_STORAGE_CONNECTION_STRING=<storage connection string or Key Vault reference>
AZURE_STORAGE_CONTAINER_NAME=insurance-documents
AZURE_STORAGE_STAGING_CONTAINER_NAME=insurance-documents-staging
OCR_SPACE_API_KEY=<OCR.Space API key or Key Vault reference>
OCR_SPACE_API_URL=https://api.ocr.space/parse/image
OCR_SPACE_LANGUAGE=eng
OCR_SPACE_ENGINE=2
SERVICE_BUS_CONNECTION=<Service Bus connection string or Key Vault reference>
SERVICE_BUS_MAIL_QUEUE_NAME=claim-validation-mails
SMTP_HOST=<SMTP host or Key Vault reference>
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USER=<SMTP user or Key Vault reference>
SMTP_PASS=<SMTP password or Key Vault reference>
EMAIL_FROM=<verified sender or Key Vault reference>
APPLICATIONINSIGHTS_CONNECTION_STRING=<app insights connection string>
```

### 11. Network And Application Gateway

1. Search for `Virtual networks`.
2. Select `Create`.
3. Set:

```text
Resource group: rg-insurance-prod-cin
Name: vnet-insurance-prod-cin
Region: Central India
Address space: 10.42.0.0/16
```

4. Add subnets:

```text
appgw-subnet: 10.42.1.0/24
appservice-integration-subnet: 10.42.2.0/24
private-endpoint-subnet: 10.42.3.0/24
```

5. Search for `Public IP addresses`.
6. Create:

```text
Name: pip-insurance-prod-cin
SKU: Standard
Region: Central India
```

7. Search for `Web Application Firewall policies`.
8. Create:

```text
Name: waf-insurance-prod-cin
Region: Central India
Policy for: Application Gateway
Mode: Detection initially
Managed rules: OWASP 3.2
```

9. Search for `Application gateways`.
10. Create:

```text
Name: agw-insurance-prod-cin
Tier: WAF V2
Region: Central India
Virtual network: vnet-insurance-prod-cin
Subnet: appgw-subnet
Public IP: pip-insurance-prod-cin
Backend target: app-insurance-<suffix>.azurewebsites.net
Backend protocol: HTTPS
Backend port: 443
Pick host name from backend target: Yes
Health probe path: /health
WAF policy: waf-insurance-prod-cin
```

11. After validation, switch WAF from `Detection` to `Prevention`.

### 12. Deploy Code

Deploy the web app from the repository root.

Deploy the Function App from the `functions` folder.

Before deploying Functions:

```powershell
cd functions
npm install
```

### 13. Validation

1. Open the App Service `/health` endpoint.
2. Open the Application Gateway public endpoint.
3. Login as the demo user.
4. Submit a claim with a PDF, PNG, or JPEG document.
5. Confirm the claim starts as `PendingValidation`.
6. Confirm the document appears in `insurance-documents-staging`.
7. Wait for the Function to run.
8. Confirm the staged blob is deleted.
9. If validation passed, confirm the blob exists in `insurance-documents`.
10. If validation failed, confirm no final blob exists.
11. Confirm claim validation status changed in Cosmos DB.
12. Confirm a message was consumed from `claim-validation-mails`.
13. Confirm the user receives a pass/fail email.
