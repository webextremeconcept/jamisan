const { pool } = require('../config/db');
const { parsePhoneNumber } = require('libphonenumber-js');
const { logAudit } = require('../utils/auditLogger');

const CACHE_TTL_MS = 60 * 60 * 1000;

let orderSourcesCache = null;
let orderSourcesCacheTime = 0;
let otherSourceId = null;

async function getOrderSources() {
  if (!orderSourcesCache || Date.now() - orderSourcesCacheTime > CACHE_TTL_MS) {
    const res = await pool.query('SELECT id, name FROM order_sources WHERE is_active = true');
    orderSourcesCache = res.rows;
    orderSourcesCacheTime = Date.now();
    const other = orderSourcesCache.find((s) => s.name.toLowerCase() === 'other');
    otherSourceId = other ? other.id : null;
  }
  return orderSourcesCache;
}

let miscProductCache = null;
let miscProductCacheTime = 0;

async function getMiscProduct() {
  if (!miscProductCache || Date.now() - miscProductCacheTime > CACHE_TTL_MS) {
    const res = await pool.query(
      `SELECT p.id, p.department_id, p.brand_id, b.niche_id
         FROM products p
         JOIN brands b ON b.id = p.brand_id
        WHERE p.name = 'Miscellaneous'
          AND p.is_active = true
          AND b.is_active = true
        LIMIT 1`
    );
    if (res.rows.length === 0) {
      throw new Error('Miscellaneous fallback product not found or inactive — run Migration 006');
    }
    miscProductCache = res.rows[0];
    miscProductCacheTime = Date.now();
  }
  return miscProductCache;
}

function normalisePhone(raw) {
  try {
    const parsed = parsePhoneNumber(String(raw), 'NG');
    if (parsed.isValid()) return parsed.number; // E.164: +234XXXXXXXXXX
  } catch {
    // fall through
  }
  console.warn(`[Webhook] Could not normalise phone "${raw}" — storing raw`);
  return String(raw);
}

async function logValidationFailure(details, ipAddress) {
  await logAudit(null, 'webhook_validation_failed', {
    tableName: 'orders',
    newValue: JSON.stringify(details),
    ipAddress,
  });
}

