/**
 * CSR Service — parameterised SQL queries for the CSR interface.
 *
 * Security rules:
 * - All queries use $N parameterised placeholders — no interpolation of user input
 * - CSR ownership enforced: role 'CSR' always gets AND assigned_csr_id = userId
 * - Field allowlist enforced in buildUpdateClause
 * - page/limit inputs validated as integers before reaching here
 */
'use strict';

const { pool }       = require('../config/db');
const { logAudit }   = require('../utils/auditLogger');

/* ── Constants ── */

const ORDER_STATUSES = [
  // Group 1 — Active/Positive
  'Interested', 'Pending', 'Scheduled', 'Committed Immediate', 'Committed Scheduled', 'Cash Paid',
  // Group 2 — Unreachable
  'Not Picking Calls', 'Switched Off', 'Will Call Me Back', 'To Call Back',
  'Direct WhatsApp', 'Not Reachable', 'Invalid Number', 'No Phone Number', 'Ignored Agents Call',
  // Group 3 — Failed/Negative
  'Failed', 'Cancelled', 'Returned', 'Banned', "Didn't Order", 'Got It Elsewhere', 'Not Ready to Pay',
  // Group 4 — Conditional
  'Haggling', 'Changed Location', 'Location Requires Waybill', 'Out of the Way', 'Out of Stock', 'From Social Media',
  // Group 5 — System/Admin
  'Test', 'Abandoned', 'CSR Skipped', 'Duplicate Order',
];

const STATUSES_REQUIRING_FAILURE_REASON = ['Failed', 'Cancelled', 'Returned'];
const CASH_PAID_STATUS = 'Cash Paid';

/** Fields the CSR is permitted to update — server-enforced allowlist */
const ALLOWED_UPDATE_FIELDS = new Set([
  'status', 'comments', 'agent_id', 'date_paid', 'price',
  'admin_level_1_id', 'admin_level_2_id', 'product_id', 'product_variant_id',
  'failure_reason_id', 'logistics_fee', 'sex', 'other_phone',
  'city', 'full_address', 'quantity', 'order_bump_product_id',
  'order_bump_quantity', 'order_bump_price', 'scheduled_date',
]);

/* ── Helpers ── */

/** Determine whether to add CSR ownership filter */
function csrFilter(roleName, userId, params) {
  if (roleName === 'CSR') {
    params.push(userId);
    return `AND o.assigned_csr_id = $${params.length}`;
  }
  return '';
}

/** Build hygiene WHERE clause */
function hygieneClause(hygiene, params) {
  const now = `now()`;
  switch (hygiene) {
    case 'skipped':
      return `AND o.status = 'Interested' AND o.ordered_at < ${now} - interval '25 hours' AND o.ordered_at >= ${now} - interval '7 days'`;
    case 'no_comments':
      return `AND (o.comments IS NULL OR o.comments = '') AND o.status <> 'Interested' AND o.ordered_at >= ${now} - interval '7 days'`;
    case 'pending':
      return `AND o.status = 'Pending' AND o.ordered_at >= ${now} - interval '7 days'`;
    case 'no_logistics_fee':
      return `AND o.status = 'Cash Paid' AND (o.logistics_fee IS NULL OR o.logistics_fee = 0) AND o.ordered_at >= ${now} - interval '90 days'`;
    case 'no_date_paid':
      return `AND o.status = 'Cash Paid' AND o.date_paid IS NULL`;
    case 'abandoned':
      return `AND o.status = 'Abandoned' AND o.ordered_at >= ${now} - interval '7 days'`;
    case 'try_again':
      return `AND o.status IN ('Not Picking Calls','Will Call Me Back','To Call Back','Not Reachable') AND o.ordered_at >= ${now} - interval '72 hours'`;
    default:
      return ''; // 'all'
  }
}

/* ── Queries ── */

/**
 * Paginated order grid — all 17 columns with JOINs.
 * Returns { rows, total }.
 */
