# JAMISAN ERP — TOOLS, PLUGINS AND MCP GUIDE
**Read this file alongside SPEC.md at the start of every session.**
Jamisan Global Nigeria Ltd. | Version 1.0 | Build Blitz Active

---

## ⚠ MANDATORY RULE
Every Claude Code session must read SPEC.md AND this file before touching any code.
The tools listed here are not optional — they are part of the build workflow.

---

## AVAILABLE TOOLS

### 1. Context7 (MCP Server)
**What it does:** Fetches live, up-to-date documentation for any npm library directly into context. Prevents hallucinated or outdated API usage.

**Use it when:** Starting any module that uses new npm libraries.

**How to trigger:**
```
Use Context7 to look up current documentation for: [library1], [library2]
```

**Always use for these libraries:**
- `express` — routing and middleware
- `pg` — PostgreSQL client
- `jsonwebtoken` — JWT signing and verification
- `bcryptjs` — password hashing
- `speakeasy` — TOTP 2FA
- `nodemailer` — email delivery
- `libphonenumber-js` — phone normalisation
- `node-cron` — cron job scheduling
- `htmx` — HTMX attributes and events
- `alpinejs` — Alpine.js directives and stores
- `ejs` — EJS template syntax
- `tailwindcss` — Tailwind utility classes

---

### 2. PostgreSQL MCP
**What it does:** Connects directly to the live jamisan_erp database on the VPS. Inspect real table structures, run verification queries, check seed data.

**Use it when:**
- Before writing any SQL query — inspect the actual column names and types
- After running migrations — verify row counts and constraints
- Debugging FK errors — check what values exist in reference tables

**Connection details:**
- Host: 77.42.85.141
- Database: jamisan_erp
- User: jamisan_admin

**Common queries to run at session start:**
```sql
-- Check table structure before writing queries
SELECT column_name, data_type, is_nullable 
FROM information_schema.columns 
WHERE table_name = '[table_name]' 
ORDER BY ordinal_position;

-- Verify seed data exists
SELECT id, name FROM [table] ORDER BY id LIMIT 20;

-- Check sequence state
SELECT last_value FROM cjam_order_seq;
```

---

### 3. Superpowers Plugin (/write-plan and /execute-plan)
**What it does:** Structured planning and execution workflow. Forces a plan document before any code is written.

**Use it when:** Starting every new module or major feature.

**Workflow:**
1. Run `/write-plan` — generates structured implementation plan
2. Present plan to user for approval
3. User approves → run `/execute-plan`
4. Build in focused increments with checkpoints

**Never write application code before the plan is approved.**

---

### 4. Code Review Plugin
**What it does:** AI-powered code review with specialized agents. Catches Critical and Important issues before Gemini review.

**Use it when:**
- After completing each phase of a module
- After applying a batch of fixes
- Before the final Gemini review

**How to trigger:**
```
Run the Code review plugin on: [file1], [file2], [file3]
```

**Fix all Critical and Important findings before proceeding. Suggestions are optional.**

---

### 5. Code Simplifier Plugin
**What it does:** Cleans up recently modified code for clarity and maintainability. Reduces nesting, improves naming, eliminates redundancy. Never changes behaviour.

**Use it when:**
- After applying multiple patches to the same file (e.g. after 5+ fixes on authController.js)
- Before the final Gemini review
- After a module is complete and tests pass

**How to trigger:**
```
Run Code Simplifier on: [file1], [file2]
```

---

### 6. Frontend Design Plugin
**What it does:** Generates production-grade frontend interfaces with distinctive design. Avoids generic AI aesthetics. Reads design direction from mockups and spec.

**Use it when:**
- Building any UI component (grid, sidebar, modal, panel, dashboard)
- The visual output looks generic or doesn't match the mockups
- Starting Modules 4, 5, 6, 7 (any module with a frontend)

**How to trigger:**
```
Use the Frontend Design plugin to build [component] matching the attached mockup screenshots.
```

**Always attach mockup screenshots when using this plugin.**

**Design system (locked — all modules inherit):**
| Token | Value | Use |
|---|---|---|
| Sidebar background | #1a1a1a | Sidebar |
| Main panel | #FFFFFF | Content area |
| Primary orange | #F59E0B | Buttons, active states, badges |
| Gold | #D97706 | New Order button |
| Inactive | #9CA3AF | Inactive sidebar items |
| Blue | #3B82F6 | Only Me pill |
| Green | #10B981 | VIP rows, success |
| Red | #EF4444 | Banned rows, errors, danger |
| Font | Inter (CDN) | All text |
| Grid row height | 44px | Dense readable grid |
| Sidebar expanded | 240px | Default state |
| Sidebar collapsed | 64px | Icons only |
| Slide-out width | 75vw | From right |

---

### 7. GitHub Plugin (MCP)
**What it does:** Manages Git operations, PRs, branch management directly from Claude Code.

**Use it when:**
- Creating pull requests after module completion
- Checking branch status
- Reviewing commit history

---

### 8. Commit Commands Plugin
**What it does:** Standardizes commit message format.

**Use it when:** Making any git commit. Ensures consistent commit message style across all modules.

---

## MODULE-SPECIFIC TOOL ASSIGNMENTS

