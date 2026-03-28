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

// FIX 4: Pre-computed bcrypt hash for timing-attack mitigation on unknown-email path.
// bcrypt.compare runs the full algorithm (~100ms) and returns false,
// preventing email enumeration via response-time differences.
const DUMMY_HASH = '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewdBPj4QB5i/.Tri';

// MODULE 5 REQUIREMENT (Gemini FIX 3): Any admin route that toggles is_active = false
// MUST also increment token_version atomically in the same UPDATE statement:
//   UPDATE users SET is_active = false, token_version = token_version + 1 WHERE id = $1
// This ensures all existing JWTs are immediately rejected by authMiddleware Gate 4.

/**
 * Helper: extract client IP from request.
 * app.js sets trust proxy — req.ip is already the real client address.
 */
function getClientIp(req) {
  return req.ip || 'unknown';
}

/**
 * Helper: issue tokens and create session log entry.
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
 * Helper: load user by ID with role name (used by 2FA flows after temp token verification).
 * Includes pending_2fa_secret for server-side TOTP enrolment (FIX 10).
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
 * FIX 8/12: Check audit_log for 10+ login failures in 24h and fire alert email.
 * FIX 12: Gate prevents duplicate alerts — fires at most once per 24h per email.
 * A login_alert_sent entry is written to audit_log before the email send to
 * suppress subsequent triggers within the same window.
 * queryEmail is stored as new_value in audit_log for all login_failed actions.
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
    if (countResult.rows[0].cnt >= EMAIL_ALERT_THRESHOLD) {
      // FIX 12: Check if alert was already sent in this 24h window
      const alertedResult = await pool.query(
        `SELECT COUNT(*)::int AS cnt FROM audit_log
         WHERE action = 'login_alert_sent'
           AND new_value = $1
           AND created_at > now() - interval '24 hours'`,
        [queryEmail]
      );
      if (alertedResult.rows[0].cnt > 0) {
        return; // alert already sent in this window — suppress duplicate
      }

      const recentFailures = await pool.query(
        `SELECT ip_address, created_at FROM audit_log
         WHERE action = 'login_failed'
           AND new_value = $1
           AND created_at > now() - interval '24 hours'
         ORDER BY created_at DESC`,
        [queryEmail]
      );

      // Write audit entry before sending — reduces (but cannot fully eliminate
      // under concurrent load) duplicate sends. Acceptable for an internal ERP.
      await logAudit(null, 'login_alert_sent', { newValue: queryEmail });

      sendLoginAlertEmail(displayName, recentFailures.rows).catch((err) => {
        console.error('[Auth] Failed to send login alert email:', err.message);
      });
    }
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

  // FIX 6/14: typeof validation — reject non-string inputs (prevents object injection attacks)
  if (!email || !password || typeof email !== 'string' || typeof password !== 'string') {
    return res.status(400).json({ message: 'Email and password are required' });
  }

  // Load user by email
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

  // Unknown email — FIX 4: run dummy bcrypt to prevent timing-based enumeration
  if (!user) {
    await bcrypt.compare(password, DUMMY_HASH);
    await logAudit(null, 'login_failed', {
      ipAddress: ip,
      newValue: email,
    });
    // FIX 8: alert check runs on unknown-email path
    await checkAndSendLoginAlert(email, email);
    return res.status(401).json({ message: 'Invalid email or password' });
  }

  // Account deactivated — FIX 7: generic message, no information leakage
  if (!user.is_active) {
    await logAudit(user.id, 'login_failed', {
      ipAddress: ip,
      newValue: user.email,
    });
    await checkAndSendLoginAlert(user.email, user.username || user.email);
    return res.status(401).json({ message: 'Invalid email or password' });
  }

  // Lockout check — BEFORE bcrypt.compare to save CPU
  // FIX 7: generic message (423 status preserved; message normalized)
  if (user.locked_until && new Date(user.locked_until) > new Date()) {
    await logAudit(user.id, 'login_failed', {
      ipAddress: ip,
      newValue: user.email,
    });
    await checkAndSendLoginAlert(user.email, user.username || user.email);
    return res.status(423).json({ message: 'Invalid email or password' });
  }

  // FIX 13: Lockout expired naturally — reset counter to give user a clean slate.
  // Without this, failed_login_attempts remains at 5+, causing immediate re-lock
  // on the next wrong guess after the 30-minute wait period.
  if (user.locked_until && new Date(user.locked_until) <= new Date()) {
    await pool.query(
      `UPDATE users SET failed_login_attempts = 0, locked_until = NULL WHERE id = $1`,
      [user.id]
    );
  }

  // Password verification
  const passwordValid = await bcrypt.compare(password, user.password_hash);

  if (!passwordValid) {
    // FIX 9: Atomic increment + conditional lock in a single UPDATE — eliminates race condition
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

    // Audit log — store email in new_value as the 24h alert query key
    await logAudit(user.id, 'login_failed', {
      ipAddress: ip,
      newValue: user.email,
    });

    // FIX 8: alert check unified across all login_failed paths
    await checkAndSendLoginAlert(user.email, user.username || user.email);

    return res.status(401).json({ message: 'Invalid email or password' });
  }

  // --- Password is correct ---

  // Reset lockout counters
  await pool.query(
    `UPDATE users SET failed_login_attempts = 0, locked_until = NULL WHERE id = $1`,
    [user.id]
  );

  // Check if role requires 2FA
  if (TWO_FA_ROLES.includes(user.role_name)) {
    const tempToken = generateTempToken(user);

    if (user.two_fa_enabled && user.two_fa_secret) {
      // 2FA is set up — user must verify TOTP code
      await logAudit(user.id, 'login_2fa_pending', { ipAddress: ip });
      return res.status(200).json({
        requires_2fa: true,
        temp_token: tempToken,
      });
    }

    // 2FA not yet set up — user must complete setup
    await logAudit(user.id, 'login_2fa_setup_required', { ipAddress: ip });
    return res.status(200).json({
      requires_2fa_setup: true,
      temp_token: tempToken,
    });
  }

  // Non-2FA role — issue tokens immediately
  const { accessToken, refreshToken } = await issueTokensAndCreateSession(user, req);

  await logAudit(user.id, 'login_success', { ipAddress: ip });

  return res.status(200).json({
    access_token: accessToken,
    refresh_token: refreshToken,
    user: {
      id: user.id,
      display_name: user.display_name,
      role: user.role_name,
    },
  });
}

// ============================================================================
// POST /auth/2fa/verify
// ============================================================================
async function twoFactorVerify(req, res) {
  const { temp_token, totp_code } = req.body;
  const ip = getClientIp(req);

  // FIX 14: typeof guard — reject non-string totp_code (prevents injection into speakeasy)
  if (!temp_token || !totp_code || typeof totp_code !== 'string') {
    return res.status(400).json({ message: 'temp_token and totp_code are required' });
  }

  // Verify temp token
  let payload;
  try {
    payload = verifyTempToken(temp_token);
  } catch (err) {
    return res.status(401).json({ message: 'Invalid or expired verification token' });
  }

  const user = await loadUserById(payload.user_id);
  if (!user || !user.is_active) {
    return res.status(401).json({ message: 'Invalid token' });
  }

  // token_version must still match
  if (payload.token_version !== user.token_version) {
    return res.status(401).json({ message: 'Session invalidated' });
  }

  if (!user.two_fa_secret) {
    return res.status(400).json({ message: '2FA not configured for this account' });
  }

  // Verify TOTP code
  const isValid = twoFactor.verifyToken(user.two_fa_secret, totp_code);
  if (!isValid) {
    await logAudit(user.id, '2fa_failed', { ipAddress: ip });
    return res.status(401).json({ message: 'Invalid TOTP code' });
  }

  // 2FA passed — issue real tokens
  const { accessToken, refreshToken } = await issueTokensAndCreateSession(user, req);

  await logAudit(user.id, 'login_success', {
    ipAddress: ip,
    newValue: JSON.stringify({ method: '2fa_totp' }),
  });

  return res.status(200).json({
    access_token: accessToken,
    refresh_token: refreshToken,
    user: {
      id: user.id,
      display_name: user.display_name,
      role: user.role_name,
    },
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

  let payload;
  try {
    payload = verifyTempToken(temp_token);
  } catch (err) {
    return res.status(401).json({ message: 'Invalid or expired verification token' });
  }

  const user = await loadUserById(payload.user_id);
  if (!user || !user.is_active) {
    return res.status(401).json({ message: 'Invalid token' });
  }

  if (payload.token_version !== user.token_version) {
    return res.status(401).json({ message: 'Session invalidated' });
  }

  // FIX 11: Guard against double-setup — overwriting pending_2fa_secret would silently
  // break any authenticator app already scanning the first QR code.
  if (user.pending_2fa_secret) {
    return res.status(400).json({ message: '2FA setup is already in progress. Please scan the QR code already sent or contact your Operations Manager.' });
  }

  // FIX 3: Guard against re-initiating setup on an already-configured account
  if (user.two_fa_enabled && user.two_fa_secret) {
    return res.status(400).json({ message: '2FA is already configured for this account' });
  }

  // Generate new TOTP secret
  const { secret, otpauth_url } = twoFactor.generateSecret(user.email);
  const qrCode = await twoFactor.generateQRCode(otpauth_url);

  // FIX 10: Store secret server-side — client never receives the raw secret
  await pool.query(
    `UPDATE users SET pending_2fa_secret = $1 WHERE id = $2`,
    [secret, user.id]
  );

  await logAudit(user.id, '2fa_setup_initiated', { ipAddress: ip });

  // Return only the QR code — secret is server-side only
  return res.status(200).json({
    qr_code: qrCode,
  });
}

// ============================================================================
// POST /auth/2fa/activate
// ============================================================================
async function twoFactorActivate(req, res) {
  // FIX 10: secret removed from request body — read from server-side storage
  const { temp_token, totp_code } = req.body;
  const ip = getClientIp(req);

  if (!temp_token || !totp_code) {
    return res.status(400).json({ message: 'temp_token and totp_code are required' });
  }

  let payload;
  try {
    payload = verifyTempToken(temp_token);
  } catch (err) {
    return res.status(401).json({ message: 'Invalid or expired verification token' });
  }

  const user = await loadUserById(payload.user_id);
  if (!user || !user.is_active) {
    return res.status(401).json({ message: 'Invalid token' });
  }

  if (payload.token_version !== user.token_version) {
    return res.status(401).json({ message: 'Session invalidated' });
  }

  // FIX 10: Read secret from server-side storage — never trust a client-supplied value
  if (!user.pending_2fa_secret) {
    return res.status(400).json({ message: '2FA setup has not been initiated — call /auth/2fa/setup first' });
  }

  // Verify TOTP code against the server-stored pending secret
  const isValid = twoFactor.verifyToken(user.pending_2fa_secret, totp_code);
  if (!isValid) {
    await logAudit(user.id, '2fa_activate_failed', { ipAddress: ip });
    return res.status(401).json({ message: 'Invalid TOTP code — scan the QR code and try again' });
  }

  // Atomically promote pending_2fa_secret → two_fa_secret and clear the pending column
  await pool.query(
    `UPDATE users
     SET two_fa_secret = pending_2fa_secret,
         two_fa_enabled = true,
         pending_2fa_secret = NULL
     WHERE id = $1`,
    [user.id]
  );

  // Reload user with fresh state for token generation
  const updatedUser = await loadUserById(user.id);

  // Issue real tokens
  const { accessToken, refreshToken } = await issueTokensAndCreateSession(updatedUser, req);

  await logAudit(user.id, '2fa_activated', { ipAddress: ip });

  return res.status(200).json({
    access_token: accessToken,
    refresh_token: refreshToken,
    user: {
      id: updatedUser.id,
      display_name: updatedUser.display_name,
      role: updatedUser.role_name,
    },
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

  // Load current token_version from DB
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

  // Stateless invalidation: compare payload version against DB version
  if (payload.token_version !== user.token_version) {
    return res.status(401).json({ message: 'Session invalidated — please log in again' });
  }

  // Issue rotated token pair
  const accessToken = generateAccessToken(user);
  const refreshToken = generateRefreshToken(user);

  // Audit trail for forensic analysis of stolen refresh token usage
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

  // FIX 14: typeof guard — non-string new_password would throw in bcrypt.hash
  if (
    !current_password || !new_password ||
    typeof current_password !== 'string' || typeof new_password !== 'string'
  ) {
    return res.status(400).json({ message: 'current_password and new_password are required' });
  }

  if (new_password.length < 8) {
    return res.status(400).json({ message: 'New password must be at least 8 characters' });
  }

  // Load current hash
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

  // Hash new password and increment token_version atomically
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

  // Increment token_version — invalidates ALL tokens for this user everywhere
  await pool.query(
    `UPDATE users SET token_version = token_version + 1 WHERE id = $1`,
    [userId]
  );

  // Close all open sessions
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
