const MIN_TEXT_LENGTH = 20;

function validateDocumentText(claim, extractedText, stagedFile = {}) {
  const errors = [];
  const normalizedText = normalize(extractedText);

  if (!extractedText || extractedText.trim().length < MIN_TEXT_LENGTH) {
    errors.push('OCR text is empty or too short to validate.');
  }

  if (!isSupportedDocumentType(stagedFile.mimeType)) {
    errors.push('Document type is not supported for OCR validation.');
  }

  if (claim.policyNumber && !normalizedText.includes(normalize(claim.policyNumber))) {
    errors.push('Policy number was not found in the OCR text.');
  }

  if (claim.contactNumber && !containsDigits(normalizedText, claim.contactNumber)) {
    errors.push('Contact number was not found in the OCR text.');
  }

  if (claim.claimAmount && !containsAmount(normalizedText, claim.claimAmount)) {
    errors.push('Claim amount was not found in the OCR text.');
  }

  return {
    passed: errors.length === 0,
    errors,
    extractedTextPreview: extractedText ? extractedText.trim().slice(0, 1200) : ''
  };
}

function isSupportedDocumentType(mimeType = '') {
  return ['application/pdf', 'image/png', 'image/jpeg', 'image/jpg'].includes(mimeType.toLowerCase());
}

function normalize(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9.]/g, '');
}

function containsDigits(normalizedText, value) {
  const digits = String(value || '').replace(/\D/g, '');
  return !digits || normalizedText.includes(digits);
}

function containsAmount(normalizedText, value) {
  const amount = Number(value);
  if (!Number.isFinite(amount)) return false;

  const exact = amount.toFixed(2).replace(/[^0-9.]/g, '');
  const whole = String(Math.trunc(amount));
  return normalizedText.includes(exact) || normalizedText.includes(whole);
}

module.exports = {
  validateDocumentText
};
