# JAMISAN CRM — MASTER SPECIFICATION
**Read this file before touching any code. No exceptions.**
Jamisan Global Nigeria Ltd. | Version 1.1 | Spec Week 2025

---

## PROJECT OVERVIEW

COD (Cash on Delivery) e-commerce CRM replacing Google Sheets.
11,000+ orders/month across Beauty and Gadgets departments.
Hosted at: **app.jamisan.com** (Hetzner Cloud CPX32 + Cloudflare)

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
| Database | PostgreSQL — 61 tables |
| Frontend | HTML + Tailwind CSS + HTMX |
| Reactivity | Alpine.js |
| Auth | JWT + TOTP 2FA (Directors, Ops, Accountant) |
| Process manager | PM2 |
| Reverse proxy | Nginx (SSL termination → port 3000) |
| CDN/Security | Cloudflare |
| Build tool | Claude Code CLI |

---

## DATABASE SUMMARY

- **61 tables** across 25 sections
- Schema file: `jamisan_erp_schema.dbml` (v1.1 — 1,910 lines)
- SQL export: `jamisan_erp_schema.sql`
- Revenue = Cash Paid orders only. Cash Remitted is retired.
- Three-state inventory: Available = waybill_stock − reserved − decremented
- Agent ledger: Cash_Remitted credit fires on UPDATE WHERE status = Verified_Cleared (NOT on INSERT)
- Order ID format: CJAM + number starting from 1000 (e.g. CJAM1000, CJAM1001) — PostgreSQL SEQUENCE cjam_order_seq START 1000, atomic
- 17 schema audit fixes applied — see Day 2 spec Section 22 for full list

---

## 9 ROLES AND ACCESS LEVELS

| Role | Landing Page | Key Access |
|---|---|---|
| Director | Financial Hero dashboard | Full access, 2FA, replaces Power BI |
| Operations Manager | Command Center Live Dashboard | God-view grid, escalations, agent remittances |
| CSR | Order grid (DATABASE tab) | Own orders + team view, no finance |
| Accountant | Pending Actions dashboard | Finance module, read-only orders, 2FA |
| HR | Staff Directory | User management, punch-clock, payroll prep |
| Warehouse Coordinator | Live Inventory | Stock, waybills, goods movement |
| Auditor | Audit Dashboard | Absolute read-only — RBAC enforced |
| Social Media Manager | Performance Insights | Aggregated data only — zero PII |
| Data Analyst | Deep Query Engine | Read-only all modules + shared dashboards |

---

## CURRENT BUILD STATUS

| Day | Topic | Status |
|---|---|---|
| Day 1 | Business Logic | ✅ Complete |
| Day 2 | Database Schema (61 tables) | ✅ Complete |
| Day 3 | UI/UX — All 9 Roles | ✅ Complete |
| Day 4 | Automation and Integration Map | ✅ Complete |
| Day 5 | Tech Stack and Git Structure | ✅ Complete |
| Day 6 | Full Spec Review | ✅ Complete |
| Day 7 | Buffer | ✅ Complete |

**Current module: See below**

---

## MODULE STATUS — BUILD BLITZ

| # | Module | Branch | Status |
|---|---|---|---|
| 1 | Database Schema | erp/feature/database-schema | ⏳ Next |
| 2 | Auth System | erp/feature/auth-system | Not started |
| 3 | Order Ingestion | erp/feature/order-ingestion | Not started |
| 4 | CSR Interface | erp/feature/csr-interface | Not started |
| 5 | Admin Interface | erp/feature/admin-interface | Not started |
| 6 | Finance Module | erp/feature/finance-module | Not started |
| 7 | Reporting Dashboard | erp/feature/reporting-dashboard | Not started |
| 8 | WATI Integration | erp/feature/wati-integration | Not started |
| 9 | Polish and Deploy | erp/feature/polish-deploy | Not started |

---

## SESSION RITUAL — DO NOT SKIP ANY STEP

```
1. git pull origin main
2. Read SPEC.md (this file) — you are doing this now ✓
3. git checkout feature/[current-module]
4. Read existing files in the current branch
5. Build in focused increments
6. Commit at every meaningful checkpoint
7. Test before ending session
8. Merge to main only when module is fully tested
9. Identify decisions made today — update agenda
```

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
- Procurement: Accountant or Ops Manager can log
- All expense tables have `receipt_url` (Google Drive link)

