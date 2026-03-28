const nodemailer = require('nodemailer');

let transporter = null;

function getTransporter() {
  if (!transporter) {
    transporter = nodemailer.createTransport({
      host: process.env.SMTP_HOST,
      port: parseInt(process.env.SMTP_PORT, 10) || 587,
      secure: false,
      auth: {
        user: process.env.SMTP_USER,
        pass: process.env.SMTP_PASS,
      },
    });
  }
  return transporter;
}

/**
 * Send a brute-force login alert to Director + Ops Manager.
 * Triggered when a single account hits 10+ failed attempts in 24 hours.
 */
async function sendLoginAlertEmail(username, attempts) {
  const recipients = process.env.ALERT_EMAIL_TO;
  if (!recipients) {
    console.warn('[Email] ALERT_EMAIL_TO not configured — skipping login alert');
    return;
  }

  const ipList = attempts.map((a) => `  - ${a.ip_address} at ${a.created_at}`).join('\n');

  const mailOptions = {
    from: `"Jamisan ERP Security" <${process.env.SMTP_USER}>`,
    to: recipients,
    subject: `[SECURITY ALERT] Repeated login failures for ${username}`,
    text: [
      `User "${username}" has ${attempts.length} failed login attempts in the last 24 hours.`,
      '',
      'Failed attempt details:',
      ipList,
      '',
      'The account has been locked for 30 minutes.',
      'If this is unexpected, investigate immediately.',
      '',
      '— Jamisan ERP Security System',
    ].join('\n'),
  };

  try {
    await getTransporter().sendMail(mailOptions);
    console.log(`[Email] Login alert sent for user "${username}"`);
  } catch (err) {
    console.error(`[Email] Failed to send login alert: ${err.message}`);
  }
}

/**
 * Send a reconciliation discrepancy alert when |crm - pabbly| > 2.
 */
async function sendReconciliationAlertEmail(date, crmCount, pabblyCount, discrepancy) {
  const recipients = process.env.ALERT_EMAIL_TO;
  if (!recipients) {
    console.warn('[Email] ALERT_EMAIL_TO not configured — skipping reconciliation alert');
    return;
  }

  const mailOptions = {
    from: `"Jamisan ERP Operations" <${process.env.SMTP_USER}>`,
    to: recipients,
    subject: `[RECONCILIATION ALERT] Order count discrepancy on ${date}`,
    text: [
      `Order count discrepancy detected for ${date}.`,
      '',
      `  CRM orders:    ${crmCount}`,
      `  Pabbly orders: ${pabblyCount}`,
      `  Discrepancy:   ${discrepancy}`,
      '',
      'Please review the pabbly_reconciliation_log table and investigate missing orders.',
      '',
      '— Jamisan ERP Operations System',
    ].join('\n'),
  };

  try {
    await getTransporter().sendMail(mailOptions);
    console.log(`[Email] Reconciliation alert sent for ${date}`);
  } catch (err) {
    console.error(`[Email] Failed to send reconciliation alert: ${err.message}`);
  }
}

module.exports = { sendLoginAlertEmail, sendReconciliationAlertEmail };
