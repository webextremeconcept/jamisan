const { pool } = require('../config/db');

/**
 * Write an immutable entry to the audit_log table.
 *
 * audit_log has rules preventing UPDATE and DELETE (Module 1 FIX 2),
 * so entries are permanent once written.
 *
 * @param {number|null} userId   - ID of the acting user (null for anonymous/failed login)
 * @param {string}      action   - Action identifier (e.g. 'login_success', 'login_failed', '2fa_failed')
 * @param {object}      details  - Additional context
 * @param {string}      [details.tableName]  - Target table name
 * @param {number}      [details.recordId]   - Target record ID
 * @param {string}      [details.oldValue]   - Previous value (JSON string or text)
 * @param {string}      [details.newValue]   - New value (JSON string or text)
 * @param {string}      [details.ipAddress]  - Client IP address
 */
async function logAudit(userId, action, details = {}) {
  const {
    tableName = null,
    recordId = null,
    oldValue = null,
    newValue = null,
    ipAddress = null,
  } = details;

  try {
    await pool.query(
      `INSERT INTO audit_log (user_id, action, table_name, record_id, old_value, new_value, ip_address)
       VALUES ($1, $2, $3, $4, $5, $6, $7)`,
      [userId, action, tableName, recordId, oldValue, newValue, ipAddress]
    );
  } catch (err) {
    // Never let audit logging failures crash the request.
    // Log to stdout for ops monitoring — the primary action still proceeds.
    console.error(`[Audit] Failed to write audit log: ${err.message}`, {
      userId,
      action,
      ipAddress,
    });
  }
}

module.exports = { logAudit };