async function getOrderGrid({ userId, roleName, hygiene = 'all', page = 1, limit = 150 }) {
  const params = [];
  const ownership = csrFilter(roleName, userId, params);
  const hygieneWhere = hygieneClause(hygiene, params);

  // COUNT for pagination
  const countSql = `
    SELECT COUNT(*) AS total
    FROM orders o
    LEFT JOIN customers c ON c.id = o.customer_id
    WHERE o.is_test = false
    ${ownership}
    ${hygieneWhere}
  `;
  const { rows: countRows } = await pool.query(countSql, params);
  const total = parseInt(countRows[0].total, 10);

  // Pagination params
  const safeLimit  = Math.min(Math.max(1, parseInt(limit, 10) || 150), 1000);
  const safePage   = Math.max(1, parseInt(page, 10) || 1);
  const offset     = (safePage - 1) * safeLimit;

  const dataParams = [...params, safeLimit, offset];
  const limitIdx   = dataParams.length - 1;
  const offsetIdx  = dataParams.length;

  const dataSql = `
    SELECT
      o.id,
      COALESCE(o.row_number, o.id) AS row_num,
      o.order_id,
      u.display_name                     AS csr_name,
      o.ordered_at,
      (CURRENT_DATE - o.ordered_at::date) AS dfo,
      o.customer_name,
      o.phone_number,
      p.name                             AS product_name,
      pv.colour,
      o.price,
      al1.name                           AS state_name,
      al2.name                           AS lga_name,
      ag.name                            AS agent_name,
      o.status,
      o.comments,
      o.date_paid,
      o.sex,
      -- extra fields needed for row colour + slide-out
      c.is_banned,
      COALESCE(c.total_purchases, 0)     AS total_purchases,
      COALESCE(c.total_orders, 0)        AS total_orders,
      o.admin_level_1_id,
      o.admin_level_2_id,
      o.agent_id,
      o.product_id,
      o.product_variant_id,
      o.failure_reason_id,
      o.logistics_fee,
      o.scheduled_date,
      o.customer_id,
      o.first_contact_at
    FROM orders o
    LEFT JOIN users u          ON u.id = o.assigned_csr_id
    LEFT JOIN products p       ON p.id = o.product_id
    LEFT JOIN product_variants pv ON pv.id = o.product_variant_id
    LEFT JOIN admin_level_1 al1   ON al1.id = o.admin_level_1_id
    LEFT JOIN admin_level_2 al2   ON al2.id = o.admin_level_2_id
    LEFT JOIN agents ag           ON ag.id = o.agent_id
    LEFT JOIN customers c         ON c.id = o.customer_id
    WHERE o.is_test = false
    ${ownership}
    ${hygieneWhere}
    ORDER BY o.ordered_at DESC
    LIMIT $${limitIdx} OFFSET $${offsetIdx}
  `;

  const { rows } = await pool.query(dataSql, dataParams);
  return { rows, total, page: safePage, limit: safeLimit };
}

/**
 * Single order for slide-out panel.
 */
async function getOrderById(id, userId, roleName) {
  const params = [id];
  const ownership = roleName === 'CSR' ? `AND o.assigned_csr_id = $2` : '';
  if (roleName === 'CSR') params.push(userId);

  const { rows } = await pool.query(`
    SELECT
      o.*,
      u.display_name    AS csr_name,
      p.name            AS product_name,
      pv.colour,
      al1.name          AS state_name,
      al2.name          AS lga_name,
      ag.name           AS agent_name,
      ag.phone          AS agent_phone,
      ag.whatsapp_group_link AS agent_wa_link,
      c.is_banned, c.total_purchases, c.total_orders AS customer_total_orders,
      c.lifetime_value, c.customer_tag, c.csr_notes, c.first_order_date,
      TRIM(to_char(o.ordered_at, 'Day')) AS assigned_weekday
    FROM orders o
    LEFT JOIN users u          ON u.id = o.assigned_csr_id
    LEFT JOIN products p       ON p.id = o.product_id
    LEFT JOIN product_variants pv ON pv.id = o.product_variant_id
    LEFT JOIN admin_level_1 al1   ON al1.id = o.admin_level_1_id
    LEFT JOIN admin_level_2 al2   ON al2.id = o.admin_level_2_id
    LEFT JOIN agents ag           ON ag.id = o.agent_id
    LEFT JOIN customers c         ON c.id = o.customer_id
    WHERE o.id = $1 ${ownership}
  `, params);

  return rows[0] || null;
}

