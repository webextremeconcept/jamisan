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

// MODULE 5 REQUIREMENT (Gemini FIX 3): Any admin route that toggles is_active = false
// MUST also increment token_version atomically in the same UPDATE statement:
//   UPDATE users SET is_active = false, token_version = token_version + 1 WHERE id = $1
// This ensures all existing JWTs are immediately rejected by authMiddleware Gate 4.

/**
 * Helper: extract client IP from request.
 * Respects X-Forwarded-For (Cloudflare / Nginx proxy).
 */
function getClientIp(req) {
  const forwarded = req.headers['x-forwarded-for'];
  if (forwarded) {
    return forwarded.split(',')[0].trim();
  }
  return req.ip || req.connection?.remoteAddress || 'unknown';
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
 */
async function loadUserById(userId) {
  const result = await pool.query(
    `SELECT u.id, u.role_id, r.name AS role_name, u.email, u.display_name,
            u.token_version, u.is_active, u.two_fa_enabled, u.two_fa_secret
     FROM users u
     JOIN roles r ON r.id = u.role_id
     WHERE u.id = $1`,
    [userId]
  );
  return result.rows[0] || null;
}

// ============================================================================
// POST /auth/login
// ============================================================================
async function login(req, res) {
  const { email, password } = req.body;
  const ip = getClientIp(req);

  if (!email || !password) {
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

  // Unknown email — audit with null userId, store email in new_value for 24h query
  if (!user) {
    await logAudit(null, 'login_failed', {
      ipAddress: ip,
      newValue: email,
    });
    return res.status(401).json({ message: 'Invalid email or password' });
  }

  // Account deactivated
  if (!user.is_active) {
    await logAudit(user.id, 'login_failed', {
      ipAddress: ip,
      newValue: user.email,
    });
    return res.status(401).json({ message: 'Account deactivated — contact your Operations Manager' });
  }

  // Lockout check — BEFORE bcrypt.compare to save CPU
  if (user.locked_until && new Date(user.locked_until) > new Date()) {
    await logAudit(user.id, 'login_failed', {
      ipAddress: ip,
      newValue: user.email,
    });
    return res.status(423).json({ message: 'Account locked — try again later' });
  }

  // Password verification
  const passwordValid = await bcrypt.compare(password, user.password_hash);

  if (!passwordValid) {
    // Atomic increment at DB level — never read/increment/write in JS (Gemini FIX 2)
    const incrementResult = await pool.query(
      `UPDATE users SET failed_login_attempts = failed_login_attempts + 1
       WHERE id = $1
       RETURNING failed_login_attempts`,
      [user.id]
    );
    const newAttempts = incrementResult.rows[0].failed_login_attempts;

    // Lock account if threshold reached
    if (newAttempts >= LOCKOUT_THRESHOLD) {
      const lockUntil = new Date(Date.now() + LOCKOUT_DURATION_MIN * 60 * 1000);
      await pool.query(
        `UPDATE users SET locked_until = $1 WHERE id = $2`,
        [lockUntil, user.id]
      );
    }

    // Audit log — store email in new_value as the 24h alert query key
    await logAudit(user.id, 'login_failed', {
      ipAddress: ip,
      newValue: user.email,
    });

    // Email alert: count failures in audit_log within 24h (source of truth)
    // This survives counter resets from successful logins
    const countResult = await pool.query(
      `SELECT COUNT(*)::int AS cnt FROM audit_log
       WHERE action = 'login_failed'
         AND new_value = $1
         AND created_at > now() - interval '24 hours'`,
      [user.email]
    );
    const failuresIn24h = countResult.rows[0].cnt;

    if (failuresIn24h >= EMAIL_ALERT_THRESHOLD) {
      const recentFailures = await pool.query(
        `SELECT ip_address, created_at FROM audit_log
         WHERE action = 'login_failed'
           AND new_value = $1
           AND created_at > now() - interval '24 hours'
         ORDER BY created_at DESC`,
        [user.email]
      );
      sendLoginAlertEmail(user.username, recentFailures.rows).catch((err) => {
        console.error('[Auth] Failed to send login alert email:', err.message);
      });
    }

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

  if (!temp_token || !totp_code) {
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

  // Generate new TOTP secret
  const { secret, otpauth_url } = twoFactor.generateSecret(user.email);
  const qrCode = await twoFactor.generateQRCode(otpauth_url);

  await logAudit(user.id, '2fa_setup_initiated', { ipAddress: ip });

  return res.status(200).json({
    secret,
    qr_code: qrCode,
  });
}

// ============================================================================
// POST /auth/2fa/activate
// ============================================================================
async function twoFactorActivate(req, res) {
  const { temp_token, secret, totp_code } = req.body;
  const ip = getClientIp(req);

  if (!temp_token || !secret || !totp_code) {
    return res.status(400).json({ message: 'temp_token, secret, and totp_code are required' });
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

  // Verify the TOTP code against the provided secret to confirm the user scanned correctly
  const isValid = twoFactor.verifyToken(secret, totp_code);
  if (!isValid) {
    await logAudit(user.id, '2fa_activate_failed', { ipAddress: ip });
    return res.status(401).json({ message: 'Invalid TOTP code — scan the QR code and try again' });
  }

  // Persist the secret and enable 2FA
  await pool.query(
    `UPDATE users SET two_fa_secret = $1, two_fa_enabled = true WHERE id = $2`,
    [secret, user.id]
  );

  // Reload user with updated token_version for token generation
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

  if (!current_password || !new_password) {
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
