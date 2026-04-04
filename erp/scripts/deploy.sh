#!/bin/bash
echo "=== Jamisan ERP Deploy ==="

echo "1. Syntax check..."
cd /opt/jamisan-erp
node --check src/server.js || { echo "❌ Syntax error — aborting deploy"; exit 1; }

echo "2. Restarting PM2..."
pm2 restart ecosystem.config.js

echo "3. Checking status..."
pm2 status

echo "4. Checking logs for errors..."
sleep 3
pm2 logs jamisan-erp --lines 15 --nostream

echo "=== Deploy complete ==="