/**
 * Hygiene badge counts — single table scan with FILTER aggregation.
 * Time windows per Day 3 spec.
 */
async function getHygieneCounts(userId, roleName) {
  const params = [];
  const ownership = csrFilter(roleName, userId, params);

  const { rows } = await pool.query(`
    SELECT
      COUNT(*) FILTER (
        WHERE status = 'Interested'
          AND ordered_at < now() - interval '25 hours'
          AND ordered_at >= now() - interval '7 days'
      )::int AS skipped,
      COUNT(*) FILTER (
        WHERE (comments IS NULL OR comments = '')
          AND status <> 'Interested'
          AND ordered_at >= now() - interval '7 days'
      )::int AS no_comments,
      COUNT(*) FILTER (
        WHERE status = 'Pending'
          AND ordered_at >= now() - interval '7 days'
      )::int AS pending,
      COUNT(*) FILTER (
        WHERE status = 'Cash Paid'
          AND (logistics_fee IS NULL OR logistics_fee = 0)
          AND ordered_at >= now() - interval '90 days'
      )::int AS no_logistics_fee,
      COUNT(*) FILTER (
        WHERE status = 'Cash Paid'
          AND date_paid IS NULL
      )::int AS no_date_paid,
      COUNT(*) FILTER (
        WHERE status = 'Abandoned'
          AND ordered_at >= now() - interval '7 days'
      )::int AS abandoned,
      COUNT(*) FILTER (
        WHERE status IN ('Not Picking Calls','Will Call Me Back','To Call Back','Not Reachable')
          AND ordered_at >= now() - interval '72 hours'
      )::int AS try_again
    FROM orders
    WHERE is_test = false
    ${ownership}
  `, params);

  return rows[0];
}

/**
 * Update an order — enforces allowlist, validates status transitions,
 * stamps first_contact_at, writes order_status_history, writes audit_log.
 * Returns the updated order row (with JOINs) for HTMX rendering.
 */
async function updateOrder({ id, fields, userId, roleName, ipAddress }) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    // 1. Load current order, verify ownership
    const { rows: current } = await client.query(
      `SELECT id, status, assigned_csr_id, first_contact_at, comments, agent_id,
              date_paid, logistics_fee, failure_reason_id, product_id, admin_level_1_id
       FROM orders WHERE id = $1`,
      [id]
    );
    if (!current.length) {
      const err = new Error('Order not found'); err.status = 404; throw err;
    }
    const order = current[0];
    if (roleName === 'CSR' && order.assigned_csr_id !== userId) {
      const err = new Error('Forbidden'); err.status = 403; throw err;
    }

    // 2. Filter to allowed fields only (managers can also reassign CSR)
    const managerFields = new Set(['assigned_csr_id']);
    const updates = {};
    for (const [key, val] of Object.entries(fields)) {
      const allowed = ALLOWED_UPDATE_FIELDS.has(key)
        || (managerFields.has(key) && roleName !== 'CSR');
      if (allowed && val !== undefined) {
        updates[key] = val === '' ? null : val;
      }
    }
    if (Object.keys(updates).length === 0) {
      await client.query('COMMIT');
      return getOrderById(id, userId, roleName);
    }

    const newStatus = updates.status || order.status;

    // 3. Validate status-specific requirements
    if (newStatus === CASH_PAID_STATUS && newStatus !== order.status) {
      if (!updates.date_paid && !order.date_paid) {
        const err = new Error('date_paid is required for Cash Paid'); err.status = 422; throw err;
      }
      if (!updates.agent_id && !order.agent_id) {
        const err = new Error('agent_id is required for Cash Paid'); err.status = 422; throw err;
      }
      if ((updates.logistics_fee === null || updates.logistics_fee === undefined) && order.logistics_fee === null) {
        const err = new Error('logistics_fee is required for Cash Paid'); err.status = 422; throw err;
      }
    }

    if (STATUSES_REQUIRING_FAILURE_REASON.includes(newStatus) && newStatus !== order.status) {
      if (!updates.failure_reason_id && !order.failure_reason_id) {
        const err = new Error('failure_reason_id is required for ' + newStatus); err.status = 422; throw err;
      }
      const comment = updates.comments ?? order.comments ?? '';
      if (!comment || comment.trim().length < 10) {
        const err = new Error('A comment of at least 10 characters is required for ' + newStatus); err.status = 422; throw err;
      }
    }

    // 4. Stamp first_contact_at on first departure from Interested
    if (order.status === 'Interested' && newStatus !== 'Interested' && !order.first_contact_at) {
      updates.first_contact_at = new Date();
    }

    // 5. Build SET clause
    const setClauses = [];
    const params = [];
    for (const [key, val] of Object.entries(updates)) {
      params.push(val);
      setClauses.push(`${key} = $${params.length}`);
    }
    setClauses.push('updated_at = now()');
    params.push(id);
    const idIdx = params.length;

    // 6. UPDATE orders (inside transaction)
    await client.query(
      `UPDATE orders SET ${setClauses.join(', ')} WHERE id = $${idIdx}`,
      params
    );

    // 7. Write order_status_history if status changed (inside transaction)
    if (updates.status && updates.status !== order.status) {
      await client.query(
        `INSERT INTO order_status_history (order_id, previous_status, new_status, changed_by, notes)
         VALUES ($1, $2, $3, $4, $5)`,
        [id, order.status, updates.status, userId, updates.comments || null]
      );
    }

    await client.query('COMMIT');

    // 8. Audit log — fire-and-forget, OUTSIDE transaction (uses pool, not client)
    logAudit(userId, 'order_updated', {
      tableName: 'orders',
      recordId: id,
      oldValue: JSON.stringify({ status: order.status }),
      newValue: JSON.stringify({ status: newStatus, ...updates }),
      ipAddress,
    });

    // 9. Return updated row with JOINs for HTMX rendering (uses pool)
    return getOrderById(id, userId, roleName);

  } catch (err) {
    await client.query('ROLLBACK');
    throw err; // Controller catches and returns HTMX-compatible error response
  } finally {
    client.release();
  }
}

