/**
 * Module 2 Auth System — Integration Test Runner
 * Run on VPS: node test_auth.js
 *
 * Updated for security patch round (FIX 10 and new tests N1–N4).
 */
const http = require('http');
const { Pool } = require('pg');
const bcrypt = require('bcryptjs');
const speakeasy = require('speakeasy');

const BASE = 'http://localhost:3000';
const pool = new Pool({
  host: '127.0.0.1', port: 5432,
  database: 'jamisan_erp', user: 'jamisan_admin', password: 'jamisan_admin',
});

let CSR_ACCESS = '';
let CSR_REFRESH = '';
let DIR_TEMP = '';
let DIR_SECRET = '';   // populated from DB after setup (FIX 10)
let DIR_ACCESS = '';

let passed = 0;
let failed = 0;

function post(path, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const url = new URL(path, BASE);
    const opts = {
      hostname: url.hostname, port: url.port, path: url.pathname,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data), ...headers },
    };
    const req = http.request(opts, (res) => {
      let buf = '';
      res.on('data', (c) => (buf += c));
      res.on('end', () => {
        let json;
        try { json = JSON.parse(buf); } catch { json = buf; }
        resolve({ status: res.statusCode, body: json });
      });
    });
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

function patch(path, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const url = new URL(path, BASE);
    const opts = {
      hostname: url.hostname, port: url.port, path: url.pathname,
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data), ...headers },
    };
    const req = http.request(opts, (res) => {
      let buf = '';
      res.on('data', (c) => (buf += c));
      res.on('end', () => {
        let json;
        try { json = JSON.parse(buf); } catch { json = buf; }
        resolve({ status: res.statusCode, body: json });
      });
    });
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

function get(path, headers = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, BASE);
    const opts = {
      hostname: url.hostname, port: url.port, path: url.pathname,
      method: 'GET', headers,
    };
    const req = http.request(opts, (res) => {
      let buf = '';
      res.on('data', (c) => (buf += c));
      res.on('end', () => {
        let json;
        try { json = JSON.parse(buf); } catch { json = buf; }
        resolve({ status: res.statusCode, body: json });
      });
    });
    req.on('error', reject);
    req.end();
  });
}

async function dbQuery(sql, params = []) {
  const res = await pool.query(sql, params);
  return res.rows;
}

function log(test, status, detail) {
  const icon = status === 'PASS' ? '✅' : '❌';
  console.log(`\n${icon} Test ${test}: ${status}`);
  if (typeof detail === 'object') console.log(JSON.stringify(detail, null, 2));
  else if (detail) console.log(detail);
  if (status === 'PASS') passed++; else failed++;
}

