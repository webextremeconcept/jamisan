const { handlePabblyCount } = require('../services/reconciliationService');

async function handlePabblyReconcile(req, res) {
  try {
    const { date, count } = req.body;

    if (!date || count === undefined || count === null) {
      return res.status(200).json({ error: true, message: 'Missing required fields: date, count' });
    }

    // Validate date format YYYY-MM-DD
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      return res.status(200).json({ error: true, message: 'date must be in YYYY-MM-DD format' });
    }

    // Reject future dates and dates more than 7 days in the past
    const d = new Date(date);
    const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000);
    if (d > new Date() || d < sevenDaysAgo) {
      return res.status(200).json({ error: true, message: 'date must be within the last 7 days and not in the future' });
    }

    const parsedCount = parseInt(count, 10);
    if (isNaN(parsedCount) || parsedCount < 0) {
      return res.status(200).json({ error: true, message: 'count must be a non-negative integer' });
    }

    await handlePabblyCount(date, parsedCount);
    return res.status(200).json({ received: true });
  } catch (err) {
    console.error('[Reconcile] Unhandled error:', err.message, err.stack);
    return res.status(200).json({ error: true, message: 'Processing error' });
  }
}

module.exports = { handlePabblyReconcile };