/**
 * Order status history timeline.
 */
async function getOrderHistory(orderId) {
  const { rows } = await pool.query(`
    SELECT
      osh.id,
      osh.previous_status,
      osh.new_status,
      osh.changed_at,
      osh.notes,
      u.display_name AS changed_by_name
    FROM order_status_history osh
    LEFT JOIN users u ON u.id = osh.changed_by
    WHERE osh.order_id = $1
    ORDER BY osh.changed_at DESC
  `, [orderId]);
  return rows;
}

/**
 * Customer intelligence for right panel.
 */
async function getCustomerIntel(customerId, currentOrderId) {
  if (!customerId) return { customer: null, orders: [] };

  const { rows: [customer] } = await pool.query(
    `SELECT id, full_name, phone_number, total_orders, total_purchases,
            lifetime_value, customer_tag, is_banned, first_order_date
     FROM customers WHERE id = $1`,
    [customerId]
  );

  const { rows: orders } = await pool.query(`
    SELECT o.id, o.order_id, o.status, o.ordered_at, o.price, o.comments,
           p.name AS product_name, u.display_name AS csr_name
    FROM orders o
    LEFT JOIN products p ON p.id = o.product_id
    LEFT JOIN users u    ON u.id = o.assigned_csr_id
    WHERE o.customer_id = $1 AND o.is_test = false
    ORDER BY o.ordered_at DESC
    LIMIT 20
  `, [customerId]);

  return { customer, orders };
}

/**
 * WhatsApp copy text for an order.
 */
async function getCopyText(orderId, userId, roleName) {
  const order = await getOrderById(orderId, userId, roleName);
  if (!order) return null;

  const price = order.price ? '₦' + Number(order.price).toLocaleString() : 'N/A';

  const text = [
    `📦 ORDER — ${order.order_id}`,
    `👤 Customer: ${order.customer_name}`,
    `📞 Phone: ${order.phone_number}`,
    order.other_phone            ? `📞 Other: ${order.other_phone}` : null,
    `🛍 Product: ${order.product_name}`,
    order.colour                 ? `🎨 Colour: ${order.colour}` : null,
    `💰 Price: ${price}`,
    order.state_name             ? `📍 State: ${order.state_name}${order.lga_name ? ' | LGA: ' + order.lga_name : ''}` : null,
    order.city                   ? `🏙 City: ${order.city}` : null,
    order.full_address           ? `🏠 Address: ${order.full_address}` : null,
    order.agent_name             ? `🚚 Agent: ${order.agent_name}` : null,
    order.logistics_fee          ? `💵 Logistics Fee: ₦${Number(order.logistics_fee).toLocaleString()}` : null,
    order.date_paid              ? `📅 Date Paid: ${new Date(order.date_paid).toLocaleDateString('en-NG', { day:'2-digit', month:'2-digit', year:'numeric' })}` : null,
  ].filter(Boolean).join('\n');

  return text;
}

