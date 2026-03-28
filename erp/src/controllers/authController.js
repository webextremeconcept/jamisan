const bcrypt = require('bcryptjs');
const { pool } = require('../config/db');
const {
  generateAccessToken,
  generateRefreshToken,
  generateTempToken,
  verifyRefreshToken,
  verifyTempToken,
} = require('../services/tokenService');
const twoFactor = require('../services/twoFactorService');
const { sendLoginAlertEmail } = require('../services/emailService');
const { logAudit } = require('../utils/auditLogger');

const BCRYPT_ROUNDS = 12;
const LOCKOUT_THRESHOLD = 5;
const LOCKOUT_DURATION_MIN = 30;
const EMAIL_ALERT_THRESHOLD = 10;

// Roles that require 2FA — exact strings from the database
const TWO_FA_ROLES = ['Director', 'Operations_Manager', 'Accountant'];

// Pre-computed bcrypt hash used on the unknown-email path so that
// bcrypt.compare always runs (~100ms), preventing email enumeration
// via response-time differences.
const DUMMY_HASH = '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewdBPj4QB5i/.Tri';

// NOTE: Any admin route that toggles is_active = false MUST also increment
// token_version atomically in the same UPDATE statement:
//   UPDATE users SET is_active = false, token_version = token_version + 1 WHERE id = $1
// This ensures all existing JWTs are immediately rejected by authMiddleware Gate 4.

/**
 * Extract client IP from request.
 * app.js sets trust proxy — req.ip is already the real client address.
 */
function getClientIp(req) {
  return req.ip || 'unknown';
}

/**
 * Issue tokens and create a session log entry.
 * Shared by login, 2fa/verify, and 2fa/activate flows.
 */
async function issueTokensAndCreateSession(user, req) {
  const accessToken = generateAccessToken(user);
  const refreshToken = generateRefreshToken(user);

  await pool.query(
    `INSERT INTO session_log (user_id, logged_in_at, ip_address, device_info)
     VALUES ($1, now(), $2, $3)`,
    [user.id, getClientIp(req), req.headers['user-agent'] || null]
  );

  await pool.query(
    `UPDATE users SET last_login_at = now() WHERE id = $1`,
    [user.id]
  );

  return { accessToken, refreshToken };
}

/**
 * Build a user-facing response payload from a user row.
 */
function buildUserPayload(user) {
  return {
    id: user.id,
    display_name: user.display_name,
    role: user.role_name,
  };
}

/**
 * Load a user by ID with their role name.
 * Used by 2FA flows after temp token verification.
 */
async function loadUserById(userId) {
  const result = await pool.query(
    `SELECT u.id, u.role_id, r.name AS role_name, u.email, u.display_name,
            u.token_version, u.is_active, u.two_fa_enabled, u.two_fa_secret,
            u.pending_2fa_secret
     FROM users u
     JOIN roles r ON r.id = u.role_id
     WHERE u.id = $1`,
    [userId]
  );
  return result.rows[0] || null;
}

/**
 * Verify a temp token and load the associated user.
 * Returns { user, payload } or sends an error response and returns null.
 */
async function verifyTempTokenAndLoadUser(tempToken, res) {
  let payload;
  try {
    payload = verifyTempToken(tempToken);
  } catch {
    res.status(401).json({ message: 'Invalid or expired verification token' });
    return null;
  }

  const user = await loadUserById(payload.user_id);
  if (!user || !user.is_active) {
    res.status(401).json({ message: 'Invalid token' });
    return null;
  }

  if (payload.token_version !== user.token_version) {
    res.status(401).json({ message: 'Session invalidated' });
    return null;
  }

  return { user, payload };
}

/**
 * Check audit_log for 10+ login failures in 24h and send an alert email.
 * A login_alert_sent entry is written before sending to suppress duplicates
 * within the same 24h window. queryEmail is stored as new_value for all
 * login_failed actions.
 */