| Module | Context7 | PostgreSQL MCP | Superpowers | Code Review | Code Simplifier | Frontend Design |
|---|---|---|---|---|---|---|
| 1 — DB Schema | ❌ | ✅ Verify tables | ✅ Plan | ❌ SQL only | ❌ | ❌ |
| 2 — Auth System | ✅ jwt, bcrypt, speakeasy | ✅ Inspect users/sessions | ✅ Plan | ✅ Security critical | ✅ After fixes | ❌ |
| 3 — Order Ingestion | ✅ libphonenumber, node-cron | ✅ Inspect orders/customers | ✅ Plan | ✅ | ✅ After fixes | ❌ |
| 4 — CSR Interface | ✅ htmx, alpinejs, ejs | ✅ Inspect orders/users | ✅ Plan | ✅ | ✅ After fixes | ✅ All UI |
| 5 — Admin Interface | ✅ htmx, alpinejs | ✅ | ✅ Plan | ✅ | ✅ | ✅ All UI |
| 6 — Finance Module | ✅ | ✅ Inspect ledger tables | ✅ Plan | ✅ Financial critical | ✅ | ✅ Accountant UI |
| 7 — Reporting | ✅ chart.js or similar | ✅ Inspect reporting tables | ✅ Plan | ✅ | ✅ | ✅ Dashboards |
| 8 — WATI Integration | ✅ googleapis | ✅ | ✅ Plan | ✅ | ✅ | ❌ |
| 9 — Polish & Deploy | ❌ | ✅ Final verification | ❌ | ✅ Full audit | ✅ | ✅ Mobile pass |

---

## MANDATORY BUILD WORKFLOW (every module)

```
Stage 1 — Session Start
  → git pull origin main
  → Read SPEC.md
  → Read TOOLS.md (this file)
  → git checkout erp/feature/[current-module]

Stage 2 — Research
  → Use Context7 for all libraries in this module
  → Use PostgreSQL MCP to inspect relevant tables

Stage 3 — Planning
  → Run /write-plan (Superpowers)
  → Present plan to user
  → WAIT FOR APPROVAL before writing any code

Stage 4 — Build
  → Run /execute-plan (Superpowers)
  → Commit at every meaningful checkpoint

Stage 5 — Post-Build Review
  → Run Code Review plugin on all new files
  → Fix all Critical and Important findings
  → Run Code Simplifier on heavily patched files

Stage 6 — Testing
  → Run full verification checklist
  → All tests must pass before proceeding

Stage 7 — Gemini Review
  → Export schema: pg_dump --schema-only
  → Bundle code: concatenate key files into module[N]_review.txt
  → Send to Gemini with the template prompt from SPEC.md
  → Apply all Critical and High findings

Stage 8 — Final Commit and Merge
  → git add .
  → git commit -m "feat: Module [N] complete — [summary]"
  → git checkout main
  → git merge erp/feature/[branch]
  → git push origin main
  → Update SPEC.md module status
```

---

## GEMINI REVIEW TEMPLATE
Use this for every module's Gemini review. Fill in Module N details.

```
You are a senior [Node.js security architect / PostgreSQL database architect / 
frontend architect] performing a production peer review of Module [N] — [Name]
for a Nigerian e-commerce ERP (11,000+ orders/month, ~50 staff, Hetzner CPX32).

Previous modules: Module 1 (DB Schema), Module 2 (Auth), Module 3 (Order Ingestion) — all complete.

Review the attached files for:
1. Security vulnerabilities or logic errors
2. Performance issues under 11,000 orders/month
3. Missing indexes on high-query columns
4. Edge cases not handled
5. Spec violations (see key rules below)

Key spec rules:
- Order ID: CJAM + cjam_order_seq (starts 1000) — atomic
- Status on ingestion: always Interested (or Banned if is_banned=true)
- Webhook always returns 200 — never 4xx on processing errors (401 only for bad token)
- api_batch_id is idempotency key — duplicates skipped
- product_id always NOT NULL — Miscellaneous fallback
- department_id and brand_id inherited from product row
- Audit log immutable — never UPDATE or DELETE
- All failures logged to audit_log
- token_version stateless JWT invalidation
- 2FA required: Director, Operations_Manager, Accountant
- Password resets: no self-serve — Ops Manager only (Module 5)
- HTMX inline edits: hx-target="closest tr" — never re-render full grid
- Status dropdown: Alpine intercepts — no hx-patch on <select> directly

If nothing critical: confirm module is production-ready.
Be critical. This handles real money and real employee data.
```

---

## VPS QUICK REFERENCE
| Item | Value |
|---|---|
| Host | 77.42.85.141 |
| OS | Ubuntu 24.04 |
| App path | /opt/jamisan-erp/ |
| DB name | jamisan_erp |
| DB user | jamisan_admin |
| DB password | see /opt/jamisan-erp/.env |
| Node process | PM2 (Module 9) / nohup node src/server.js currently |
| Schema export | `pg_dump -U jamisan_admin -h localhost -d jamisan_erp --schema-only -f /root/module[N]_final.sql` |
| SSH key | C:\Users\bmegb\.ssh\id_ed25519 |
| SSH user | root |

---

*Jamisan ERP — TOOLS.md v1.0 | All modules | Confidential*