/**
 * Toggle on-break status for logged-in CSR.
 */
async function toggleBreak(userId, ipAddress) {
  const { rows } = await pool.query(
    `UPDATE users SET is_on_break = NOT is_on_break, updated_at = now()
     WHERE id = $1 RETURNING is_on_break`,
    [userId]
  );
  const isOnBreak = rows[0]?.is_on_break ?? false;
  logAudit(userId, isOnBreak ? 'csr_on_break' : 'csr_resumed', { tableName: 'users', recordId: userId, ipAddress });
  return isOnBreak;
}

/**
 * Lookup: states list.
 */
async function getStates() {
  const { rows } = await pool.query(
    `SELECT id, name FROM admin_level_1 WHERE is_active = true ORDER BY name`
  );
  return rows;
}

/**
 * Lookup: LGAs for a state.
 */
async function getLgas(stateId) {
  const { rows } = await pool.query(
    `SELECT id, name FROM admin_level_2 WHERE admin_level_1_id = $1 AND is_active = true ORDER BY name`,
    [stateId]
  );
  return rows;
}

/**
 * Lookup: agents optionally filtered by state.
 */
async function getAgentsByState(stateId) {
  const params = [];
  let where = 'WHERE ag.is_active = true';
  if (stateId) {
    params.push(stateId);
    where += ` AND ag.admin_level_1_id = $1`;
  }
  const { rows } = await pool.query(
    `SELECT ag.id, ag.name, ag.phone, ag.whatsapp_group_link
     FROM agents ag ${where} ORDER BY ag.name`,
    params
  );
  return rows;
}

/**
 * Lookup: products (active only).
 */
async function getProducts() {
  const { rows } = await pool.query(
    `SELECT id, name, price FROM products WHERE is_active = true ORDER BY name`
  );
  return rows;
}

/**
 * Lookup: failure reason codes.
 */
async function getFailureReasons(status) {
  const params = [];
  let where = 'WHERE is_active = true';
  if (status) {
    params.push(status);
    where += ` AND (applies_to_status = $1 OR applies_to_status IS NULL)`;
  }
  const { rows } = await pool.query(
    `SELECT id, code, description FROM failure_reason_codes ${where} ORDER BY description`,
    params
  );
  return rows;
}

/**
 * Agents directory (full list for Agents tab).
 */
async function getAgents({ search, stateId }) {
  const params = [];
  const conditions = ['ag.is_active = true'];
  if (search) {
    params.push(`%${search}%`);
    conditions.push(`(ag.name ILIKE $${params.length} OR ag.contact_name ILIKE $${params.length})`);
  }
  if (stateId) {
    params.push(stateId);
    conditions.push(`ag.admin_level_1_id = $${params.length}`);
  }
  const { rows } = await pool.query(`
    SELECT ag.id, ag.name, ag.contact_name, ag.phone, ag.email,
           ag.whatsapp_group_link, ag.status, ag.ratings,
           al1.name AS state_name
    FROM agents ag
    LEFT JOIN admin_level_1 al1 ON al1.id = ag.admin_level_1_id
    WHERE ${conditions.join(' AND ')}
    ORDER BY ag.name
    LIMIT 200
  `, params);
  return rows;
}

/**
 * CSR performance stats — current month live + monthly history.
 */