async function ingestOrder(payload, ipAddress) {
  const required = ['api_batch_id', 'customer_name', 'phone_number', 'assigned_csr_id', 'price'];
  for (const field of required) {
    const val = payload[field];
    if (val === undefined || val === null || val === '') {
      await logValidationFailure({ missing_field: field, api_batch_id: payload.api_batch_id || null }, ipAddress);
      return { error: true, message: `Missing required field: ${field}` };
    }
  }

  // Sanitize inputs before DB use — strip currency symbols/commas from price,
  // trim whitespace from string fields that feed into ILIKE lookups or stored values.
  const cleanPrice = parseFloat(String(payload.price).replace(/[^0-9.]/g, ''));
  const customerName = String(payload.customer_name).trim();
  const productName = payload.product_name ? String(payload.product_name).trim() : null;
  const stateName = payload.state ? String(payload.state).trim() : null;
  const lgaName = payload.lga ? String(payload.lga).trim() : null;
  const address = payload.address ? String(payload.address).trim() : null;

  if (!isFinite(cleanPrice) || cleanPrice < 0) {
    await logValidationFailure({ invalid_field: 'price', value: String(payload.price), api_batch_id: payload.api_batch_id }, ipAddress);
    return { error: true, message: 'price must be a non-negative number' };
  }

  const csrId = parseInt(payload.assigned_csr_id, 10);
  if (!isFinite(csrId)) {
    await logValidationFailure({ invalid_field: 'assigned_csr_id', api_batch_id: payload.api_batch_id }, ipAddress);
    return { error: true, message: 'Invalid assigned_csr_id' };
  }
  const csrCheck = await pool.query(
    'SELECT id FROM users WHERE id = $1 AND is_active = true',
    [csrId]
  );
  if (csrCheck.rows.length === 0) {
    await logValidationFailure({ invalid_field: 'assigned_csr_id', value: csrId, api_batch_id: payload.api_batch_id }, ipAddress);
    return { error: true, message: 'Invalid assigned_csr_id' };
  }

  // Idempotency check
  const dupCheck = await pool.query(
    'SELECT id FROM orders WHERE api_batch_id = $1',
    [payload.api_batch_id]
  );
  if (dupCheck.rows.length > 0) {
    await logAudit(null, 'webhook_duplicate_skipped', {
      tableName: 'orders',
      newValue: JSON.stringify({ api_batch_id: payload.api_batch_id }),
      ipAddress,
    });
    return { skipped: true };
  }

  // Product lookup — inherit department_id, brand_id, niche_id
  let productRow = null;
  let unknownProduct = false;

  if (productName) {
    const productRes = await pool.query(
      `SELECT p.id, p.department_id, p.brand_id, b.niche_id
         FROM products p
         JOIN brands b ON b.id = p.brand_id
        WHERE p.name ILIKE $1
        LIMIT 1`,
      [productName]
    );
    if (productRes.rows.length > 0) {
      productRow = productRes.rows[0];
    }
  }

  if (!productRow) {
    productRow = await getMiscProduct();
    unknownProduct = true;
  }

  // Geo lookups (soft fail)
  let stateId = null;
  if (stateName) {
    const stateRes = await pool.query(
      'SELECT id FROM admin_level_1 WHERE name ILIKE $1 LIMIT 1',
      [stateName]
    );
    if (stateRes.rows.length > 0) {
      stateId = stateRes.rows[0].id;
    } else {
      console.warn(`[Webhook] Unknown state: "${stateName}"`);
    }
  }

  let lgaId = null;
  if (lgaName && stateId) {
    const lgaRes = await pool.query(
      'SELECT id FROM admin_level_2 WHERE name ILIKE $1 AND admin_level_1_id = $2 LIMIT 1',
      [lgaName, stateId]
    );
    if (lgaRes.rows.length > 0) {
      lgaId = lgaRes.rows[0].id;
    }
  }

  // Source lookup (soft fail to 'Other')
  const sources = await getOrderSources();
  let sourceId = otherSourceId;
  let unknownSource = false;

  if (payload.order_source) {
    const match = sources.find(
      (s) => s.name.toLowerCase() === payload.order_source.toLowerCase()
    );
    if (match) {
      sourceId = match.id;
    } else {
      unknownSource = true;
    }
  }

  const phone = normalisePhone(payload.phone_number);
  const otherPhone = payload.other_phone ? normalisePhone(payload.other_phone) : null;

  const hasOrderBump = payload.has_order_bump === true || payload.has_order_bump === 'true';
  if (hasOrderBump && !payload.order_bump_product_id) {
    await logAudit(null, 'webhook_order_bump_data_incomplete', {
      tableName: 'orders',
      newValue: JSON.stringify({ api_batch_id: payload.api_batch_id }),
      ipAddress,
    });
  }

  // Pre-transaction ban check (customer UPSERT happens inside the transaction)
  const preTxCustomer = await pool.query(
    'SELECT id, is_banned FROM customers WHERE phone_number = $1',
    [phone]
  );
  const existingCustomer = preTxCustomer.rows[0] || null;
  const isReturnCustomer = !!existingCustomer;
  const isBanned = existingCustomer ? existingCustomer.is_banned : false;
  const orderStatus = isBanned ? 'Banned' : 'Interested';

  // Transaction: UPSERT customer FIRST, then INSERT order with the resolved customer_id
  const client = await pool.connect();
  let orderRowId;
  let orderId;
  let resolvedCustomerId;

  try {
    await client.query('BEGIN');

    const seqRes = await client.query("SELECT nextval('cjam_order_seq') AS n");
    orderId = `CJAM${seqRes.rows[0].n}`;

    const upsertRes = await client.query(
      `INSERT INTO customers (phone_number, full_name, first_order_date, last_order_date, total_orders)
       VALUES ($1, $2, now(), now(), 1)
       ON CONFLICT (phone_number) DO UPDATE
         SET last_order_date = now(),
             total_orders    = customers.total_orders + 1,
             updated_at      = now()
       RETURNING id`,
      [phone, customerName]
    );
    resolvedCustomerId = upsertRes.rows[0].id;

    const insertRes = await client.query(
      `INSERT INTO orders (
        order_id, ordered_at, status,
        product_id, department_id, brand_id, niche_id,
        admin_level_1_id, admin_level_2_id,
        source_id, phone_number, other_phone,
        customer_id, is_return_customer, assigned_csr_id,
        customer_name, price, quantity,
        email, sex, city, full_address,
        has_order_bump,
        order_bump_product_id, order_bump_variant_id,
        order_bump_quantity, order_bump_price, order_bump_type,
        product_variant_id, api_batch_id
      ) VALUES (
        $1,  now(), $2,
        $3,  $4,    $5,  $6,
        $7,  $8,
        $9,  $10,   $11,
        $12, $13,   $14,
        $15, $16,   $17,
        $18, $19,   $20, $21,
        $22,
        $23, $24,
        $25, $26,   $27,
        $28, $29
      ) RETURNING id`,
      [
        orderId, orderStatus,
        productRow.id, productRow.department_id, productRow.brand_id, productRow.niche_id,
        stateId, lgaId,
        sourceId, phone, otherPhone,
        resolvedCustomerId, isReturnCustomer, csrId,
        customerName, cleanPrice, payload.quantity || 1,
        payload.email || null, payload.sex || null, payload.city || null, address,
        hasOrderBump,
        payload.order_bump_product_id || null, payload.order_bump_variant_id || null,
        payload.order_bump_quantity || 0, payload.order_bump_price || 0, payload.order_bump_type || null,
        payload.product_variant_id || null, payload.api_batch_id,
      ]
    );
    orderRowId = insertRes.rows[0].id;

    await client.query('COMMIT');
  } catch (err) {
    await client.query('ROLLBACK');
    // Concurrent duplicate — both requests passed the SELECT idempotency check,
    // but the UNIQUE constraint on api_batch_id blocks the second INSERT.
    if (err.code === '23505' && err.constraint === 'unique_api_batch_id') {
      await logAudit(null, 'webhook_duplicate_skipped', {
        tableName: 'orders',
        newValue: JSON.stringify({ api_batch_id: payload.api_batch_id }),
        ipAddress,
      });
      return { skipped: true };
    }
    throw err;
  } finally {
    client.release();
  }

  // Post-commit audit entries
  if (unknownSource) {
    await logAudit(null, 'unknown_source_mapped', {
      tableName: 'orders',
      recordId: orderRowId,
      newValue: JSON.stringify({ order_source: payload.order_source }),
      ipAddress,
    });
  }

  if (unknownProduct) {
    await logAudit(null, 'unknown_product_mapped', {
      tableName: 'orders',
      recordId: orderRowId,
      newValue: JSON.stringify({ product_name: payload.product_name || null }),
      ipAddress,
    });
  }

  if (isBanned) {
    await logAudit(null, 'banned_customer_blocked', {
      tableName: 'orders',
      recordId: orderRowId,
      newValue: JSON.stringify({ order_id: orderId, customer_id: resolvedCustomerId }),
      ipAddress,
    });
  }

  await logAudit(null, 'order_created', {
    tableName: 'orders',
    recordId: orderRowId,
    newValue: JSON.stringify({ order_id: orderId, status: orderStatus, is_return_customer: isReturnCustomer }),
    ipAddress,
  });

  return {
    order_id: orderId,
    status: orderStatus,
    is_return_customer: isReturnCustomer,
    customer_id: resolvedCustomerId,
  };
}

module.exports = { ingestOrder };
