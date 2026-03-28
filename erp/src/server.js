require('dotenv').config();

const app = require('./app');
const { testConnection } = require('./config/db');

const PORT = parseInt(process.env.PORT, 10) || 3000;

async function start() {
  try {
    await testConnection();
    app.listen(PORT, () => {
      console.log(`[Server] Jamisan ERP running on port ${PORT}`);
    });
  } catch (err) {
    console.error('[Server] Failed to start:', err.message);
    process.exit(1);
  }
}

start();
