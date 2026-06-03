const { CosmosClient } = require('@azure/cosmos');

let container;

function getContainer() {
  if (container) return container;

  const endpoint = process.env.COSMOS_DB_ENDPOINT;
  const key = process.env.COSMOS_DB_KEY;
  const databaseName = process.env.COSMOS_DB_DATABASE_NAME || 'insurance-claims';
  const containerName = process.env.COSMOS_DB_CONTAINER_NAME || 'claims';

  if (!endpoint || !key) {
    throw new Error('COSMOS_DB_ENDPOINT and COSMOS_DB_KEY are required.');
  }

  const client = new CosmosClient({ endpoint, key });
  container = client.database(databaseName).container(containerName);
  return container;
}

async function getClaim(userId, claimId) {
  const { resource } = await getContainer().item(claimId, userId).read();
  return resource || null;
}

async function saveClaim(claim) {
  claim.id = claim.claimId;
  claim.type = 'claim';
  claim.partitionKey = claim.userId;
  claim.updatedAt = new Date().toISOString();
  await getContainer().items.upsert(claim);
  return claim;
}

module.exports = {
  getClaim,
  saveClaim
};
