# Insurance Claims Portal

A small monolithic insurance claims application with user and admin access. It stores users, claims, statuses, and feedback in Azure Cosmos DB. Uploaded documents are staged, OCR-validated by Azure Functions, and only approved documents are stored in the final Azure Blob Storage container.

## Features

- Login as `user` or `admin`
- Users can submit many insurance claim forms
- Users can upload one supporting document per claim for OCR validation
- Users can view submitted claims, documents, status, and admin feedback
- Admins can view users and all submitted claims
- Admins can download uploaded files and save claim feedback
- Azure Functions validate staged documents with OCR.Space before final Blob Storage persistence
- `/health` endpoint for Azure Application Gateway health probes

## Run Locally

```powershell
npm install
Copy-Item .env.example .env
npm start
```

Open `http://localhost:3000`.

Demo credentials:

- User: `user` / `user123`
- Admin: `admin` / `admin123`

If Azure settings are blank, metadata is stored in `.local-storage/db.json`, staged documents are stored under `.local-storage/staging`, and approved documents are stored under `.local-storage/uploads`.

## Azure Cosmos DB Setup

Create an Azure Cosmos DB account using the NoSQL API. The app can create the database and container automatically when the connection settings are present.

Recommended values:

```text
Database: insurance-claims
Container: claims
Partition key: /partitionKey
```

The app stores these document types in Cosmos DB:

```text
type=user   partitionKey=user
type=claim  partitionKey={userId}
```

## Azure Blob Storage Setup

Create a Storage Account with geo-redundant replication, preferably `RA-GRS` or `RA-GZRS`, then create a blob container named `insurance-documents`.

Blob Storage uses a staging container and a final document container. The web app writes uploads to staging first:

```text
insurance-documents-staging/uploads/{userId}/{claimId}/{timestamp}-{filename}
```

The document validation Azure Function runs OCR.Space extraction and validation. If validation passes, it writes the document to the final container:

```text
insurance-documents/uploads/{userId}/{claimId}/{timestamp}-{filename}
```

The staged blob is deleted after both passed and failed validation. Add a lifecycle rule on the staging container to delete blobs older than 1 day as a safety net.

## Azure Functions Validation Flow

The `functions` folder contains:

```text
DocumentValidationFunction
  Blob-triggered from insurance-documents-staging
  Calls OCR.Space
  Validates OCR text against claim data
  Promotes passed documents to insurance-documents
  Deletes the staged blob after processing
  Sends a Service Bus queue message

MailQueueFunction
  Service Bus queue-triggered from claim-validation-mails
  Sends pass/fail email through SMTP
```

The validation checks readable OCR text, supported MIME type, policy number, claim amount, and contact number. Failed documents are not stored in the final Blob container.

## App Service Settings

For App Service application settings:

```text
COSMOS_DB_ENDPOINT=<cosmos account endpoint>
COSMOS_DB_KEY=<cosmos account key>
COSMOS_DB_DATABASE_NAME=insurance-claims
COSMOS_DB_CONTAINER_NAME=claims
AZURE_STORAGE_CONNECTION_STRING=<storage account connection string>
AZURE_STORAGE_CONTAINER_NAME=insurance-documents
AZURE_STORAGE_STAGING_CONTAINER_NAME=insurance-documents-staging
SESSION_SECRET=<long random secret>
DEMO_USER_PASSWORD=<replace>
DEMO_ADMIN_PASSWORD=<replace>
NODE_ENV=production
```

For the Function App settings:

```text
AzureWebJobsStorage=<storage account connection string>
COSMOS_DB_ENDPOINT=<cosmos account endpoint>
COSMOS_DB_KEY=<cosmos account key>
COSMOS_DB_DATABASE_NAME=insurance-claims
COSMOS_DB_CONTAINER_NAME=claims
AZURE_STORAGE_CONNECTION_STRING=<storage account connection string>
AZURE_STORAGE_CONTAINER_NAME=insurance-documents
AZURE_STORAGE_STAGING_CONTAINER_NAME=insurance-documents-staging
OCR_SPACE_API_KEY=<ocr.space api key>
OCR_SPACE_API_URL=https://api.ocr.space/parse/image
SERVICE_BUS_CONNECTION=<service bus connection string>
SERVICE_BUS_MAIL_QUEUE_NAME=claim-validation-mails
SMTP_HOST=<smtp host>
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USER=<smtp user>
SMTP_PASS=<smtp password>
EMAIL_FROM=<verified sender>
```

## Azure Deployment Architecture

Recommended simple target:

```text
Browser
  -> Azure Application Gateway with WAF v2
  -> Azure App Service
  -> Azure Functions for OCR validation and email queue processing
  -> Azure Cosmos DB for users and claims
  -> Azure Blob Storage with staging and final containers
  -> Azure Service Bus Queue for validation email messages
```

Configure the Application Gateway backend pool to point to the App Service hostname. Use `/health` as the health probe path. Enable WAF prevention mode after validating the app behavior.

## Deploy to App Service

One practical path:

```powershell
az login
az group create --name rg-insurance-claims --location eastus
az appservice plan create --name asp-insurance-claims --resource-group rg-insurance-claims --sku B1 --is-linux
az webapp create --name <unique-app-name> --resource-group rg-insurance-claims --plan asp-insurance-claims --runtime "NODE:20-lts"
az webapp config appsettings set --name <unique-app-name> --resource-group rg-insurance-claims --settings COSMOS_DB_ENDPOINT="<cosmos-endpoint>" COSMOS_DB_KEY="<cosmos-key>" COSMOS_DB_DATABASE_NAME="insurance-claims" COSMOS_DB_CONTAINER_NAME="claims" AZURE_STORAGE_CONNECTION_STRING="<storage-connection-string>" AZURE_STORAGE_CONTAINER_NAME="insurance-documents" AZURE_STORAGE_STAGING_CONTAINER_NAME="insurance-documents-staging" SESSION_SECRET="<secret>" NODE_ENV="production"
az webapp up --name <unique-app-name> --resource-group rg-insurance-claims --runtime "NODE:20-lts"
```

For stricter production security, replace demo login with Microsoft Entra ID, store secrets in Key Vault, use managed identity for Cosmos DB and Blob Storage access, and restrict the App Service so traffic comes through Application Gateway.
