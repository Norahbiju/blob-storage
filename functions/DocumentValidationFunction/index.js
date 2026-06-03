const { deleteStagedBlob, getStagedBlobProperties, promoteStagedBlob } = require('../shared/blobDocuments');
const { getClaim, saveClaim } = require('../shared/cosmosClaims');
const { extractTextWithOcrSpace } = require('../shared/ocrSpaceClient');
const { validateDocumentText } = require('../shared/validateDocument');

module.exports = async function documentValidationFunction(context, document) {
  const { userId, claimId, fileName } = context.bindingData;
  const blobName = `uploads/${userId}/${claimId}/${fileName}`;
  const now = new Date().toISOString();
  let claim;
  let mailMessage = null;

  try {
    claim = await getClaim(userId, claimId);
    if (!claim) {
      context.log.warn(`Claim ${claimId} for user ${userId} was not found. Deleting staged blob ${blobName}.`);
      return;
    }

    const stagedFile = claim.stagedFile || {
      blobName,
      originalName: fileName,
      mimeType: 'application/octet-stream',
      size: document.length
    };

    const properties = await getStagedBlobProperties(blobName);
    const contentType = properties.contentType || stagedFile.mimeType || 'application/octet-stream';

    const ocrResult = await extractTextWithOcrSpace(document, stagedFile.originalName || fileName, contentType);
    const validation = validateDocumentText(
      claim,
      ocrResult.extractedText,
      { ...stagedFile, mimeType: contentType }
    );

    if (validation.passed) {
      await promoteStagedBlob(blobName, document, contentType, {
        userId,
        claimId,
        originalName: stagedFile.originalName || fileName
      });

      claim.uploadedFile = {
        blobName,
        originalName: stagedFile.originalName || fileName,
        mimeType: contentType,
        size: stagedFile.size || document.length
      };
      claim.stagedFile = null;
      claim.status = 'ValidationPassed';
      claim.validation = {
        status: 'passed',
        requestedAt: claim.validation && claim.validation.requestedAt ? claim.validation.requestedAt : claim.createdAt,
        checkedAt: now,
        errors: [],
        extractedTextPreview: validation.extractedTextPreview
      };

      await saveClaim(claim);
      mailMessage = buildMailMessage(claim, 'validation-passed');
      context.log(`Claim ${claimId} document validation passed.`);
    } else {
      claim.uploadedFile = null;
      claim.stagedFile = null;
      claim.status = 'ValidationFailed';
      claim.validation = {
        status: 'failed',
        requestedAt: claim.validation && claim.validation.requestedAt ? claim.validation.requestedAt : claim.createdAt,
        checkedAt: now,
        errors: validation.errors,
        extractedTextPreview: validation.extractedTextPreview
      };

      await saveClaim(claim);
      mailMessage = buildMailMessage(claim, 'validation-failed', validation.errors);
      context.log.warn(`Claim ${claimId} document validation failed: ${validation.errors.join('; ')}`);
    }
  } catch (error) {
    context.log.error(`Document validation failed for ${blobName}.`, error);

    if (claim) {
      claim.uploadedFile = null;
      claim.stagedFile = null;
      claim.status = 'ValidationFailed';
      claim.validation = {
        status: 'failed',
        requestedAt: claim.validation && claim.validation.requestedAt ? claim.validation.requestedAt : claim.createdAt,
        checkedAt: now,
        errors: [error.message || 'Document validation failed.'],
        extractedTextPreview: ''
      };
      await saveClaim(claim);
      mailMessage = buildMailMessage(claim, 'validation-failed', claim.validation.errors);
    }
  } finally {
    try {
      await deleteStagedBlob(blobName);
      context.log(`Deleted staged blob ${blobName}.`);
    } catch (deleteError) {
      context.log.error(`Could not delete staged blob ${blobName}.`, deleteError);
    }
  }

  if (mailMessage) {
    context.bindings.mailMessage = mailMessage;
  }
};

function buildMailMessage(claim, type, reasons = []) {
  return {
    to: claim.userEmail,
    userName: claim.userName,
    claimId: claim.claimId,
    policyNumber: claim.policyNumber,
    type,
    reasons,
    createdAt: new Date().toISOString()
  };
}
