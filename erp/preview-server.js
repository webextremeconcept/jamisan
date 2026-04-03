/**
 * preview-server.js — local preview only, skips DB connection check.
 * Not committed. Real server is src/server.js.
 */
require('dotenv').config({ path: __dirname + '/.env' });

const app  = require('./src/app');
const PORT = parseInt(process.env.PORT, 10) || 3000;

app.listen(PORT, () => {
  console.log('[Preview] Jamisan ERP running on http://localhost:' + PORT);
});