async function checkAndSendLoginAlert(queryEmail, displayName) {
  try {
    const countResult = await pool.query(
      `SELECT COUNT(*)::int AS cnt FROM audit_log
       WHERE action = 'login_failed'
         AND new_value = $1
         AND created_at > now() - interval '24 hours'`,
      [queryEmail]
    );

    if (countResult.rows[0].cnt < EMAIL_ALERT_THRESHOLD) {
      return;
    }

    const alertedResult = await pool.query(
      `SELECT COUNT(*)::int AS cnt FROM audit_log
       WHERE action = 'login_alert_sent'
         AND new_value = $1
         AND created_at > now() - interval '24 hours'`,
      [queryEmail]
    );

    if (alertedResult.rows[0].cnt > 0) {
      return;
    }

    const recentFailures = await pool.query(
      `SELECT ip_address, created_at FROM audit_log
       WHERE action = 'login_failed'
         AND new_value = $1
         AND created_at > now() - interval '24 hours'
       ORDER BY created_at DESC`,
      [queryEmail]
    );

    // Write audit entry before sending to reduce (but not fully eliminate
    // under concurrent load) duplicate sends. Acceptable for an internal ERP.
    await logAudit(null, 'login_alert_sent', { newValue: queryEmail });

    sendLoginAlertEmail(displayName, recentFailures.rows).catch((err) => {
      console.error('[Auth] Failed to send login alert email:', err.message);
    });
  } catch (err) {
    console.error('[Auth] Failed to run login alert check:', err.message);
  }
}

// ============================================================================
// POST /auth/login
// ============================================================================
async function login(req, res) {
  const { email, password } = req.body;
  const ip = getClientIp(req);

  if (!email || !password || typeof email !== 'string' || typeof password !== 'string') {
    return res.status(400).json({ message: 'Email and password are required' });
  }

  const userResult = await pool.query(
    `SELECT u.id, u.role_id, r.name AS role_name, u.email, u.username, u.display_name,
            u.password_hash, u.token_version, u.is_active, u.two_fa_enabled, u.two_fa_secret,
            u.failed_login_attempts, u.locked_until
     FROM users u
     JOIN roles r ON r.id = u.role_id
     WHERE u.email = $1`,
    [email]
  );

  const user = userResult.rows[0];

  // Unknown email — run dummy bcrypt to prevent timing-based enumeration
  if (!user) {
    await bcrypt.compare(password, DUMMY_HASH);
    await logAudit(null, 'login_failed', { ipAddress: ip, newValue: email });
    await checkAndSendLoginAlert(email, email);
    return res.status(401).json({ message: 'Invalid email or password' });
  }

  // Account deactivated — generic message to avoid information leakage
  if (!user.is_active) {
    await logAudit(user.id, 'login_failed', { ipAddress: ip, newValue: user.email });
    await checkAndSendLoginAlert(user.email, user.username || user.email);
    return res.status(401).json({ message: 'Invalid email or password' });
  }

  // Lockout check — before bcrypt.compare to save CPU
  if (user.locked_until && new Date(user.locked_until) > new Date()) {
    await logAudit(user.id, 'login_failed', { ipAddress: ip, newValue: user.email });
    await checkAndSendLoginAlert(user.email, user.username || user.email);
    return res.status(423).json({ message: 'Invalid email or password' });
  }

  // Lockout expired — reset counter so the user gets a clean slate
  if (user.locked_until && new Date(user.locked_until) <= new Date()) {
    await pool.query(
      `UPDATE users SET failed_login_attempts = 0, locked_until = NULL WHERE id = $1`,
      [user.id]
    );
  }

  const passwordValid = await bcrypt.compare(password, user.password_hash);

  if (!passwordValid) {
    // Atomic increment + conditional lock in a single UPDATE to avoid races
    await pool.query(
      `UPDATE users
       SET failed_login_attempts = failed_login_attempts + 1,
           locked_until = CASE
             WHEN failed_login_attempts + 1 >= $2 THEN now() + ($3 * interval '1 minute')
             ELSE locked_until
           END
       WHERE id = $1`,
      [user.id, LOCKOUT_THRESHOLD, LOCKOUT_DURATION_MIN]
    );

    await logAudit(user.id, 'login_failed', { ipAddress: ip, newValue: user.email });
    await checkAndSendLoginAlert(user.email, user.username || user.email);
    return res.status(401).json({ message: 'Invalid email or password' });
  }

  // --- Password is correct ---

  await pool.query(
    `UPDATE users SET failed_login_attempts = 0, locked_until = NULL WHERE id = $1`,
    [user.id]
  );

  // 2FA required for elevated roles
  if (TWO_FA_ROLES.includes(user.role_name)) {
    const tempToken = generateTempToken(user);

    if (user.two_fa_enabled && user.two_fa_secret) {
      await logAudit(user.id, 'login_2fa_pending', { ipAddress: ip });
      return res.status(200).json({ requires_2fa: true, temp_token: tempToken });
    }

    await logAudit(user.id, 'login_2fa_setup_required', { ipAddress: ip });
    return res.status(200).json({ requires_2fa_setup: true, temp_token: tempToken });
  }

  // Non-2FA role — issue tokens immediately
  const { accessToken, refreshToken } = await issueTokensAndCreateSession(user, req);
  await logAudit(user.id, 'login_success', { ipAddress: ip });

  return res.status(200).json({
    access_token: accessToken,
    refresh_token: refreshToken,
    user: buildUserPayload(user),
  });
}

