-- Module 1 Peer Review Fixes — Applied 2026-03-27
-- Reviewer: Gemini | 4 issues identified and resolved

SET ROLE jamisan_admin;

-- =============================================================================
-- FIX 1: Agent Ledger Race Condition
-- Add pg_advisory_xact_lock to serialize concurrent inserts per agent
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_agent_ledger_running_balance()
RETURNS TRIGGER AS $$
DECLARE
  prev_balance numeric(14,2);
BEGIN
  -- Serialize per agent to prevent race conditions
  PERFORM pg_advisory_xact_lock(NEW.agent_id);

  SELECT running_balance INTO prev_balance
  FROM agent_ledger
  WHERE agent_id = NEW.agent_id
  ORDER BY id DESC
  LIMIT 1;

  IF prev_balance IS NULL THEN
    prev_balance := 0;
  END IF;

  NEW.running_balance := prev_balance
    + COALESCE(NEW.debit_amount, 0)
    - COALESCE(NEW.credit_amount, 0);

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- FIX 2: Audit Log Immutability
-- Prevent any UPDATE or DELETE on audit_log, including by Directors
-- =============================================================================
CREATE RULE prevent_audit_update AS ON UPDATE TO audit_log DO INSTEAD NOTHING;
CREATE RULE prevent_audit_delete AS ON DELETE TO audit_log DO INSTEAD NOTHING;

-- =============================================================================
-- FIX 3: stock_adjustments inventory_type column
-- Route adjustments to main inventory or order_bump_inventory
-- =============================================================================
ALTER TABLE stock_adjustments
  ADD COLUMN inventory_type varchar(20) NOT NULL DEFAULT 'main'
  CHECK (inventory_type IN ('main', 'order_bump'));

CREATE OR REPLACE FUNCTION fn_stock_adjustments_update_stock()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.inventory_type = 'main' THEN
    UPDATE inventory
    SET waybill_stock = waybill_stock + NEW.quantity_adjusted,
        updated_at = now()
    WHERE product_id = NEW.product_id
      AND variant_id IS NOT DISTINCT FROM NEW.variant_id;
  ELSIF NEW.inventory_type = 'order_bump' THEN
    UPDATE order_bump_inventory
    SET waybill_stock = waybill_stock + NEW.quantity_adjusted,
        updated_at = now()
    WHERE product_id = NEW.product_id
      AND variant_id IS NOT DISTINCT FROM NEW.variant_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- FIX 4: Late Cash Paid Stock Loophole
-- Handle Cash Paid from ANY status, not just Pending
-- Only release reservation if old status was actually holding one
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_orders_stock_management()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- === RESERVE: entering Pending or Scheduled ===
  IF NEW.status IN ('Pending', 'Scheduled') AND OLD.status NOT IN ('Pending', 'Scheduled') THEN
    UPDATE inventory SET reserved = reserved + NEW.quantity, updated_at = now()
    WHERE product_id = NEW.product_id AND variant_id IS NOT DISTINCT FROM NEW.product_variant_id;

    IF NEW.has_order_bump AND NEW.order_bump_product_id IS NOT NULL THEN
      UPDATE order_bump_inventory SET reserved = reserved + COALESCE(NEW.order_bump_quantity, 0), updated_at = now()
      WHERE product_id = NEW.order_bump_product_id AND variant_id IS NOT DISTINCT FROM NEW.order_bump_variant_id;
    END IF;
  END IF;

  -- === DECREMENT: any status -> Cash Paid ===
  IF NEW.status = 'Cash Paid' AND OLD.status <> 'Cash Paid' THEN
    IF OLD.status IN ('Pending', 'Scheduled') THEN
      -- Release reservation AND decrement
      UPDATE inventory SET reserved = reserved - NEW.quantity, decremented = decremented + NEW.quantity, updated_at = now()
      WHERE product_id = NEW.product_id AND variant_id IS NOT DISTINCT FROM NEW.product_variant_id;

      IF NEW.has_order_bump AND NEW.order_bump_product_id IS NOT NULL THEN
        UPDATE order_bump_inventory
        SET reserved = reserved - COALESCE(NEW.order_bump_quantity, 0),
            decremented = decremented + COALESCE(NEW.order_bump_quantity, 0), updated_at = now()
        WHERE product_id = NEW.order_bump_product_id AND variant_id IS NOT DISTINCT FROM NEW.order_bump_variant_id;
      END IF;
    ELSE
      -- Late Cash Paid (from Abandoned/Failed/Cancelled) -- no reservation to release
      UPDATE inventory SET decremented = decremented + NEW.quantity, updated_at = now()
      WHERE product_id = NEW.product_id AND variant_id IS NOT DISTINCT FROM NEW.product_variant_id;

      IF NEW.has_order_bump AND NEW.order_bump_product_id IS NOT NULL THEN
        UPDATE order_bump_inventory
        SET decremented = decremented + COALESCE(NEW.order_bump_quantity, 0), updated_at = now()
        WHERE product_id = NEW.order_bump_product_id AND variant_id IS NOT DISTINCT FROM NEW.order_bump_variant_id;
      END IF;
    END IF;
  END IF;

  -- === ROLLBACK DECREMENT: Cash Paid -> any other status ===
  IF OLD.status = 'Cash Paid' AND NEW.status <> 'Cash Paid' THEN
    UPDATE inventory SET decremented = decremented - NEW.quantity, updated_at = now()
    WHERE product_id = NEW.product_id AND variant_id IS NOT DISTINCT FROM NEW.product_variant_id;

    IF NEW.has_order_bump AND NEW.order_bump_product_id IS NOT NULL THEN
      UPDATE order_bump_inventory
      SET decremented = decremented - COALESCE(NEW.order_bump_quantity, 0), updated_at = now()
      WHERE product_id = NEW.order_bump_product_id AND variant_id IS NOT DISTINCT FROM NEW.order_bump_variant_id;
    END IF;
  END IF;

  -- === RELEASE RESERVE: Pending/Scheduled -> Failed/Cancelled/Abandoned ===
  IF OLD.status IN ('Pending', 'Scheduled') AND NEW.status IN ('Failed', 'Cancelled', 'Abandoned') THEN
    UPDATE inventory SET reserved = reserved - NEW.quantity, updated_at = now()
    WHERE product_id = NEW.product_id AND variant_id IS NOT DISTINCT FROM NEW.product_variant_id;

    IF NEW.has_order_bump AND NEW.order_bump_product_id IS NOT NULL THEN
      UPDATE order_bump_inventory SET reserved = reserved - COALESCE(NEW.order_bump_quantity, 0), updated_at = now()
      WHERE product_id = NEW.order_bump_product_id AND variant_id IS NOT DISTINCT FROM NEW.order_bump_variant_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
