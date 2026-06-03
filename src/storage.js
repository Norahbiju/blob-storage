const fs = require('fs/promises');
const path = require('path');
const { CosmosClient } = require('@azure/cosmos');
const { BlobServiceClient } = require('@azure/storage-blob');

const localRoot = path.join(process.cwd(), '.local-storage');
const localDbPath = path.join(localRoot, 'db.json');

const seedUsers = [
  {
    id: 'user-001',
    type: 'user',
    partitionKey: 'user',
    username: 'user',
    passwordEnv: 'DEMO_USER_PASSWORD',
    defaultPassword: 'user123',
    emailEnv: 'DEMO_USER_EMAIL',
    role: 'user',
    name: 'Demo User',
    email: 'user@example.com'
  },
  {
    id: 'admin-001',
    type: 'user',
    partitionKey: 'user',
    username: 'admin',
    passwordEnv: 'DEMO_ADMIN_PASSWORD',
    defaultPassword: 'admin123',
    emailEnv: 'DEMO_ADMIN_EMAIL',
    role: 'admin',
    name: 'Claims Admin',
    email: 'admin@example.com'
  }
];

class ClaimRepository {
  constructor() {
    this.blobContainerName = process.env.AZURE_STORAGE_CONTAINER_NAME || 'insurance-documents';
    this.stagingBlobContainerName =
      process.env.AZURE_STORAGE_STAGING_CONTAINER_NAME || 'insurance-documents-staging';
    this.blobConnectionString = process.env.AZURE_STORAGE_CONNECTION_STRING;
    this.isBlobAzure = Boolean(this.blobConnectionString);
    this.blobContainerClient = null;
    this.stagingBlobContainerClient = null;

    this.cosmosEndpoint = process.env.COSMOS_DB_ENDPOINT;
    this.cosmosKey = process.env.COSMOS_DB_KEY;
    this.cosmosDatabaseName = process.env.COSMOS_DB_DATABASE_NAME || 'insurance-claims';
    this.cosmosContainerName = process.env.COSMOS_DB_CONTAINER_NAME || 'claims';
    this.isCosmosAzure = Boolean(this.cosmosEndpoint && this.cosmosKey);
    this.cosmosContainer = null;
  }

  async init() {
    await fs.mkdir(localRoot, { recursive: true });
    await this.initBlobStorage();
    await this.initMetadataStore();
    await this.seedDemoUsers();
  }

  async initBlobStorage() {
    if (!this.isBlobAzure) {
      await fs.mkdir(this.localPath('uploads'), { recursive: true });
      await fs.mkdir(this.localStagingPath('uploads'), { recursive: true });
      return;
    }

    const serviceClient = BlobServiceClient.fromConnectionString(this.blobConnectionString);
    this.blobContainerClient = serviceClient.getContainerClient(this.blobContainerName);
    this.stagingBlobContainerClient = serviceClient.getContainerClient(this.stagingBlobContainerName);
    await this.blobContainerClient.createIfNotExists();
    await this.stagingBlobContainerClient.createIfNotExists();
  }

  async initMetadataStore() {
    if (!this.isCosmosAzure) {
      try {
        await fs.access(localDbPath);
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
        await this.writeLocalDb({ users: [], claims: [] });
      }
      return;
    }

    const client = new CosmosClient({
      endpoint: this.cosmosEndpoint,
      key: this.cosmosKey
    });
    const { database } = await client.databases.createIfNotExists({ id: this.cosmosDatabaseName });
    const { container } = await database.containers.createIfNotExists({
      id: this.cosmosContainerName,
      partitionKey: { paths: ['/partitionKey'] }
    });
    this.cosmosContainer = container;
  }

  async seedDemoUsers() {
    for (const user of seedUsers) {
      const existingUser = await this.findUser(user.username, user.role);
      const seededUser = {
        ...user,
        password: process.env[user.passwordEnv] || user.defaultPassword,
        email: process.env[user.emailEnv] || user.email
      };
      delete seededUser.passwordEnv;
      delete seededUser.defaultPassword;
      delete seededUser.emailEnv;

      if (!existingUser) {
        await this.saveUser(seededUser);
      }
    }
  }

  async findUser(username, role) {
    if (this.isCosmosAzure) {
      const query = {
        query: 'SELECT * FROM c WHERE c.type = @type AND c.username = @username AND c.role = @role',
        parameters: [
          { name: '@type', value: 'user' },
          { name: '@username', value: username },
          { name: '@role', value: role }
        ]
      };
      const { resources } = await this.cosmosContainer.items.query(query).fetchAll();
      return resources[0] || null;
    }

    const db = await this.readLocalDb();
    return db.users.find((user) => user.username === username && user.role === role) || null;
  }

  verifyPassword(user, password) {
    return user.password === password;
  }

  async listUsers() {
    const users = this.isCosmosAzure
      ? await this.queryCosmos('SELECT * FROM c WHERE c.type = @type', [{ name: '@type', value: 'user' }])
      : (await this.readLocalDb()).users;

    return users
      .filter((user) => user.role === 'user')
      .map(({ id, username, name, email, role }) => ({ id, username, name, email, role }));
  }

  async saveUser(user) {
    if (this.isCosmosAzure) {
      await this.cosmosContainer.items.upsert(user);
      return;
    }

    const db = await this.readLocalDb();
    const index = db.users.findIndex((existingUser) => existingUser.id === user.id);
    if (index >= 0) {
      db.users[index] = user;
    } else {
      db.users.push(user);
    }
    await this.writeLocalDb(db);
  }

