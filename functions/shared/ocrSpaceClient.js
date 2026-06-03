async function extractTextWithOcrSpace(buffer, fileName, contentType) {
  const apiKey = process.env.OCR_SPACE_API_KEY;
  const apiUrl = process.env.OCR_SPACE_API_URL || 'https://api.ocr.space/parse/image';

  if (!apiKey) {
    throw new Error('OCR_SPACE_API_KEY is required.');
  }

  const form = new FormData();
  form.append('apikey', apiKey);
  form.append('language', process.env.OCR_SPACE_LANGUAGE || 'eng');
  form.append('isOverlayRequired', 'false');
  form.append('detectOrientation', 'true');
  form.append('scale', 'true');
  form.append('OCREngine', process.env.OCR_SPACE_ENGINE || '2');
  form.append('file', new Blob([buffer], { type: contentType || 'application/octet-stream' }), fileName);

  const response = await fetch(apiUrl, {
    method: 'POST',
    body: form
  });

  if (!response.ok) {
    throw new Error(`OCR.Space returned HTTP ${response.status}.`);
  }

  const payload = await response.json();

  if (payload.IsErroredOnProcessing) {
    const errors = []
      .concat(payload.ErrorMessage || [])
      .concat(payload.ErrorDetails || [])
      .filter(Boolean);
    throw new Error(errors.join('; ') || 'OCR.Space failed to process the document.');
  }

  const parsedResults = payload.ParsedResults || [];
  const extractedText = parsedResults
    .map((result) => result.ParsedText || '')
    .join('\n')
    .trim();

  return {
    extractedText,
    raw: payload
  };
}

module.exports = {
  extractTextWithOcrSpace
};
