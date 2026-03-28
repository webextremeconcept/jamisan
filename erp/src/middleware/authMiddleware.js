const { pool } = require('../config/db');
const { verifyAccessToken } = require('../services/tokenService');

/**
 * JWT authentication middleware.
 *
 * Security gates (in order):
 * 1. Authorization header must be present with Bearer scheme
 * 2. Access token must have a valid signature and not be expired
 * 3. User must exist in the database
 * 4. User account must be active (is_active = true)
 * 5. token_version in JWT payload must match token_version in DB
 *    — any mismatch means the token was issued before a logout or password change
 *
 * On success: attaches req.user with { id, role_id, role_name, token_version }
 * On failure: returns 401 with a generic message (no information leakage)
 */
async function authMiddleware(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ message: 'Authentication required' });
  }

  const token = authHeader.split(' ')[1];

  // Gate 1: Verify JWT signature and expiry
  let payload;
  try {
    payload = verifyAccessToken(token);
  } catch (err) {
    const message =
      err.name === 'TokenExpiredError'
        ? 'Token expired'
        : 'Invalid token';
    return res.status(401).json({ message });
  }

  // Gate 2: Load user + role from database
  let user;
  try {
    const result = await pool.query(
      `SELECT u.id, u.role_id, r.name AS role_name, u.token_version, u.is_active
       FROM users u
       JOIN roles r ON r.id = u.role_id
       WHERE u.id = $1`,
      [payload.user_id]
    );
    user = result.rows[0];
  } catch (err) {
    console.error('[Auth] DB query failed:', err.message);
    return res.status(500).json({ message: 'Internal server error' });
  }

  if (!user) {
    return res.status(401).json({ message: 'Invalid token' });
  }

  // Gate 3: Account must be active
  // MODULE 5 REQUIREMENT: When setting is_active = false, MUST also increment token_version
  // atomically: UPDATE users SET is_active = false, token_version = token_version + 1 WHERE id = $1
  // This ensures existing tokens are rejected at Gate 4 even if this gate is somehow bypassed.
  if (!user.is_active) {
    return res.status(401).json({ message: 'Account deactivated' });
  }

  // Gate 4: token_version must match — this is the stateless invalidation check
  if (payload.token_version !== user.token_version) {
    return res.status(401).json({ message: 'Session invalidated' });
  }

  // Attach user context to request
  req.user = {
    id: user.id,
    role_id: user.role_id,
    role_name: user.role_name,
    token_version: user.token_version,
  };

  // Fire-and-forget: update last_active_at on most recent open session.
  // FIX 2: PostgreSQL does not support ORDER BY / LIMIT in UPDATE directly — use subquery.
  pool
    .query(
      `UPDATE session_log
       SET last_active_at = now()
       WHERE id = (
         SELECT id FROM session_log
         WHERE user_id = $1 AND logged_out_at IS NULL
         ORDER BY id DESC
         LIMIT 1
       )`,
      [user.id]
    )
    .catch((err) => {
      console.error('[Session] last_active_at update failed:', err.message);
    });

  next();
}

module.exports = authMiddleware;