async function run() {
  // Reset test users — including password hash so test 6's password change
  // does not carry over into subsequent runs.
  const csrPasswordHash = await bcrypt.hash('TestPass123!', 12);
  await dbQuery(
    `UPDATE users
     SET failed_login_attempts = 0, locked_until = NULL, token_version = 0,
         two_fa_enabled = false, two_fa_secret = NULL, pending_2fa_secret = NULL,
         is_active = true, password_hash = $1
     WHERE id = 100`,
    [csrPasswordHash]
  );
  await dbQuery(`
    UPDATE users
    SET failed_login_attempts = 0, locked_until = NULL, token_version = 0,
        two_fa_enabled = false, two_fa_secret = NULL, pending_2fa_secret = NULL,
        is_active = true
    WHERE id = 101
  `);
  await dbQuery("DELETE FROM session_log WHERE user_id IN (100, 101)");
  await dbQuery(`
    DELETE FROM audit_log
    WHERE user_id IN (100, 101)
       OR (user_id IS NULL AND action = 'login_failed')
       OR new_value = 'nonexistent_test_12345@nowhere.invalid'
  `);

  // ==================== TEST 2: Valid CSR login ====================
  {
    const r = await post('/auth/login', { email: 'testcsr@jamisan.com', password: 'TestPass123!' });
    const pass = r.status === 200 && r.body.access_token && r.body.refresh_token && r.body.user.role === 'CSR';
    CSR_ACCESS = r.body.access_token || '';
    CSR_REFRESH = r.body.refresh_token || '';
    log(2, pass ? 'PASS' : 'FAIL', { status: r.status, body: r.body });
  }

  // ==================== TEST 3: Wrong password 5x + lockout ====================
  {
    await dbQuery("UPDATE users SET failed_login_attempts = 0, locked_until = NULL WHERE id = 100");
    const results = [];
    for (let i = 1; i <= 5; i++) {
      const r = await post('/auth/login', { email: 'testcsr@jamisan.com', password: 'wrong' });
      results.push({ attempt: i, status: r.status, msg: r.body.message });
    }
    const r6 = await post('/auth/login', { email: 'testcsr@jamisan.com', password: 'wrong' });
    results.push({ attempt: 6, status: r6.status, msg: r6.body.message });

    const pass = results[4].status === 401 && r6.status === 423;
    log(3, pass ? 'PASS' : 'FAIL', results);
  }

  // ==================== TEST 4: Login while locked (correct password) ====================
  {
    const r = await post('/auth/login', { email: 'testcsr@jamisan.com', password: 'TestPass123!' });
    const pass = r.status === 423;
    log(4, pass ? 'PASS' : 'FAIL', { status: r.status, body: r.body });
  }

  // ==================== TEST 5: Refresh token rotation ====================
  {
    await dbQuery("UPDATE users SET failed_login_attempts = 0, locked_until = NULL WHERE id = 100");
    const login = await post('/auth/login', { email: 'testcsr@jamisan.com', password: 'TestPass123!' });
    CSR_ACCESS = login.body.access_token;
    CSR_REFRESH = login.body.refresh_token;

    const r = await post('/auth/refresh', { refresh_token: CSR_REFRESH });
    const pass = r.status === 200 && r.body.access_token && r.body.refresh_token;
    if (pass) {
      CSR_ACCESS = r.body.access_token;
      CSR_REFRESH = r.body.refresh_token;
    }
    log(5, pass ? 'PASS' : 'FAIL', { status: r.status, body: r.body });
  }

  // ==================== TEST 6: Password change invalidates old tokens ====================
  {
    const oldToken = CSR_ACCESS;
    const r = await patch('/auth/password',
      { current_password: 'TestPass123!', new_password: 'NewPass456!' },
      { Authorization: `Bearer ${CSR_ACCESS}` }
    );
    const pass1 = r.status === 200;

    const r3 = await post('/auth/logout', {}, { Authorization: `Bearer ${oldToken}` });
    const pass2 = r3.status === 401;

    const rows = await dbQuery("SELECT token_version FROM users WHERE id = 100");
    const pass3 = rows[0].token_version === 1;

    const pass = pass1 && pass2 && pass3;
    log(6, pass ? 'PASS' : 'FAIL', {
      password_change: { status: r.status, body: r.body },
      old_token_rejected: { status: r3.status, body: r3.body },
      token_version: rows[0].token_version,
    });
  }

  // ==================== TEST 7: Logout invalidates tokens ====================
  {
    const login = await post('/auth/login', { email: 'testcsr@jamisan.com', password: 'NewPass456!' });
    CSR_ACCESS = login.body.access_token;

    const r = await post('/auth/logout', {}, { Authorization: `Bearer ${CSR_ACCESS}` });
    const pass1 = r.status === 200;

    const r2 = await post('/auth/logout', {}, { Authorization: `Bearer ${CSR_ACCESS}` });
    const pass2 = r2.status === 401;

    const sessions = await dbQuery(
      "SELECT logged_out_at FROM session_log WHERE user_id = 100 ORDER BY id DESC LIMIT 1"
    );
    const pass3 = sessions.length > 0 && sessions[0].logged_out_at !== null;

    const pass = pass1 && pass2 && pass3;
    log(7, pass ? 'PASS' : 'FAIL', {
      logout: { status: r.status, body: r.body },
      post_logout_attempt: { status: r2.status, body: r2.body },
      session_logged_out_at: sessions[0]?.logged_out_at,
    });
  }

  // ==================== TEST 8: Forgot password — hard 403 ====================
  {
    const r = await post('/auth/forgot-password', { email: 'testcsr@jamisan.com' });
    const pass = r.status === 403 && r.body.message.includes('Operations Manager');
    log(8, pass ? 'PASS' : 'FAIL', { status: r.status, body: r.body });
  }

  // ==================== TEST 9: Director 2FA setup flow ====================
  // FIX 10: setup no longer returns raw secret — verify qr_code only, read secret from DB
  {
    const r = await post('/auth/login', { email: 'testdirector@jamisan.com', password: 'TestPass123!' });
    const pass1 = r.status === 200 && r.body.requires_2fa_setup === true && r.body.temp_token;
    DIR_TEMP = r.body.temp_token || '';

    let pass2 = false;
    let setupBody = {};
    if (DIR_TEMP) {
      const r2 = await post('/auth/2fa/setup', { temp_token: DIR_TEMP });
      // FIX 10: expect qr_code only — no raw secret in response
      pass2 = r2.status === 200 && r2.body.qr_code && !r2.body.secret;
      setupBody = r2.body;

      // Read server-side secret from DB for use in activation test
      const rows = await dbQuery("SELECT pending_2fa_secret FROM users WHERE id = 101");
      DIR_SECRET = rows[0]?.pending_2fa_secret || '';
    }

    const pass = pass1 && pass2;
    log(9, pass ? 'PASS' : 'FAIL', {
      login: { status: r.status, requires_2fa_setup: r.body.requires_2fa_setup, has_temp_token: !!r.body.temp_token },
      setup: {
        status: pass2 ? 200 : 'FAIL',
        has_qr_code_only: !!(setupBody.qr_code && !setupBody.secret),
        pending_secret_stored_in_db: !!DIR_SECRET,
      },
    });
  }

  // ==================== TEST 10: 2FA activate ====================
  // FIX 10: no secret in request body — server reads from pending_2fa_secret
  {
    const code = speakeasy.totp({ secret: DIR_SECRET, encoding: 'base32' });

    // Send only temp_token + totp_code (no secret field)
    const r = await post('/auth/2fa/activate', { temp_token: DIR_TEMP, totp_code: code });
    const pass1 = r.status === 200 && r.body.access_token && r.body.refresh_token;

    const rows = await dbQuery("SELECT two_fa_enabled, two_fa_secret, pending_2fa_secret FROM users WHERE id = 101");
    const pass2 = rows[0].two_fa_enabled === true
      && rows[0].two_fa_secret !== null
      && rows[0].pending_2fa_secret === null;  // pending column cleared after activation

    const pass = pass1 && pass2;
    log(10, pass ? 'PASS' : 'FAIL', {
      activate: { status: r.status, has_tokens: !!(r.body.access_token && r.body.refresh_token), user: r.body.user },
      db: {
        two_fa_enabled: rows[0].two_fa_enabled,
        has_secret: !!rows[0].two_fa_secret,
        pending_cleared: rows[0].pending_2fa_secret === null,
      },
    });
  }

  // ==================== TEST 11: 2FA login flow ====================
  {
    const r = await post('/auth/login', { email: 'testdirector@jamisan.com', password: 'TestPass123!' });
    const pass1 = r.status === 200 && r.body.requires_2fa === true && r.body.temp_token;
    const tempToken = r.body.temp_token || '';

    let pass2 = false;
    let verifyBody = {};
    if (tempToken) {
      const code = speakeasy.totp({ secret: DIR_SECRET, encoding: 'base32' });
      const r2 = await post('/auth/2fa/verify', { temp_token: tempToken, totp_code: code });
      pass2 = r2.status === 200 && r2.body.access_token && r2.body.refresh_token;
      verifyBody = r2.body;
      DIR_ACCESS = r2.body.access_token || '';
    }

    const pass = pass1 && pass2;
    log(11, pass ? 'PASS' : 'FAIL', {
      login: { status: r.status, requires_2fa: r.body.requires_2fa, has_temp_token: !!r.body.temp_token },
      verify: { has_tokens: !!(verifyBody.access_token && verifyBody.refresh_token), user: verifyBody.user },
    });
  }

  // ============================================================
  // NEW TESTS — Security patch verification
  // ============================================================

  // ==================== TEST N1: Deactivated account → 401 generic (FIX 7) ====================
  {
    await dbQuery("UPDATE users SET is_active = false WHERE id = 100");

    const r = await post('/auth/login', { email: 'testcsr@jamisan.com', password: 'NewPass456!' });
    // Must be 401 (not 403/other), message must be the same generic message as unknown-email
    const pass = r.status === 401 && r.body.message === 'Invalid email or password';

    await dbQuery("UPDATE users SET is_active = true WHERE id = 100");  // restore

    log('N1 (deactivated → 401 generic)', pass ? 'PASS' : 'FAIL', {
      status: r.status,
      message: r.body.message,
      expected_message: 'Invalid email or password',
    });
  }

  // ==================== TEST N2: 10 unknown-email failures → alert count in audit_log (FIX 8) ====================
  {
    const testEmail = 'nonexistent_test_12345@nowhere.invalid';
    await dbQuery("DELETE FROM audit_log WHERE new_value = $1", [testEmail]);

    // Fire 10 sequential login attempts with a non-existent email
    for (let i = 0; i < 10; i++) {
      await post('/auth/login', { email: testEmail, password: 'wrongpass' });
    }

    const rows = await dbQuery(
      `SELECT COUNT(*)::int AS cnt FROM audit_log
       WHERE action = 'login_failed' AND new_value = $1
         AND created_at > now() - interval '24 hours'`,
      [testEmail]
    );
    const cnt = rows[0].cnt;
    const pass = cnt >= 10;

    log('N2 (unknown-email alert count)', pass ? 'PASS' : 'FAIL', {
      audit_log_failure_count_24h: cnt,
      expected: '>= 10',
    });
  }

  // ==================== TEST N3: Client-supplied secret is ignored in activate (FIX 10) ====================
  {
    // Reset Director 2FA so we can run a fresh setup/activate cycle
    await dbQuery(`
      UPDATE users
      SET two_fa_enabled = false, two_fa_secret = NULL, pending_2fa_secret = NULL
      WHERE id = 101
    `);

    // Login to get a new temp_token
    const loginR = await post('/auth/login', { email: 'testdirector@jamisan.com', password: 'TestPass123!' });
    const tempToken = loginR.body.temp_token || '';

    // Setup — stores secret server-side
    await post('/auth/2fa/setup', { temp_token: tempToken });

    // Read the real server-side secret
    const setupRows = await dbQuery("SELECT pending_2fa_secret FROM users WHERE id = 101");
    const serverSecret = setupRows[0]?.pending_2fa_secret || '';

    // Generate valid TOTP code from server-side secret
    const code = speakeasy.totp({ secret: serverSecret, encoding: 'base32' });

    // Attempt activate with a BOGUS client-supplied secret AND correct TOTP code
    const ATTACKER_SECRET = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    const r = await post('/auth/2fa/activate', {
      temp_token: tempToken,
      totp_code: code,
      secret: ATTACKER_SECRET,  // should be completely ignored
    });

    // Verify the server used its own stored secret (not the attacker's)
    const dbRows = await dbQuery("SELECT two_fa_secret, pending_2fa_secret FROM users WHERE id = 101");
    const serverSecretUsed = dbRows[0].two_fa_secret === serverSecret;
    const attackerSecretNotUsed = dbRows[0].two_fa_secret !== ATTACKER_SECRET;
    const pendingCleared = dbRows[0].pending_2fa_secret === null;

    const pass = r.status === 200 && serverSecretUsed && attackerSecretNotUsed && pendingCleared;

    log('N3 (client secret ignored in activate)', pass ? 'PASS' : 'FAIL', {
      activate_status: r.status,
      server_secret_used: serverSecretUsed,
      attacker_secret_not_stored: attackerSecretNotUsed,
      pending_cleared: pendingCleared,
    });

    // Restore DIR_SECRET for any tests that follow
    DIR_SECRET = serverSecret;
  }

  // ==================== TEST N4: 20 concurrent wrong-password requests → atomic lockout (FIX 9) ====================
  {
    await dbQuery("UPDATE users SET failed_login_attempts = 0, locked_until = NULL WHERE id = 100");

    // Fire 20 concurrent wrong-password requests
    const concurrentRequests = Array.from({ length: 20 }, () =>
      post('/auth/login', { email: 'testcsr@jamisan.com', password: 'concurrent_wrong_pass' })
    );
    const results = await Promise.all(concurrentRequests);

    const statuses = results.map((r) => r.status);
    const has401 = statuses.includes(401);
    const has423 = statuses.includes(423);

    // Verify lockout was applied exactly (no race: locked_until must be set)
    const rows = await dbQuery("SELECT failed_login_attempts, locked_until FROM users WHERE id = 100");
    const lockedUntilSet = rows[0].locked_until !== null;
    const attemptsReasonable = rows[0].failed_login_attempts >= 5;

    const pass = has401 && has423 && lockedUntilSet && attemptsReasonable;

    log('N4 (concurrent lockout — atomic)', pass ? 'PASS' : 'FAIL', {
      total_concurrent_requests: 20,
      statuses_sample: [...new Set(statuses)],
      has_401: has401,
      has_423: has423,
      db_locked_until_set: lockedUntilSet,
      db_failed_attempts: rows[0].failed_login_attempts,
    });
  }

  // ==================== SUMMARY ====================
  console.log('\n========================================');
  console.log(`Integration tests complete: ${passed} passed, ${failed} failed`);
  console.log('========================================\n');

  await pool.end();
  if (failed > 0) process.exit(1);
}

run().catch((err) => {
  console.error('Test runner error:', err);
  pool.end();
  process.exit(1);
});
