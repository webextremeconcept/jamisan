const { pool } = require('../config/db');
const { sendReconciliationAlertEmail } = require('./emailService');

// WAT = UTC+1, no DST
const WAT_OFFSET_MS = 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

function getYesterdayWATBounds() {
  const now = new Date();
  const nowWAT = new Date(now.getTime() + WAT_OFFSET_MS);

  const todayWATMidnightUTC = new Date(Date.UTC(
    nowWAT.getUTCFullYear(),
    nowWAT.getUTCMonth(),
    nowWAT.getUTCDate()
  ));

  const todayStartUTC = new Date(todayWATMidnightUTC.getTime() - WAT_OFFSET_MS);
  const yesterdayStartUTC = new Date(todayStartUTC.getTime() - DAY_MS);
  const yesterdayWATMidnightUTC = new Date(todayWATMidnightUTC.getTime() - DAY_MS);
  const reconciliationDate = yesterdayWATMidnightUTC.toISOString().slice(0, 10);

  return { yesterdayStartUTC, todayStartUTC, reconciliationDate };
}

async function maybeSendAlert(date, crmCount, pabblyCount, discrepancy, currentAlertSent) {
  if (Math.abs(discrepancy) > 2 && !currentAlertSent) {
    await sendReconciliationAlertEmail(date, crmCount, pabblyCount, discrepancy);
    await pool.query(
      'UPDATE pabbly_reconciliation_log SET alert_sent = true WHERE reconciliation_date = $1',
      [date]
    );
  }
}

async function logReconciliationResult(row, date, pendingMessage) {
  if (row.status !== 'Pending') {
    await maybeSendAlert(date, row.crm_order_count, row.pabbly_order_count, row.discrepancy, row.alert_sent);
    console.log(`[Reconciliation] ${date} — CRM: ${row.crm_order_count}, Pabbly: ${row.pabbly_order_count}, Status: ${row.status}`);
  } else {
    console.log(`[Reconciliation] ${date} — ${pendingMessage}`);
  }
}

// Atomic upsert via ON CONFLICT — the unique index on reconciliation_date
// serialises concurrent writes. NULL pabbly_order_count/discrepancy on INSERT
// means "genuinely unknown", not a misleading 0.
async function runMidnightReconciliation() {
  const { yesterdayStartUTC, todayStartUTC, reconciliationDate } = getYesterdayWATBounds();

  const countRes = await pool.query(
    `SELECT COUNT(*)::int AS crm_order_count
       FROM orders
      WHERE ordered_at >= $1
        AND ordered_at  < $2
        AND api_batch_id IS NOT NULL`,
    [yesterdayStartUTC, todayStartUTC]
  );
  const crmCount = countRes.rows[0].crm_order_count;

  const result = await pool.query(
    `INSERT INTO pabbly_reconciliation_log
       (reconciliation_date, crm_order_count, pabbly_order_count, discrepancy, status)
     VALUES ($1, $2, NULL, NULL, 'Pending')
     ON CONFLICT (reconciliation_date) DO UPDATE
       SET crm_order_count = EXCLUDED.crm_order_count,
           discrepancy = CASE
             WHEN pabbly_reconciliation_log.pabbly_order_count IS NOT NULL
             THEN EXCLUDED.crm_order_count - pabbly_reconciliation_log.pabbly_order_count
             ELSE NULL
           END,
           status = CASE
             WHEN pabbly_reconciliation_log.pabbly_order_count IS NOT NULL
             THEN CASE
               WHEN EXCLUDED.crm_order_count - pabbly_reconciliation_log.pabbly_order_count = 0
               THEN 'Matched' ELSE 'Discrepancy Found'
             END
             ELSE 'Pending'
           END
     RETURNING reconciliation_date, crm_order_count, pabbly_order_count,
               discrepancy, status, alert_sent`,
    [reconciliationDate, crmCount]
  );

  await logReconciliationResult(result.rows[0], reconciliationDate, `CRM: ${crmCount} written. Awaiting Pabbly count.`);
}

// Mirror of runMidnightReconciliation — writes pabbly_order_count and
// calculates discrepancy only when crm_order_count IS NOT NULL.
async function handlePabblyCount(date, pabblyCount) {
  const result = await pool.query(
    `INSERT INTO pabbly_reconciliation_log
       (reconciliation_date, crm_order_count, pabbly_order_count, discrepancy, status)
     VALUES ($1, NULL, $2, NULL, 'Pending')
     ON CONFLICT (reconciliation_date) DO UPDATE
       SET pabbly_order_count = EXCLUDED.pabbly_order_count,
           discrepancy = CASE
             WHEN pabbly_reconciliation_log.crm_order_count IS NOT NULL
             THEN pabbly_reconciliation_log.crm_order_count - EXCLUDED.pabbly_order_count
             ELSE NULL
           END,
           status = CASE
             WHEN pabbly_reconciliation_log.crm_order_count IS NOT NULL
             THEN CASE
               WHEN pabbly_reconciliation_log.crm_order_count - EXCLUDED.pabbly_order_count = 0
               THEN 'Matched' ELSE 'Discrepancy Found'
             END
             ELSE 'Pending'
           END
     RETURNING reconciliation_date, crm_order_count, pabbly_order_count,
               discrepancy, status, alert_sent`,
    [date, pabblyCount]
  );

  await logReconciliationResult(result.rows[0], date, `Pabbly: ${pabblyCount} written. Awaiting midnight CRM count.`);
}

module.exports = { runMidnightReconciliation, handlePabblyCount };
