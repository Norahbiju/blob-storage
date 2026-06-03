const { BlobServiceClient } = require('@azure/storage-blob');

let serviceClient;

function getServiceClient() {
  if (serviceClient) return serviceClient;

  const connectionString = process.env.AZURE_STORAGE_CONNECTION_STRING || process.env.AzureWebJobsStorage;
  if (!connectionString) {
    throw new Error('AZURE_STORAGE_CONNECTION_STRING or AzureWebJobsStorage is required.');
  }

  serviceClient = BlobServiceClient.fromConnectionString(connectionString);
  return serviceClient;
}

function getContainer(name) {
  return getServiceClient().getContainerClient(name);
}

async function promoteStagedBlob(blobName, buffer, contentType, metadata = {}) {
  const finalContainerName = process.env.AZURE_STORAGE_CONTAINER_NAME || 'insurance-documents';
  const finalContainer = getContainer(finalContainerName);
  await finalContainer.createIfNotExists();

  const finalBlob = finalContainer.getBlockBlobClient(blobName);
  await finalBlob.uploadData(buffer, {
    blobHTTPHeaders: { blobContentType: contentType || 'application/octet-stream' },
    metadata: sanitizeMetadata(metadata)
  });
}

async function getStagedBlobProperties(blobName) {
  const stagingContainerName = process.env.AZURE_STORAGE_STAGING_CONTAINER_NAME || 'insurance-documents-staging';
  const stagingContainer = getContainer(stagingContainerName);
  const stagedBlob = stagingContainer.getBlockBlobClient(blobName);
  return stagedBlob.getProperties();
}

async function deleteStagedBlob(blobName) {
  const stagingContainerName = process.env.AZURE_STORAGE_STAGING_CONTAINER_NAME || 'insurance-documents-staging';
  const stagingContainer = getContainer(stagingContainerName);
  const stagedBlob = stagingContainer.getBlockBlobClient(blobName);
  await stagedBlob.deleteIfExists();
}

function sanitizeMetadata(metadata) {
  return Object.fromEntries(
    Object.entries(metadata)
      .filter(([, value]) => value !== undefined && value !== null)
      .map(([key, value]) => [key, String(value)])
  );
}

module.exports = {
  deleteStagedBlob,
  getStagedBlobProperties,
  promoteStagedBlob
};
