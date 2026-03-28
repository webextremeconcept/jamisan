-- Migration 005: Order Ingestion
-- Run AFTER Migration 006 (products table must be seeded before webhook goes live)

-- 1. Index for idempotency check on every webhook call
CREATE INDEX IF NOT EXISTS idx_orders_api_batch_id
    ON orders (api_batch_id)
    WHERE api_batch_id IS NOT NULL;

-- 2. Ensure 'Other' fallback source exists (id 10 confirmed, guard is a safety net)
INSERT INTO order_sources (name, is_active)
SELECT 'Other', true
WHERE NOT EXISTS (SELECT 1 FROM order_sources WHERE LOWER(name) = 'other');
