module.exports = {
  apps: [{
    name: 'jamisan-erp',
    script: '/opt/jamisan-erp/src/server.js',
    cwd: '/opt/jamisan-erp',
    instances: 1,
    watch: false,
    max_memory_restart: '500M',
    env: {
      NODE_ENV: 'production'
    },
    error_file: '/root/.pm2/logs/jamisan-erp-error.log',
    out_file: '/root/.pm2/logs/jamisan-erp-out.log',
    log_date_format: 'YYYY-MM-DD HH:mm:ss'
  }]
};
