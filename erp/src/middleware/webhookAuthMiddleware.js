const crypto = require('crypto');
const { logAudit } = require('../utils/auditLogger');

// Fixed key used only to produce equal-length digests for timingSafeEqual.
// The secrecy of the comparison is provided by PABBLY_WEBHOOK_SECRET, not this key.
const HMAC_COMPARE_KEY = 'jamisan-webhook-compare';

async function webhookAuthMiddleware(req, res, next) {
  const authHeader = req.headers['authorization'] || '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  const secret = process.env.PABBLY_WEBHOOK_SECRET || '';

  // HMAC both values so timingSafeEqual always compares 32-byte digests —
  // no length pre-check needed, and secret length is not leaked to callers.
  const tokenMac  = crypto.createHmac('sha256', HMAC_COMPARE_KEY).update(token).digest();
  const secretMac = crypto.createHmac('sha256', HMAC_COMPARE_KEY).update(secret).digest();
  const authorized = crypto.timingSafeEqual(tokenMac, secretMac);

  if (!authorized) {
    await logAudit(null, 'webhook_auth_failed', {
      ipAddress: req.ip || null,
      newValue: JSON.stringify({ path: req.path }),
    });
    return res.status(401).json({ error: 'Unauthorized' });
  }

  next();
}

module.exports = webhookAuthMiddleware;