// ============================================================================
// POST /auth/2fa/verify
// ============================================================================
async function twoFactorVerify(req, res) {
  const { temp_token, totp_code } = req.body;
  const ip = getClientIp(req);

  if (!temp_token || !totp_code || typeof totp_code !== 'string') {
    return res.status(400).json({ message: 'temp_token and totp_code are required' });
  }

  const result = await verifyTempTokenAndLoadUser(temp_token, res);
  if (!result) return;
  const { user } = result;

  if (!user.two_fa_secret) {
    return res.status(400).json({ message: '2FA not configured for this account' });
  }

  const isValid = twoFactor.verifyToken(user.two_fa_secret, totp_code);
  if (!isValid) {
    await logAudit(user.id, '2fa_failed', { ipAddress: ip });
    return res.status(401).json({ message: 'Invalid TOTP code' });
  }

  const { accessToken, refreshToken } = await issueTokensAndCreateSession(user, req);

  await logAudit(user.id, 'login_success', {
    ipAddress: ip,
    newValue: JSON.stringify({ method: '2fa_totp' }),
  });

  return res.status(200).json({
    access_token: accessToken,
    refresh_token: refreshToken,
    user: buildUserPayload(user),
  });
}

// ============================================================================
// POST /auth/2fa/setup
// ============================================================================
async function twoFactorSetup(req, res) {
  const { temp_token } = req.body;
  const ip = getClientIp(req);

  if (!temp_token) {
    return res.status(400).json({ message: 'temp_token is required' });
  }

  const result = await verifyTempTokenAndLoadUser(temp_token, res);
  if (!result) return;
  const { user } = result;

  // Guard against double-setup — would break any authenticator app already
  // scanning the first QR code
  if (user.pending_2fa_secret) {
    return res.status(400).json({ message: '2FA setup is already in progress. Please scan the QR code already sent or contact your Operations Manager.' });
  }

  // Guard against re-setup on an already-configured account
  if (user.two_fa_enabled && user.two_fa_secret) {
    return res.status(400).json({ message: '2FA is already configured for this account' });
  }

  const { secret, otpauth_url } = twoFactor.generateSecret(user.email);
  const qrCode = await twoFactor.generateQRCode(otpauth_url);

  // Store secret server-side — the client never receives the raw secret
  await pool.query(
    `UPDATE users SET pending_2fa_secret = $1 WHERE id = $2`,
    [secret, user.id]
  );

  await logAudit(user.id, '2fa_setup_initiated', { ipAddress: ip });

  return res.status(200).json({ qr_code: qrCode });
}

// ============================================================================
// POST /auth/2fa/activate
// ============================================================================
async function twoFactorActivate(req, res) {
  const { temp_token, totp_code } = req.body;
  const ip = getClientIp(req);

  if (!temp_token || !totp_code) {
    return res.status(400).json({ message: 'temp_token and totp_code are required' });
  }

  const result = await verifyTempTokenAndLoadUser(temp_token, res);
  if (!result) return;
  const { user } = result;

  if (!user.pending_2fa_secret) {
    return res.status(400).json({ message: '2FA setup has not been initiated — call /auth/2fa/setup first' });
  }

  const isValid = twoFactor.verifyToken(user.pending_2fa_secret, totp_code);
  if (!isValid) {
    await logAudit(user.id, '2fa_activate_failed', { ipAddress: ip });
    return res.status(401).json({ message: 'Invalid TOTP code — scan the QR code and try again' });
  }

  // Atomically promote pending_2fa_secret -> two_fa_secret
  await pool.query(
    `UPDATE users
     SET two_fa_secret = pending_2fa_secret,
         two_fa_enabled = true,
         pending_2fa_secret = NULL
     WHERE id = $1`,
    [user.id]
  );

  const updatedUser = await loadUserById(user.id);
  const { accessToken, refreshToken } = await issueTokensAndCreateSession(updatedUser, req);

  await logAudit(user.id, '2fa_activated', { ipAddress: ip });

  return res.status(200).json({
    access_token: accessToken,
    refresh_token: refreshToken,
    user: buildUserPayload(updatedUser),
  });
}

