# JAMISAN ERP — MASTER SPECIFICATION
**Read this file before touching any code. No exceptions.**
Jamisan Global Nigeria Ltd. | Version 2.0 | Build Blitz Active

---

## PROJECT OVERVIEW

COD (Cash on Delivery) e-commerce ERP replacing Google Sheets.
11,000+ orders/month across Beauty and Gadgets departments.
Hosted at: **app.jamisan.com** (Hetzner Cloud CPX32, Helsinki — IP: 77.42.85.141)

| Item | Detail |
|---|---|
| Business model | Cash on Delivery — no online payment gateway |
| Departments | Beauty, Gadgets (expandable) |
| Monthly volume | 11,000+ orders, scaling |
| Goal | One unified database, unlimited scale, 9 role interfaces, real-time reporting |

---

## TECH STACK

| Layer | Technology |
|---|---|
| Backend | Node.js + Express.js |
| Database | PostgreSQL 17 — 62 tables (post Module 1) |
| Frontend | HTML + Tailwind CSS + HTMX + Alpine.js |
| Auth | JWT stateless (token_version) + TOTP 2FA (Director, Ops_Manager, Accountant) |
| Process manager | PM2 |
| Reverse proxy | Nginx (SSL termination → port 3000) |
| CDN/Security | Cloudflare |
| Build tool | Claude Code |
| VPS | Hetzner Cloud CPX32 — 4 vCPU, 8GB RAM, 80GB NVMe, Ubuntu 24.04 |
| Domain | app.jamisan.com — Cloudflare proxied |
| DB user | jamisan_admin |
| DB name | jamisan_erp |
| App path | /opt/jamisan-erp/ |

---

## DATABASE SUMMARY

- **62 tables** (61 original + wati_export_queue added in Module 1)
- Schema file: `jamisan_erp_schema.sql` (6,042 lines — post Module 1 + Gemini fixes)
- 22 triggers, 216 indexes, 129 FK constraints, 915 seed rows
- Revenue = Cash Paid orders only. Cash Remitted is retired.
- Three-state inventory: Available = waybill_stock − reserved − decremented
- Agent ledger: Cash_Remitted credit fires on UPDATE WHERE status = Verified_Cleared (NOT on INSERT)
- Order ID format: CJAM + number starting from 1000 (e.g. CJAM1000) — PostgreSQL SEQUENCE cjam_order_seq START 1000, atomic
- Auth columns on users: token_version, failed_login_attempts, locked_until, two_fa_secret, two_fa_enabled, pending_2fa_secret
- Audit log is IMMUTABLE — PostgreSQL DO INSTEAD NOTHING rules prevent UPDATE/DELETE
- audit_log.user_id is NULLABLE — allows anonymous failed login logging

---

## 9 ROLES AND ACCESS LEVELS

| Role | DB role_name | Landing Page | 2FA |
|---|---|---|---|
| Director | Director | Financial Hero dashboard | ✅ Required |
| Operations Manager | Operations_Manager | Command Center Live Dashboard | ✅ Required |
| CSR | CSR | Order grid (DATABASE tab) | ❌ |
| Accountant | Accountant | Pending Actions dashboard | ✅ Required |
| HR | HR | Staff Directory | ❌ |
| Warehouse Coordinator | Warehouse_Coordinator | Live Inventory | ❌ |
| Auditor | Auditor | Audit Dashboard | ❌ |
| Social Media Manager | Social_Media_Manager | Performance Insights | ❌ |
| Data Analyst | Data_Analyst | Deep Query Engine | ❌ |

⚠ Always use the exact role_name string from the DB column above. Never guess or assume.

---

## MODULE STATUS — BUILD BLITZ

| # | Module | Branch | Status |
|---|---|---|---|
| 1 | Database Schema | erp/feature/database-schema | ✅ Complete |
| 2 | Auth System | erp/feature/auth-system | ✅ Complete |
| 3 | Order Ingestion | erp/feature/order-ingestion | ✅ Complete |
| 4 | CSR Interface | erp/feature/csr-interface | 🔵 Current |
| 5 | Admin Interface | erp/feature/admin-interface | Not started |
| 6 | Finance Module | erp/feature/finance-module | Not started |
| 7 | Reporting Dashboard | erp/feature/reporting-dashboard | Not started |
| 8 | WATI Integration | erp/feature/wati-integration | Not started |
| 9 | Polish and Deploy | erp/feature/polish-deploy | Not started |

---

## ⚠ MODULE BUILD WORKFLOW — MANDATORY FOR EVERY MODULE

This workflow must be followed for every module without exception.

### Stage 1 — Session Start
```
1. git pull origin main
2. Read SPEC.md (this file) — you are doing this now ✓
3. git checkout erp/feature/[current-module]
4. Read all existing files in the current branch before writing anything new
```

