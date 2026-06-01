# Insurance Claims Portal

A small monolithic insurance claims application with user and admin access. It stores users, claims, statuses, and feedback in Azure Cosmos DB. Azure Blob Storage is used only for uploaded documents.

## Features

- Login as `user` or `admin`
- Users can submit many insurance claim forms
- Users can upload one supporting document per claim
- Users can view submitted claims, documents, status, and admin feedback
- Admins can view users and all submitted claims
- Admins can download uploaded files and save claim feedback
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

If Azure settings are blank, metadata is stored in `.local-storage/db.json` and uploaded documents are stored under `.local-storage/uploads`.

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

Blob Storage is used only for uploaded claim documents:

```text
uploads/{userId}/{claimId}/{timestamp}-{filename}
```

## App Service Settings

For App Service application settings:

```text
COSMOS_DB_ENDPOINT=<cosmos account endpoint>
COSMOS_DB_KEY=<cosmos account key>
COSMOS_DB_DATABASE_NAME=insurance-claims
COSMOS_DB_CONTAINER_NAME=claims
AZURE_STORAGE_CONNECTION_STRING=<storage account connection string>
AZURE_STORAGE_CONTAINER_NAME=insurance-documents
SESSION_SECRET=<long random secret>
DEMO_USER_PASSWORD=<replace>
DEMO_ADMIN_PASSWORD=<replace>
NODE_ENV=production
```

## Azure Deployment Architecture

Recommended simple target:

```text
Browser
  -> Azure Application Gateway with WAF v2
  -> Azure App Service
  -> Azure Cosmos DB for users and claims
  -> Azure Blob Storage with RA-GRS or RA-GZRS for documents
```

Configure the Application Gateway backend pool to point to the App Service hostname. Use `/health` as the health probe path. Enable WAF prevention mode after validating the app behavior.

## Deploy to App Service

One practical path:

```powershell
az login
az group create --name rg-insurance-claims --location eastus
az appservice plan create --name asp-insurance-claims --resource-group rg-insurance-claims --sku B1 --is-linux
az webapp create --name <unique-app-name> --resource-group rg-insurance-claims --plan asp-insurance-claims --runtime "NODE:20-lts"
az webapp config appsettings set --name <unique-app-name> --resource-group rg-insurance-claims --settings COSMOS_DB_ENDPOINT="<cosmos-endpoint>" COSMOS_DB_KEY="<cosmos-key>" COSMOS_DB_DATABASE_NAME="insurance-claims" COSMOS_DB_CONTAINER_NAME="claims" AZURE_STORAGE_CONNECTION_STRING="<storage-connection-string>" AZURE_STORAGE_CONTAINER_NAME="insurance-documents" SESSION_SECRET="<secret>" NODE_ENV="production"
az webapp up --name <unique-app-name> --resource-group rg-insurance-claims --runtime "NODE:20-lts"
```

For stricter production security, replace demo login with Microsoft Entra ID, store secrets in Key Vault, use managed identity for Cosmos DB and Blob Storage access, and restrict the App Service so traffic comes through Application Gateway.
