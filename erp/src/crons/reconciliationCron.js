const cron = require('node-cron');
const { runMidnightReconciliation } = require('../services/reconciliationService');

// 23:00 UTC = 00:00 WAT (UTC+1, no DST)
function startReconciliationCron() {
  cron.schedule('0 23 * * *', async () => {
    console.log('[Cron] Midnight reconciliation started');
    try {
      await runMidnightReconciliation();
    } catch (err) {
      console.error('[Cron] Reconciliation failed:', err.message, err.stack);
    }
  });
  console.log('[Cron] Reconciliation cron scheduled (23:00 UTC daily)');
}

module.exports = { startReconciliationCron };