// ============================================================================
// POST /auth/refresh
// ============================================================================
async function refresh(req, res) {
  const { refresh_token } = req.body;

  if (!refresh_token) {
    return res.status(400).json({ message: 'refresh_token is required' });
  }

  let payload;
  try {
    payload = verifyRefreshToken(refresh_token);
  } catch (err) {
    const message =
      err.name === 'TokenExpiredError'
        ? 'Refresh token expired — please log in again'
        : 'Invalid refresh token';
    return res.status(401).json({ message });
  }

  const result = await pool.query(
    `SELECT u.id, u.role_id, r.name AS role_name, u.token_version, u.is_active
     FROM users u
     JOIN roles r ON r.id = u.role_id
     WHERE u.id = $1`,
    [payload.user_id]
  );

  const user = result.rows[0];
  if (!user || !user.is_active) {
    return res.status(401).json({ message: 'Invalid refresh token' });
  }

  if (payload.token_version !== user.token_version) {
    return res.status(401).json({ message: 'Session invalidated — please log in again' });
  }

  const accessToken = generateAccessToken(user);
  const refreshToken = generateRefreshToken(user);

  await logAudit(user.id, 'token_refreshed', { ipAddress: getClientIp(req) });

  return res.status(200).json({
    access_token: accessToken,
    refresh_token: refreshToken,
  });
}

// ============================================================================
// PATCH /auth/password
// ============================================================================
async function changePassword(req, res) {
  const { current_password, new_password } = req.body;
  const ip = getClientIp(req);
  const userId = req.user.id;

  if (
    !current_password || !new_password ||
    typeof current_password !== 'string' || typeof new_password !== 'string'
  ) {
    return res.status(400).json({ message: 'current_password and new_password are required' });
  }

  if (new_password.length < 8) {
    return res.status(400).json({ message: 'New password must be at least 8 characters' });
  }

  const result = await pool.query(
    `SELECT password_hash FROM users WHERE id = $1`,
    [userId]
  );
  const user = result.rows[0];

  if (!user) {
    return res.status(401).json({ message: 'User not found' });
  }

  const isMatch = await bcrypt.compare(current_password, user.password_hash);
  if (!isMatch) {
    await logAudit(userId, 'password_change_failed', {
      ipAddress: ip,
      newValue: JSON.stringify({ reason: 'wrong_current_password' }),
    });
    return res.status(401).json({ message: 'Current password is incorrect' });
  }

  const newHash = await bcrypt.hash(new_password, BCRYPT_ROUNDS);
  await pool.query(
    `UPDATE users SET password_hash = $1, token_version = token_version + 1 WHERE id = $2`,
    [newHash, userId]
  );

  await logAudit(userId, 'password_changed', { ipAddress: ip });

  return res.status(200).json({ message: 'Password changed. Please log in again.' });
}

// ============================================================================
// POST /auth/logout
// ============================================================================
async function logout(req, res) {
  const ip = getClientIp(req);
  const userId = req.user.id;

  await pool.query(
    `UPDATE users SET token_version = token_version + 1 WHERE id = $1`,
    [userId]
  );

  await pool.query(
    `UPDATE session_log SET logged_out_at = now()
     WHERE user_id = $1 AND logged_out_at IS NULL`,
    [userId]
  );

  await logAudit(userId, 'logout', { ipAddress: ip });

  return res.status(200).json({ message: 'Logged out successfully' });
}

// ============================================================================
// POST /auth/forgot-password
// ============================================================================
async function forgotPassword(req, res) {
  const ip = getClientIp(req);

  await logAudit(null, 'password_reset_denied', {
    ipAddress: ip,
    newValue: JSON.stringify({ email: req.body.email || 'not_provided' }),
  });

  return res.status(403).json({
    message: 'Please contact your Operations Manager to reset your password.',
  });
}

module.exports = {
  login,
  twoFactorVerify,
  twoFactorSetup,
  twoFactorActivate,
  refresh,
  changePassword,
  logout,
  forgotPassword,
};
