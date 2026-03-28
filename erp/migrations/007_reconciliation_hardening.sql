-- Migration 007: Reconciliation log hardening
-- Run AFTER Migration 006

-- 1. Unique constraint on reconciliation_date — prevents phantom duplicate rows
--    from concurrent cron/webhook invocations.
CREATE UNIQUE INDEX IF NOT EXISTS idx_reconciliation_date_unique
  ON pabbly_reconciliation_log (reconciliation_date);

-- 2. Allow NULL on count and discrepancy columns so a partial row (one side
--    not yet received) can be represented correctly as 'unknown', not 0.
ALTER TABLE pabbly_reconciliation_log ALTER COLUMN crm_order_count  DROP NOT NULL;
ALTER TABLE pabbly_reconciliation_log ALTER COLUMN pabbly_order_count DROP NOT NULL;
ALTER TABLE pabbly_reconciliation_log ALTER COLUMN discrepancy      DROP NOT NULL;
