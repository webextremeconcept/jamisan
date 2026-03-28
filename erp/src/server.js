require('dotenv').config();

const app = require('./app');
const { testConnection } = require('./config/db');
const { startReconciliationCron } = require('./crons/reconciliationCron');

const PORT = parseInt(process.env.PORT, 10) || 3000;

// Fail fast on missing secrets — catch misconfigurations before any request is served.
if (!process.env.PABBLY_WEBHOOK_SECRET) {
  throw new Error('[Startup] PABBLY_WEBHOOK_SECRET is not set');
}

async function start() {
  try {
    await testConnection();
    app.listen(PORT, () => {
      console.log(`[Server] Jamisan ERP running on port ${PORT}`);
      startReconciliationCron();
    });
  } catch (err) {
    console.error('[Server] Failed to start:', err.message);
    process.exit(1);
  }
}

start();
