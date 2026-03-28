const speakeasy = require('speakeasy');
const QRCode = require('qrcode');

const ISSUER = 'Jamisan ERP';

/**
 * Generate a new TOTP secret for a user.
 * Returns { secret (base32), otpauth_url }
 */
function generateSecret(userEmail) {
  const secret = speakeasy.generateSecret({
    name: `${ISSUER}:${userEmail}`,
    issuer: ISSUER,
    length: 20,
  });
  return {
    secret: secret.base32,
    otpauth_url: secret.otpauth_url,
  };
}

/**
 * Generate a QR code data URL from an otpauth:// URL.
 */
async function generateQRCode(otpauthUrl) {
  return QRCode.toDataURL(otpauthUrl);
}

/**
 * Verify a TOTP code against a base32 secret.
 * window: 1 allows one period (30s) of clock skew in either direction.
 */
function verifyToken(secret, token) {
  return speakeasy.totp.verify({
    secret,
    encoding: 'base32',
    token,
    window: 1,
  });
}

module.exports = {
  generateSecret,
  generateQRCode,
  verifyToken,
};