  async saveClaim(userId, claim) {
    const claimDocument = {
      ...claim,
      id: claim.claimId,
      type: 'claim',
      partitionKey: userId
    };

    if (this.isCosmosAzure) {
      await this.cosmosContainer.items.upsert(claimDocument);
      return;
    }

    const db = await this.readLocalDb();
    const index = db.claims.findIndex((existingClaim) => existingClaim.claimId === claim.claimId);
    if (index >= 0) {
      db.claims[index] = claimDocument;
    } else {
      db.claims.push(claimDocument);
    }
    await this.writeLocalDb(db);
  }

  async getClaim(userId, claimId) {
    if (this.isCosmosAzure) {
      const { resource } = await this.cosmosContainer.item(claimId, userId).read();
      return resource || null;
    }

    const db = await this.readLocalDb();
    return db.claims.find((claim) => claim.userId === userId && claim.claimId === claimId) || null;
  }

  async listClaims(userId) {
    const claims = this.isCosmosAzure
      ? await this.queryCosmos(
          'SELECT * FROM c WHERE c.type = @type AND c.userId = @userId',
          [
            { name: '@type', value: 'claim' },
            { name: '@userId', value: userId }
          ]
        )
      : (await this.readLocalDb()).claims.filter((claim) => claim.userId === userId);

    return this.sortClaims(claims);
  }

  async listAllClaims() {
    const claims = this.isCosmosAzure
      ? await this.queryCosmos('SELECT * FROM c WHERE c.type = @type', [{ name: '@type', value: 'claim' }])
      : (await this.readLocalDb()).claims;

    return this.sortClaims(claims);
  }

  async saveUploadedFile(userId, claimId, file) {
    const safeName = file.originalname.replace(/[^\w.\- ]/g, '_');
    const blobName = `uploads/${userId}/${claimId}/${Date.now()}-${safeName}`;
    await this.writeDocumentBlob(blobName, file.buffer, file.mimetype);
    return {
      blobName,
      originalName: file.originalname,
      mimeType: file.mimetype,
      size: file.size
    };
  }

  async saveStagedUploadedFile(userId, claimId, file) {
    const safeName = file.originalname.replace(/[^\w.\- ]/g, '_');
    const blobName = `uploads/${userId}/${claimId}/${Date.now()}-${safeName}`;
    await this.writeStagingBlob(blobName, file.buffer, file.mimetype, {
      userId,
      claimId,
      originalName: file.originalname
    });
    return {
      blobName,
      originalName: file.originalname,
      mimeType: file.mimetype,
      size: file.size
    };
  }

  async getFile(blobName) {
    if (this.isBlobAzure) {
      const blockBlobClient = this.blobContainerClient.getBlockBlobClient(blobName);
      const exists = await blockBlobClient.exists();
      if (!exists) return null;
      const properties = await blockBlobClient.getProperties();
      const download = await blockBlobClient.download(0);
      const buffer = await streamToBuffer(download.readableStreamBody);
      return {
        buffer,
        contentType: properties.contentType || 'application/octet-stream'
      };
    }

    const fullPath = this.localPath(blobName);
    try {
      const buffer = await fs.readFile(fullPath);
      return { buffer, contentType: 'application/octet-stream' };
    } catch (error) {
      if (error.code === 'ENOENT') return null;
      throw error;
    }
  }

  async writeDocumentBlob(name, buffer, contentType) {
    if (this.isBlobAzure) {
      const blockBlobClient = this.blobContainerClient.getBlockBlobClient(name);
      await blockBlobClient.uploadData(buffer, {
        blobHTTPHeaders: { blobContentType: contentType }
      });
      return;
    }

    const fullPath = this.localPath(name);
    await fs.mkdir(path.dirname(fullPath), { recursive: true });
    await fs.writeFile(fullPath, buffer);
  }

  async writeStagingBlob(name, buffer, contentType, metadata = {}) {
    if (this.isBlobAzure) {
      const blockBlobClient = this.stagingBlobContainerClient.getBlockBlobClient(name);
      await blockBlobClient.uploadData(buffer, {
        blobHTTPHeaders: { blobContentType: contentType },
        metadata: Object.fromEntries(
          Object.entries(metadata)
            .filter(([, value]) => value !== undefined && value !== null)
            .map(([key, value]) => [key, String(value)])
        )
      });
      return;
    }

    const fullPath = this.localStagingPath(name);
    await fs.mkdir(path.dirname(fullPath), { recursive: true });
    await fs.writeFile(fullPath, buffer);
  }

  async queryCosmos(queryText, parameters) {
    const { resources } = await this.cosmosContainer.items
      .query({ query: queryText, parameters })
      .fetchAll();
    return resources;
  }

  sortClaims(claims) {
    return claims.sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
  }

  async readLocalDb() {
    const buffer = await fs.readFile(localDbPath);
    return JSON.parse(buffer.toString('utf8'));
  }

  async writeLocalDb(db) {
    await fs.mkdir(localRoot, { recursive: true });
    await fs.writeFile(localDbPath, JSON.stringify(db, null, 2));
  }

  localPath(name) {
    return path.join(localRoot, ...name.split('/'));
  }

  localStagingPath(name) {
    return path.join(localRoot, 'staging', ...name.split('/'));
  }
}

async function streamToBuffer(readableStream) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    readableStream.on('data', (data) => chunks.push(data instanceof Buffer ? data : Buffer.from(data)));
    readableStream.on('end', () => resolve(Buffer.concat(chunks)));
    readableStream.on('error', reject);
  });
}

module.exports = new ClaimRepository();