### Stage 2 — Research (Before Any Code)
- Use **Context7** to pull live documentation for every library used in this module
- Use **PostgreSQL MCP** to inspect relevant live table structures before writing any queries
- Example: "Use Context7 to look up current docs for [lib1], [lib2], [lib3]"

### Stage 3 — Planning (Before Any Code)
- Run: `/write-plan` (Superpowers plugin)
- Present the full implementation plan to the user for approval
- ⚠ DO NOT write a single line of application code until the user explicitly approves the plan

### Stage 4 — Build
- Run: `/execute-plan` (Superpowers plugin)
- Build in focused increments
- Commit at every meaningful checkpoint: `git add . && git commit -m "feat: [description]"`

### Stage 5 — Post-Build Review
- Run: **Code review plugin** on all new files
- Fix every Critical and Important issue before proceeding
- Run: **Code Simplifier plugin** on heavily modified files to clean up patched code

### Stage 6 — Testing
- Run the full verification checklist for the module
- Report PASS or FAIL for every test
- Do not proceed until all tests pass

### Stage 7 — Gemini Review
Export schema and source code for external architectural review.

**Schema export — run on VPS:**
```bash
pg_dump -U jamisan_admin -h localhost -d jamisan_erp --schema-only -f /root/module[N]_final.sql
```
Password: `grep DB_PASSWORD /opt/jamisan-erp/.env`

**Code bundle — run in Claude Code:**
Concatenate all new/modified source files into `erp/module[N]_review.txt` with `=== FILE: ===` headers.
Commit and push so user can pull locally with `git pull origin main`.

**Gemini review prompt template — paste this to user:**
```
You are a senior [Node.js security architect / PostgreSQL database architect] performing a
production peer review of Module [N] — [Module Name] for a Nigerian e-commerce ERP handling
real financial transactions (11,000+ orders/month, ~50 staff, Hetzner CPX32 VPS).

Previous modules completed:
- Module 1: Database Schema (62 tables, 22 triggers, 216 indexes, 3 Gemini rounds, 7 fixes)
- Module 2: Auth System (JWT stateless token_version, TOTP 2FA, 14 security fixes, production sign-off)
[Add current module summary here]

Please review the attached files and identify:
1. Security vulnerabilities or logic errors
2. Performance issues under 11,000 orders/month load
3. Missing indexes on high-query columns
4. Edge cases not handled
5. Any violations of the ERP spec rules below

Key spec rules to enforce:
- Order ID: CJAM + cjam_order_seq (starts at 1000) — atomic, never reused
- Status on ingestion: always Interested
- Return customer detection: check customers table by phone number
- Ban check: customers.is_banned on ingestion — reject banned customers
- 2FA required for: Director, Operations_Manager, Accountant
- Audit log is immutable — never UPDATE or DELETE audit_log rows
- All failures and state changes must be logged to audit_log
- Password resets: no self-serve — Ops Manager only via Admin route (Module 5)
- token_version stateless invalidation — no refresh tokens stored in DB
- is_active = false must also increment token_version (implemented in Module 5)

If you find nothing critical, say so clearly and confirm the module is production-ready.
Be critical. This handles real money and real employee data.
```

### Stage 8 — Apply Gemini Fixes
- Apply every Critical and High finding
- Re-run affected tests after each fix
- Re-run Code review plugin to confirm no regressions

### Stage 9 — Final Commit and Merge
```bash
git add .
git commit -m "feat: Module [N] complete — [summary of what was built]"
git checkout main
git merge erp/feature/[module-branch]
git push origin main
```
Update module status table in this SPEC.md file.

---

## KEY DECISIONS — QUICK REFERENCE

### Orders
- Status on ingestion: always `Interested`
- Auto-abandon: Pending orders → Abandoned at exactly 72 hours via cron (every 15 min)
- Cash Paid reversal: if status changes away from Cash Paid, reverse ledger debit and stock decrement
- Abandoned → Cash Paid: re-fire all triggers + set `late_cash_paid = true`
- Logistics fee trigger: Cash Paid → `Logistics_Fee_Retained`, Failed/Returned → `Return_Fee_Retained`

### Inventory
- `available` = GENERATED ALWAYS AS (waybill_stock − reserved − decremented) STORED
- CHECK constraint: `available >= 0` — database-level safety net
- Director approval required if stock adjustment pushes available below zero
- Main stock and Order Bump stock tracked in separate tables

### Finance
- Revenue = SUM(orders.price) WHERE status = Cash Paid
- Agent ledger Cash_Remitted credit: fires on UPDATE WHERE status = `Verified_Cleared` only
- Remittance shortage stays as agent ledger debit until Director explicitly forgives
- Payroll flow: HR prepares → Director approves → Accountant pays externally → logs reference
- All expense tables have `receipt_url` (Google Drive link)

