-- Migration 008: UNIQUE constraint on orders.api_batch_id
-- Closes the race window where two concurrent requests with the same api_batch_id
-- could both pass the SELECT idempotency check before either INSERT completes.
-- PostgreSQL UNIQUE allows multiple NULLs, so non-webhook orders are unaffected.
ALTER TABLE orders ADD CONSTRAINT unique_api_batch_id UNIQUE (api_batch_id);
