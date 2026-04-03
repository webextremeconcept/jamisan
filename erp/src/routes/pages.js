/**
 * Page routes — serve full HTML pages.
 * These are NOT behind authMiddleware because the auth guard
 * runs client-side in public/js/app.js (localStorage check).
 * The server-rendered shell passes user data from the JWT
 * only when a valid token is decoded; otherwise it passes empty user.
 */
const express = require('express');
const router = express.Router();
const { verifyAccessToken } = require('../services/tokenService');
const { pool } = require('../config/db');

/** Extract user from Authorization header, non-throwing */
async function tryGetUser(req) {
  try {
    const auth = req.headers.authorization || '';
    if (!auth.startsWith('Bearer ')) return null;
    const payload = verifyAccessToken(auth.slice(7));
    const { rows } = await pool.query(
      `SELECT u.id, u.display_name, u.full_name, u.is_on_break, u.csr_level,
              r.name AS role_name
       FROM users u
       JOIN roles r ON r.id = u.role_id
       WHERE u.id = $1 AND u.is_active = true`,
      [payload.user_id]
    );
    return rows[0] || null;
  } catch {
    return null;
  }
}

/** GET / — redirect to dashboard or login */
router.get('/', (req, res) => {
  res.redirect('/dashboard');
});

/** GET /login — login page */
router.get('/login', (req, res) => {
  res.render('pages/login');
});

/** GET /dashboard — main app shell */
router.get('/dashboard', async (req, res) => {
  // Try to read actual user from DB (token is in Authorization header on HTMX loads,
  // but may be absent on hard refresh since it lives in localStorage not cookies)
  const dbUser = await tryGetUser(req);
  const user = dbUser || { display_name: '', role_name: 'CSR', is_on_break: false };

  res.render('layouts/shell', {
    body: '',     // body will be filled by HTMX on first load
    user,
    title: 'Workspace',
    activePage: 'workspace',
  });
});

/** GET /preview/panel — slide-out panel with hardcoded data (no DB required) */
router.get('/preview/panel', (req, res) => {
  res.locals.previewMode = true;
  const order = {
    id: 1, order_id: 'FJAMG1271', status: 'Interested',
    customer_name: 'Faith Ajogbor', phone_number: '+2349010641483', other_phone: null,
    row_num: 10000,
    email: 'faitheee@yahoo.com', sex: 'Female', comments: 'Sent to Agent',
    product_id: 1, product_name: 'Temique Stretchmarks Gel', product_variant_id: 1, colour: 'Red',
    price: 19500, quantity: 1, has_order_bump: false,
    order_bump_product_id: null, order_bump_quantity: 0, order_bump_price: 0,
    admin_level_1_id: 16, state_name: 'Imo', admin_level_2_id: 101, lga_name: 'Oru East',
    city: 'Owerri', full_address: '12 Ugbaja Street',
    agent_id: 5, agent_name: 'Parcel Exchange', agent_phone: '+2348012345678', agent_wa_link: 'https://chat.whatsapp.com/example',
    logistics_fee: 1500, date_paid: null,
    ordered_at: '2026-03-25', first_contact_at: null, assigned_weekday: 'Wednesday',
    csr_name: 'Ayomide', assigned_csr_id: 2,
    customer_id: 1, is_banned: false, total_purchases: 4, customer_total_orders: 5,
    lifetime_value: 118900, customer_tag: 'Verified Buyer', csr_notes: null, first_order_date: '2025-11-10',
    failure_reason_id: null,
    updated_at: '2026-03-26T14:22:00Z',
    api_batch_id: 'pabbly_batch_20260325_143822_abc',
  };
  const panelHtml = require('ejs').render(
    require('fs').readFileSync(require('path').join(__dirname, '../views/partials/slide-out-panel.ejs'), 'utf8'),
    { order }
  );
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Panel Preview</title>
  <link rel="stylesheet" href="/css/app.css">
  <script defer src="https://cdn.jsdelivr.net/npm/alpinejs@3.x.x/dist/cdn.min.js"></script>
  <script>
    document.addEventListener('alpine:init', () => {
      Alpine.store('ui', {
        panelRightCollapsed: false,
        hasUnsavedChanges: false,
        panelOpen: true,
        closePanel() { this.panelOpen = false; this.hasUnsavedChanges = false; }
      });
      Alpine.effect(() => {
        const collapsed = Alpine.store('ui').panelRightCollapsed;
        const el = document.querySelector('.pp-intel');
        if (el) el.classList.toggle('pp-intel-collapsed', collapsed);
        const chevron = document.querySelector('.pp-chevron-svg');
        if (chevron) chevron.classList.toggle('pp-chevron-rotated', collapsed);
      });
    });
  </script>
</head>
<body style="margin:0;background:#F3F4F6;" x-data>
  <!-- Simulated grid background behind overlay -->
  <div style="padding:20px;font-family:Inter,system-ui,sans-serif;">
    <div style="background:#fff;border-radius:8px;padding:16px;box-shadow:0 1px 3px rgba(0,0,0,0.1);">
      <div style="font-size:0.8rem;color:#9CA3AF;border-bottom:1px solid #E5E7EB;padding-bottom:8px;margin-bottom:8px;">Order Grid (simulated background)</div>
      <div style="font-size:0.75rem;color:#D1D5DB;">10000 &nbsp; FJAMG1271 &nbsp; Ohambele &nbsp; 25/03/26 &nbsp; FAITH AJOGBOR &nbsp; Temique Stretchmarks &nbsp; Red &nbsp; N19,500</div>
      <div style="font-size:0.75rem;color:#D1D5DB;margin-top:4px;">9999 &nbsp; FJAME1778 &nbsp; Ayomide &nbsp; 25/03/26 &nbsp; Isah Musa &nbsp; Temique Stretchmarks &nbsp; Blue &nbsp; N19,500</div>
      <div style="font-size:0.75rem;color:#D1D5DB;margin-top:4px;">9998 &nbsp; FJAME1777 &nbsp; Doyin &nbsp; 25/03/26 &nbsp; Awo Stella Ezinne &nbsp; DarkSpot Serum &nbsp; Green &nbsp; N19,500</div>
    </div>
  </div>
  <!-- Semi-transparent overlay -->
  <div style="position:fixed;inset:0;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;padding:24px;">
    <div style="width:90vw;max-width:1200px;height:90vh;background:#fff;border-radius:12px;box-shadow:0 25px 60px rgba(0,0,0,0.3);display:flex;flex-direction:column;overflow:hidden;">
      ${panelHtml}
    </div>
  </div>
</body>
</html>`;
  res.send(html);
});

module.exports = router;