### Auth (Module 2 — Complete)
- JWT stateless invalidation via token_version — no refresh tokens stored in DB
- Access token: 15min expiry | Refresh token: 8h expiry | Temp/2FA token: 5min expiry
- Logout and password change both increment token_version — instantly invalidates all tokens
- 2FA roles: Director, Operations_Manager, Accountant — use exact strings
- TOTP secret stored server-side in pending_2fa_secret, promoted to two_fa_secret on activation
- Login lockout: 5 failures → 30min lock (atomic SQL CASE WHEN)
- Alert email: 10+ failures in 24h, gated to once per 24h per email via audit_log
- POST /auth/forgot-password: hard 403 — no self-serve resets
- is_active = false must also increment token_version — implement in Module 5

### WATI / Pabbly
- WATI export: real-time on Cash Paid → writes to CashPaid Google Sheet
- Pabbly reads sheet at 5:30 AM WAT — unchanged
- wati_sequence_triggered = true prevents duplicate exports
- wati_suppressed = true (complaint/refund logged) prevents export

### CSR Interface
- Pagination: 150 rows default, max 1000
- Abandoned auto-switch: 72 hours (3 days)
- CSR status thresholds: 🟢 <20 min, 🟡 20-45 min, 🔴 >45 min

### Module 5 Pending Actions
- is_active = false route must also increment token_version atomically
- Password reset route: Ops Manager/Director only, overwrites hash + increments token_version
- Flagged in authMiddleware.js and authController.js comments

---

## INTEGRATION BOUNDARIES

| System | What it does | What ERP does |
|---|---|---|
| Pabbly | Form ingestion, round-robin CSR assignment, pre-purchase WATI, reads CashPaid sheet | Receives webhook, generates Order ID, detects return customers |
| WATI | Post-purchase sequences, automation rules | Writes rows to CashPaid Google Sheet in real-time |
| Google Sheets | CashPaid tab holds last processed orders | Appends rows on Cash Paid, preserves SequenceTriggered = YES |
| Cloudflare | CDN, DDoS, bot protection | Sits behind Cloudflare — nothing to do |

---

## SPEC DOCUMENTS (for deep detail)

| Document | Contents |
|---|---|
| `Jamisan_ERP_Spec_Day1.docx` | Business logic, order lifecycle, all 32 statuses, 9 roles, UI/UX |
| `Jamisan_ERP_Spec_Day2.docx` | Schema decisions, 17 audit fixes, trigger timing |
| `Jamisan_ERP_Spec_Day3.docx` | All 9 role interfaces — full UI/UX spec |
| `Jamisan_ERP_Spec_Day4.docx` | Pabbly payload contract, trigger map, 6 cron jobs, WATI export |
| `Jamisan_ERP_Spec_Day5.docx` | Tech stack, folder structure, Git rules, env vars, VPS setup |
| `Jamisan_ERP_Spec_Amendment.docx` | All spec amendments — hosting decision, 14 patches locked |
| `jamisan_erp_schema.sql` | PostgreSQL SQL — production-ready, 6,042 lines |
| `Jamisan_ERP_Build_Agenda.docx` | Build tracker — module status and completion summaries |

---

## MODULE COMPLETION SUMMARIES

### Module 1 — Database Schema ✅
62 tables, 22 triggers, 216 indexes, 129 FK constraints, 915 seed rows.
3 Gemini review rounds, 7 issues fixed (race condition, audit log immutability, inventory routing, late Cash Paid loophole, FK indexes, updated_at triggers, stock INSERT guard).
Migration files: 001_peer_review_fixes.sql, 002_auth_system_columns.sql (from Module 2).

### Module 2 — Auth System ✅
12 files, 8 auth endpoints, 14 security fixes applied across 3 review rounds (Code review plugin x2 + Gemini x2).
Commits: bd14521, fb7346d, e885d7e. All 14 QA tests pass. Gemini final sign-off received.
Key files: src/controllers/authController.js, src/middleware/authMiddleware.js, src/services/tokenService.js.
Migrations: 003_auth_system_columns.sql, 004_pending_2fa_secret.sql.

### Module 3 — Order Ingestion ✅
16 files, 4 migrations (005-008). Pabbly webhook with Bearer token auth (HMAC timingSafeEqual), CJAM Order ID generation via cjam_order_seq, return customer detection, ban check (order created with status=Banned), product/geo/source FK lookups with Miscellaneous fallback, department+brand inherited from product row. Reconciliation split: midnight cron writes CRM count + POST /webhook/pabbly-reconcile receives Pabbly count. 11 code review fixes + 5 Gemini fixes (idempotency UNIQUE constraint, timezone fix, NULL math, payload sanitization, body size limit). 17 QA tests pass. Commits: 5cd8d1c, 1f78eee, 7264436. Gemini final sign-off received.

---

*Jamisan ERP — SPEC.md v2.0 | Build Blitz Active | Module 4 Current | Confidential*
