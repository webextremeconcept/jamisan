'use strict';
/**
 * CSR Controller — all handler functions for /api/csr/* routes.
 * Handlers call csrService, then render EJS or return JSON.
 */
const svc = require('../services/csrService');

/** Minimal HTML escape for values built into res.send() strings. */
function esc(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/* ══ Dashboard ══ */

async function getDashboard(req, res, next) {
  try {
    const { id: userId, role_name: roleName } = req.user;
    let rows = [], total = 0, page = 1, limit = 150, counts = {};
    try {
      ({ rows, total, page, limit } = await svc.getOrderGrid({ userId, roleName }));
      counts = await svc.getHygieneCounts(userId, roleName);
    } catch { /* DB unavailable — render empty state */ }
    res.render('partials/dashboard', { rows, total, page, limit, hygiene: 'all', counts });
  } catch (err) { next(err); }
}

/* ══ Orders grid (paginated — HTMX partial swap) ══ */

async function getOrders(req, res, next) {
  try {
    const { id: userId, role_name: roleName } = req.user;
    const hygiene = req.query.hygiene || 'all';
    const page    = Math.max(1, parseInt(req.query.page)  || 1);
    const limit   = Math.min(Math.max(1, parseInt(req.query.limit) || 150), 1000);

    // Build queryString: all active filters except 'page' and 'limit', for pagination links
    const allowedFilters = ['hygiene', 'search', 'color'];
    const qs = allowedFilters
      .filter(k => req.query[k] && req.query[k] !== '')
      .map(k => '&' + encodeURIComponent(k) + '=' + encodeURIComponent(req.query[k]))
      .join('');

    let rows = [], total = 0;
    try {
      ({ rows, total } = await svc.getOrderGrid({ userId, roleName, hygiene, page, limit }));
    } catch { /* DB unavailable — render empty state */ }
    res.render('partials/order-grid', { rows, total, page, limit, hygiene, queryString: qs });
  } catch (err) { next(err); }
}

/* ══ Slide-out panel (Phase 4 stub) ══ */

async function getOrderPanel(req, res, next) {
  try {
    const { id: userId, role_name: roleName } = req.user;
    const id = parseInt(req.params.id);
    if (isNaN(id)) return res.status(400).json({ message: 'Invalid order id' });
    const order = await svc.getOrderById(id, userId, roleName);
    if (!order) return res.status(404).json({ message: 'Order not found' });
    res.render('partials/slide-out-panel', { order });
  } catch (err) { next(err); }
}

/* ══ Inline order update — returns updated row for HTMX outerHTML swap ══ */

async function updateOrderCtrl(req, res, next) {
  const { id: userId, role_name: roleName } = req.user;
  const id = parseInt(req.params.id);
  if (isNaN(id)) return res.status(400).json({ message: 'Invalid order id' });

  try {
    const order = await svc.updateOrder({
      id,
      fields: req.body,
      userId,
      roleName,
      ipAddress: req.ip,
    });
    if (!order) return res.status(404).json({ message: 'Order not found' });
    res.render('partials/order-row', { o: order });
  } catch (err) {
    // HTMX does not swap HTML on error status codes — always return 200
    // so the row un-dims (htmx-request class gets removed)
    const message = err.message || 'Update failed';
    res.set('HX-Trigger', JSON.stringify({ showToast: { message, type: 'error' } }));
    try {
      // Re-render the ORIGINAL (unchanged) row so the grid stays consistent
      const original = await svc.getOrderById(id, userId, roleName);
      return res.status(200).render('partials/order-row', { o: original });
    } catch (fetchErr) {
      // Fallback: never vaporise the row — return a visible error row
      return res.status(200).send(
        '<tr class="bg-red-50"><td colspan="100%" style="padding:16px;color:#DC2626;text-align:center;">Data sync error. Please refresh the page.</td></tr>'
      );
    }
  }
}

/* ══ Order status history (Phase 4 stub) ══ */

async function getOrderHistory(req, res, next) {
  try {
    const orderId = parseInt(req.params.id);
    if (isNaN(orderId)) return res.status(400).json({ message: 'Invalid order id' });
    const rows = await svc.getOrderHistory(orderId);
    const items = rows.map(r =>
      `<div style="padding:8px 0;border-bottom:1px solid #F3F4F6;font-size:0.8rem;">
         <span style="color:#9CA3AF;">${esc(new Date(r.changed_at).toLocaleString())}</span>
         <span style="color:#111827;margin:0 8px;font-weight:600;">
           ${esc(r.previous_status)} → ${esc(r.new_status)}
         </span>
         <span style="color:#6B7280;">${esc(r.changed_by_name ?? 'System')}</span>
       </div>`
    ).join('');
    res.send(items || '<div style="padding:16px;color:#9CA3AF;font-size:0.8rem;">No history yet.</div>');
  } catch (err) { next(err); }
}

/* ══ Customer intelligence (Phase 4 stub) ══ */

async function getCustomerIntel(req, res, next) {
  try {
    const { id: userId, role_name: roleName } = req.user;
    const id = parseInt(req.params.id);
    if (isNaN(id)) return res.status(400).json({ message: 'Invalid order id' });
    const order = await svc.getOrderById(id, userId, roleName);
    if (!order) return res.status(404).json({ message: 'Order not found' });
    const { customer, orders } = await svc.getCustomerIntel(order.customer_id, id);
    res.render('partials/customer-intel', { customer, orders, currentOrderId: id });
  } catch (err) { next(err); }
}

/* ══ WhatsApp copy text ══ */

async function getCopyText(req, res, next) {
  try {
    const { id: userId, role_name: roleName } = req.user;
    const id = parseInt(req.params.id);
    if (isNaN(id)) return res.status(400).json({ message: 'Invalid order id' });
    const text = await svc.getCopyText(id, userId, roleName);
    if (!text) return res.status(404).json({ message: 'Order not found' });
    res.json({ text });
  } catch (err) { next(err); }
}

/* ══ Hygiene counts — returns rendered alert-pills HTML for HTMX swap ══ */

async function getHygieneCounts(req, res, next) {
  try {
    const { id: userId, role_name: roleName } = req.user;
    let counts = {};
    try { counts = await svc.getHygieneCounts(userId, roleName); } catch { /* DB unavailable */ }
    res.render('partials/alert-pills', { counts });
  } catch (err) { next(err); }
}

/* ══ Secondary tab stubs (Phase 6) ══ */

async function getScheduled(req, res, next) {
  try {
    const { id: userId, role_name: roleName } = req.user;
    const rows = await svc.getScheduledOrders(userId, roleName);
    res.render('partials/tab-scheduled', { rows });
  } catch (err) { next(err); }
}

async function getAgents(req, res, next) {
  try {
    const { search, agent_state_filter: stateId } = req.query;
    const rows = await svc.getAgents({ search, stateId: stateId ? parseInt(stateId) : null });
    let states = [];
    try { states = await svc.getStates(); } catch { /* DB unavailable */ }
    res.render('partials/tab-agents', { rows, states });
  } catch (err) { next(err); }
}

async function getContacts(req, res, next) {
  try {
    const rows = await svc.getContacts();
    res.render('partials/tab-contacts', { rows });
  } catch (err) { next(err); }
}

async function getPerformance(req, res, next) {
  try {
    const { id: userId } = req.user;
    const { live, history } = await svc.getPerformance(userId);
    const leaderboard = await svc.getLeaderboard();
    res.render('partials/tab-performance', { live, history, leaderboard, userId });
  } catch (err) { next(err); }
}

/* ══ On break toggle ══ */

async function toggleBreak(req, res, next) {
  try {
    const isOnBreak = await svc.toggleBreak(req.user.id, req.ip);
    res.json({ isOnBreak });
  } catch (err) { next(err); }
}

/* ══ Lookups ══ */

async function getStates(req, res, next) {
  try {
    res.json(await svc.getStates());
  } catch (err) { next(err); }
}

async function getLgas(req, res, next) {
  try {
    const stateId = parseInt(req.query.admin_level_1_id);
    if (isNaN(stateId)) return res.send('');
    const rows = await svc.getLgas(stateId);
    res.send(rows.map(r => `<option value="${esc(String(r.id))}">${esc(r.name)}</option>`).join('\n'));
  } catch (err) { next(err); }
}

async function getAgentsByState(req, res, next) {
  try {
    const stateId = parseInt(req.query.admin_level_1_id);
    const rows = await svc.getAgentsByState(isNaN(stateId) ? null : stateId);
    res.send(rows.map(r => `<option value="${esc(String(r.id))}">${esc(r.name)}</option>`).join('\n'));
  } catch (err) { next(err); }
}

async function getProducts(req, res, next) {
  try {
    res.json(await svc.getProducts());
  } catch (err) { next(err); }
}

async function getFailureReasons(req, res, next) {
  try {
    res.json(await svc.getFailureReasons(req.query.status || null));
  } catch (err) { next(err); }
}

async function getFailureReasonsOptions(req, res, next) {
  try {
    const rows = await svc.getFailureReasons(req.query.status || null);
    res.send(rows.map(r => `<option value="${esc(String(r.id))}">${esc(r.description)}</option>`).join('\n'));
  } catch (err) { next(err); }
}

module.exports = {
  getDashboard,
  getOrders,
  getOrderPanel,
  updateOrderCtrl,
  getOrderHistory,
  getCustomerIntel,
  getCopyText,
  getHygieneCounts,
  getScheduled,
  getAgents,
  getContacts,
  getPerformance,
  toggleBreak,
  getStates,
  getLgas,
  getAgentsByState,
  getProducts,
  getFailureReasons,
  getFailureReasonsOptions,
};
