const jwt = require('jsonwebtoken');

const ACCESS_SECRET = () => process.env.JWT_ACCESS_SECRET;
const REFRESH_SECRET = () => process.env.JWT_REFRESH_SECRET;
const ACCESS_EXPIRY = () => process.env.JWT_ACCESS_EXPIRY || '15m';
const REFRESH_EXPIRY = () => process.env.JWT_REFRESH_EXPIRY || '8h';

/**
 * Generate a short-lived access token.
 * Payload: user_id, role (name string), token_version
 */
function generateAccessToken(user) {
  return jwt.sign(
    {
      user_id: user.id,
      role: user.role_name,
      token_version: user.token_version,
    },
    ACCESS_SECRET(),
    { expiresIn: ACCESS_EXPIRY(), algorithm: 'HS256' }
  );
}

/**
 * Generate a longer-lived refresh token.
 * Payload: user_id, token_version (no role — only used for renewal)
 */
function generateRefreshToken(user) {
  return jwt.sign(
    {
      user_id: user.id,
      token_version: user.token_version,
    },
    REFRESH_SECRET(),
    { expiresIn: REFRESH_EXPIRY(), algorithm: 'HS256' }
  );
}

/**
 * Generate a short-lived temp token for 2FA flow (5 min).
 * Issued after password check passes but before TOTP verification.
 */
function generateTempToken(user) {
  return jwt.sign(
    {
      user_id: user.id,
      purpose: '2fa',
      token_version: user.token_version,
    },
    ACCESS_SECRET(),
    { expiresIn: '5m', algorithm: 'HS256' }
  );
}

function verifyAccessToken(token) {
  return jwt.verify(token, ACCESS_SECRET(), { algorithms: ['HS256'] });
}

function verifyRefreshToken(token) {
  return jwt.verify(token, REFRESH_SECRET(), { algorithms: ['HS256'] });
}

function verifyTempToken(token) {
  const payload = jwt.verify(token, ACCESS_SECRET(), { algorithms: ['HS256'] });
  if (payload.purpose !== '2fa') {
    throw new jwt.JsonWebTokenError('Invalid token purpose');
  }
  return payload;
}

module.exports = {
  generateAccessToken,
  generateRefreshToken,
  generateTempToken,
  verifyAccessToken,
  verifyRefreshToken,
  verifyTempToken,
};