### WATI / Pabbly
- WATI export: real-time on Cash Paid status change → writes to CashPaid Google Sheet
- Pabbly reads sheet at 5:30 AM WAT — unchanged
- WATI automation rules — unchanged
- Trigger: Cash Paid ONLY (Cash Remitted retired)
- wati_sequence_triggered = true prevents duplicate exports
- wati_suppressed = true (complaint/refund logged) prevents export

### CSR Interface
- Pagination: 150 rows default, max 1000
- Sort button: REMOVED
- Abandoned auto-switch: 72 hours (3 days)
- On Break toggle: CSR sidebar bottom left, amber bar when active
- CSR status thresholds: 🟢 <20 min, 🟡 20-45 min, 🔴 >45 min
- Pabbly assigns CSRs as normal — no status check. Ops Manager bulk reassigns Away leads manually

### Schema Audit (17 fixes — see Day 2 Section 22)
- `department_targets.department_id`: NOT unique — multiple rows for history
- `orders.order_bump_price`: added — required for P&L
- `payroll`: added `director_approved_by`, `director_approved_at`, `bank_reference`
- `procurement_expenses`: added `vendor_id` linking to vendors table
- `csr_level_history.changed_by`: nullable — NULL for automated promotions
- Agent ledger trigger timing: Verified_Cleared UPDATE, not INSERT

---

## INTEGRATION BOUNDARIES

| System | What it does | What CRM does |
|---|---|---|
| Pabbly | Form ingestion, round-robin CSR assignment, pre-purchase WATI, reads CashPaid sheet, calls WATI API, Termii SMS | Receives webhook, generates Order ID, detects return customers |
| WATI | Post-purchase sequences, automation rules | Writes rows to CashPaid Google Sheet in real-time |
| Google Sheets | CashPaid tab holds last processed orders | Appends rows on Cash Paid, preserves SequenceTriggered = YES |
| Cloudflare | CDN, DDoS, bot protection | Nothing — sits behind Cloudflare |

---

## SPEC DOCUMENTS (for deep detail)

| Document | Contents |
|---|---|
| `Jamisan_ERP_Spec_Day1.docx` | Business logic, order lifecycle, all 32 statuses, 9 roles, UI/UX (Sections 1–27) |
| `Jamisan_ERP_Spec_Day2.docx` | Schema decisions, 17 audit fixes, trigger timing |
| `Jamisan_ERP_Spec_Day3.docx` | All 9 role interfaces — full UI/UX spec |
| `Jamisan_ERP_Spec_Day4.docx` | Pabbly payload contract, trigger map, 6 cron jobs, WATI export migration |
| `Jamisan_ERP_Spec_Day5.docx` | Tech stack, folder structure, Git rules, env vars, VPS setup |
| `jamisan_erp_schema.dbml` | Full 61-table schema with inline documentation |
| `jamisan_erp_schema.sql` | PostgreSQL SQL export — run this in Module 1 |

---

## MODULE 1 CHECKLIST (Database Schema)

When starting Module 1, verify these in order:

- [ ] Run `jamisan_erp_schema.sql` against PostgreSQL on VPS
- [ ] Verify all 61 tables created correctly
- [ ] Create PostgreSQL SEQUENCE `cjam_order_seq` for Order ID generation
- [ ] Verify GENERATED ALWAYS AS on `inventory.available` and `order_bump_inventory.available`
- [ ] Add CHECK constraints: `available >= 0` on both inventory tables
- [ ] Create trigger: `trashed_items` INSERT → subtract `waybill_stock`
- [ ] Create trigger: `stock_adjustments` INSERT → update `waybill_stock`
- [ ] Create trigger: `agent_ledger` INSERT → calculate `running_balance`
- [ ] Create trigger: `orders` status change → stock reserve/decrement/rollback logic
- [ ] Create trigger: `orders` Cash Paid → WATI export service call
- [ ] Create trigger: `agent_remittance` UPDATE WHERE Verified_Cleared → agent_ledger Cash_Remitted credit
- [ ] Seed all reference data (roles, statuses, states, LGAs, expense categories, etc.)
- [ ] Seed `escalation_reason_codes` including `Auditor_Flag`
- [ ] Seed `lesson_categories`
- [ ] Seed `auditor_check_categories`
- [ ] Seed `remittance_variance_reason_codes`
- [ ] Seed `department_targets` with initial Beauty and Gadgets rates
- [ ] Add `last_active_at` to session_log
- [ ] Verify all foreign keys and indexes
- [ ] Test backup log table

---

*Jamisan ERP — SPEC.md v1.1 | Updated end of Spec Week | Confidential*
