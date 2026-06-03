const nodemailer = require('nodemailer');

let transporter;

module.exports = async function mailQueueFunction(context, message) {
  const payload = typeof message === 'string' ? JSON.parse(message) : message;

  if (!payload || !payload.to) {
    context.log.warn('Mail queue message did not include a recipient.');
    return;
  }

  const mail = buildMail(payload);
  const client = getTransporter();

  if (!client) {
    context.log.warn(`SMTP settings are incomplete. Skipping email to ${payload.to}.`);
    return;
  }

  await client.sendMail(mail);
  context.log(`Sent ${payload.type} email to ${payload.to} for claim ${payload.claimId}.`);
};

function getTransporter() {
  if (transporter) return transporter;

  const host = process.env.SMTP_HOST;
  const port = Number(process.env.SMTP_PORT || 587);
  const user = process.env.SMTP_USER;
  const pass = process.env.SMTP_PASS;

  if (!host || !user || !pass) return null;

  transporter = nodemailer.createTransport({
    host,
    port,
    secure: String(process.env.SMTP_SECURE || 'false').toLowerCase() === 'true',
    auth: { user, pass }
  });

  return transporter;
}

function buildMail(payload) {
  const from = process.env.EMAIL_FROM || 'claims@example.com';
  const passed = payload.type === 'validation-passed';
  const subject = passed
    ? `Claim ${payload.policyNumber} document validation passed`
    : `Claim ${payload.policyNumber} document validation failed`;

  const text = passed
    ? [
        `Hello ${payload.userName || 'there'},`,
        '',
        `Your document for claim ${payload.claimId} passed validation and has been stored for review.`,
        '',
        'Aegis Claims'
      ].join('\n')
    : [
        `Hello ${payload.userName || 'there'},`,
        '',
        `Your document for claim ${payload.claimId} did not pass validation.`,
        '',
        'Reasons:',
        ...(payload.reasons && payload.reasons.length ? payload.reasons.map((reason) => `- ${reason}`) : ['- Validation failed.']),
        '',
        'Please submit a corrected document.',
        '',
        'Aegis Claims'
      ].join('\n');

  return {
    from,
    to: payload.to,
    subject,
    text
  };
}
