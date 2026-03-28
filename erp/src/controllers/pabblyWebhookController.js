const { ingestOrder } = require('../services/orderIngestionService');
const { logAudit } = require('../utils/auditLogger');

async function handlePabblyWebhook(req, res) {
  // Always respond 200 on any processing error — Pabbly must not retry on our failures.
  // The only non-200 path is webhookAuthMiddleware returning 401.
  try {
    const ipAddress = req.ip || null;
    const result = await ingestOrder(req.body, ipAddress);
    return res.status(200).json(result);
  } catch (err) {
    console.error('[Webhook] Unhandled error in order ingestion:', err.message, err.stack);
    await logAudit(null, 'webhook_processing_error', {
      tableName: 'orders',
      newValue: JSON.stringify({
        error: err.message,
        api_batch_id: req.body?.api_batch_id || null,
      }),
      ipAddress: req.ip || null,
    });
    return res.status(200).json({ error: true, message: 'Processing error — order not created' });
  }
}

module.exports = { handlePabblyWebhook };