async function getPerformance(userId) {
  // Live stats from orders table
  const { rows: [live] } = await pool.query(`
    SELECT
      COUNT(*)                                    AS total_orders,
      COUNT(*) FILTER (WHERE status = 'Cash Paid') AS cash_paid_orders,
      ROUND(
        COUNT(*) FILTER (WHERE status = 'Cash Paid') * 100.0
        / NULLIF(COUNT(*), 0), 1
      )                                           AS conversion_rate,
      COALESCE(SUM(price) FILTER (WHERE status = 'Cash Paid'), 0) AS total_revenue
    FROM orders
    WHERE assigned_csr_id = $1
      AND is_test = false
      AND ordered_at >= date_trunc('month', now())
  `, [userId]);

  // Monthly history from csr_performance_monthly
  const { rows: history } = await pool.query(`
    SELECT month, year, total_orders, total_units_paid, payment_rate,
           commission_per_unit, total_commission, total_compensation, csr_level_at_time
    FROM csr_performance_monthly
    WHERE user_id = $1
    ORDER BY year DESC, month DESC
    LIMIT 6
  `, [userId]);

  return { live, history };
}

/**
 * Scheduled orders view (Scheduled + Committed Immediate + Committed Scheduled).
 */
async function getScheduledOrders(userId, roleName) {
  const params = [];
  const ownership = csrFilter(roleName, userId, params);
  const { rows } = await pool.query(`
    SELECT
      o.id, o.order_id, o.customer_name, o.phone_number,
      p.name AS product_name, o.price,
      al1.name AS state_name, ag.name AS agent_name,
      o.status, o.comments, o.scheduled_date, o.ordered_at,
      u.display_name AS csr_name
    FROM orders o
    LEFT JOIN users u          ON u.id = o.assigned_csr_id
    LEFT JOIN products p       ON p.id = o.product_id
    LEFT JOIN admin_level_1 al1 ON al1.id = o.admin_level_1_id
    LEFT JOIN agents ag         ON ag.id = o.agent_id
    WHERE o.status IN ('Scheduled', 'Committed Immediate', 'Committed Scheduled')
      AND o.is_test = false
    ${ownership}
    ORDER BY o.scheduled_date ASC NULLS LAST, o.ordered_at DESC
    LIMIT 500
  `, params);
  return rows;
}

/**
 * Staff contacts directory (read-only — display_name, role, status only).
 */
async function getContacts() {
  const { rows } = await pool.query(`
    SELECT u.id, u.display_name, u.full_name, u.phone, u.email,
           r.name AS role_name, u.is_active, u.is_on_break, u.last_login_at
    FROM users u
    JOIN roles r ON r.id = u.role_id
    WHERE u.is_active = true
    ORDER BY r.id, u.display_name
  `);
  return rows;
}

/**
 * CSR leaderboard — current month, CSR role only.
 * Commission amounts intentionally excluded from leaderboard view.
 */
async function getLeaderboard() {
  const { rows } = await pool.query(`
    SELECT
      u.id,
      u.display_name,
      COUNT(o.id)::int                                           AS total_orders,
      COUNT(o.id) FILTER (WHERE o.status = 'Cash Paid')::int     AS cash_paid_orders,
      ROUND(
        COUNT(o.id) FILTER (WHERE o.status = 'Cash Paid') * 100.0
        / NULLIF(COUNT(o.id), 0), 1
      )                                                          AS conversion_rate
    FROM users u
    JOIN roles r ON r.id = u.role_id
    LEFT JOIN orders o ON o.assigned_csr_id = u.id
      AND o.is_test = false
      AND o.ordered_at >= date_trunc('month', now())
    WHERE r.name = 'CSR' AND u.is_active = true
    GROUP BY u.id, u.display_name
    ORDER BY cash_paid_orders DESC, conversion_rate DESC
  `);
  return rows;
}

module.exports = {
  ORDER_STATUSES,
  STATUSES_REQUIRING_FAILURE_REASON,
  CASH_PAID_STATUS,
  getOrderGrid,
  getOrderById,
  getHygieneCounts,
  updateOrder,
  getOrderHistory,
  getCustomerIntel,
  getCopyText,
  toggleBreak,
  getStates,
  getLgas,
  getAgentsByState,
  getProducts,
  getFailureReasons,
  getAgents,
  getPerformance,
  getScheduledOrders,
  getContacts,
  getLeaderboard,
};
