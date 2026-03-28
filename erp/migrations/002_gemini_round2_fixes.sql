-- Module 1 Gemini Round 2 Fixes — Applied 2026-03-27
-- 3 issues: missing indexes, missing updated_at triggers, stock INSERT blindspot

SET ROLE jamisan_admin;

-- =============================================================================
-- FIX 1: Missing FK and filter indexes (140 indexes)
-- =============================================================================

-- FK INDEXES (128 columns)
CREATE INDEX idx_action_items_assigned_by ON action_items(assigned_by);
CREATE INDEX idx_action_items_assigned_to ON action_items(assigned_to);
CREATE INDEX idx_action_items_closed_by ON action_items(closed_by);
CREATE INDEX idx_ad_expenses_brand_id ON ad_expenses(brand_id);
CREATE INDEX idx_ad_expenses_logged_by ON ad_expenses(logged_by);
CREATE INDEX idx_ad_expenses_product_id ON ad_expenses(product_id);
CREATE INDEX idx_admin_level_1_country_id ON admin_level_1(country_id);
CREATE INDEX idx_admin_level_2_admin_level_1_id ON admin_level_2(admin_level_1_id);
CREATE INDEX idx_agent_ledger_agent_id ON agent_ledger(agent_id);
CREATE INDEX idx_agent_ledger_logged_by ON agent_ledger(logged_by);
CREATE INDEX idx_agent_remittance_admin_level_1_id ON agent_remittance(admin_level_1_id);
CREATE INDEX idx_agent_remittance_agent_id ON agent_remittance(agent_id);
CREATE INDEX idx_agent_remittance_logged_by ON agent_remittance(logged_by);
CREATE INDEX idx_agent_remittance_variance_reason_id ON agent_remittance(variance_reason_id);
CREATE INDEX idx_agent_zone_assignments_admin_level_1_id ON agent_zone_assignments(admin_level_1_id);
CREATE INDEX idx_agent_zone_assignments_admin_level_2_id ON agent_zone_assignments(admin_level_2_id);
CREATE INDEX idx_agent_zone_assignments_overflow_agent_id ON agent_zone_assignments(overflow_agent_id);
CREATE INDEX idx_agent_zone_assignments_primary_agent_id ON agent_zone_assignments(primary_agent_id);
CREATE INDEX idx_agents_admin_level_1_id ON agents(admin_level_1_id);
CREATE INDEX idx_agents_admin_level_2_id ON agents(admin_level_2_id);
CREATE INDEX idx_audit_log_user_id ON audit_log(user_id);
CREATE INDEX idx_auditor_spot_checks_auditor_id ON auditor_spot_checks(auditor_id);
CREATE INDEX idx_auditor_spot_checks_check_category_id ON auditor_spot_checks(check_category_id);
CREATE INDEX idx_auditor_spot_checks_order_id ON auditor_spot_checks(order_id);
CREATE INDEX idx_brands_department_id ON brands(department_id);
CREATE INDEX idx_brands_niche_id ON brands(niche_id);
CREATE INDEX idx_commission_tiers_department_id ON commission_tiers(department_id);
CREATE INDEX idx_complaints_assigned_csr_id ON complaints(assigned_csr_id);
CREATE INDEX idx_complaints_customer_id ON complaints(customer_id);
CREATE INDEX idx_complaints_order_id ON complaints(order_id);
CREATE INDEX idx_complaints_resolved_by ON complaints(resolved_by);
CREATE INDEX idx_csr_level_history_changed_by ON csr_level_history(changed_by);
CREATE INDEX idx_csr_level_history_user_id ON csr_level_history(user_id);
CREATE INDEX idx_csr_performance_monthly_commission_tier_id ON csr_performance_monthly(commission_tier_id);
CREATE INDEX idx_csr_performance_monthly_department_id ON csr_performance_monthly(department_id);
CREATE INDEX idx_csr_performance_monthly_user_id ON csr_performance_monthly(user_id);
CREATE INDEX idx_csr_promotion_thresholds_department_id ON csr_promotion_thresholds(department_id);
CREATE INDEX idx_customers_banned_by ON customers(banned_by);
CREATE INDEX idx_department_targets_department_id ON department_targets(department_id);
CREATE INDEX idx_department_targets_set_by ON department_targets(set_by);
CREATE INDEX idx_escalation_reason_codes_created_by ON escalation_reason_codes(created_by);
CREATE INDEX idx_expenses_admin_level_1_id ON expenses(admin_level_1_id);
CREATE INDEX idx_expenses_agent_id ON expenses(agent_id);
CREATE INDEX idx_expenses_expense_category_id ON expenses(expense_category_id);
CREATE INDEX idx_expenses_logged_by ON expenses(logged_by);
CREATE INDEX idx_expenses_product_id ON expenses(product_id);
CREATE INDEX idx_goods_movement_admin_level_1_id ON goods_movement(admin_level_1_id);
CREATE INDEX idx_goods_movement_from_agent_id ON goods_movement(from_agent_id);
CREATE INDEX idx_goods_movement_logged_by ON goods_movement(logged_by);
CREATE INDEX idx_goods_movement_product_id ON goods_movement(product_id);
CREATE INDEX idx_goods_movement_shipping_type_id ON goods_movement(shipping_type_id);
CREATE INDEX idx_goods_movement_to_agent_id ON goods_movement(to_agent_id);
CREATE INDEX idx_goods_movement_variant_id ON goods_movement(variant_id);
CREATE INDEX idx_inventory_product_id ON inventory(product_id);
CREATE INDEX idx_inventory_variant_id ON inventory(variant_id);
CREATE INDEX idx_investment_inflow_logged_by ON investment_inflow(logged_by);
CREATE INDEX idx_lesson_categories_created_by ON lesson_categories(created_by);
CREATE INDEX idx_lessons_learned_category_id ON lessons_learned(category_id);
CREATE INDEX idx_lessons_learned_reviewed_by ON lessons_learned(reviewed_by);
CREATE INDEX idx_lessons_learned_submitted_by ON lessons_learned(submitted_by);
CREATE INDEX idx_loans_logged_by ON loans(logged_by);
CREATE INDEX idx_notifications_recipient_agent_id ON notifications(recipient_agent_id);
CREATE INDEX idx_notifications_recipient_user_id ON notifications(recipient_user_id);
CREATE INDEX idx_order_bump_inventory_product_id ON order_bump_inventory(product_id);
CREATE INDEX idx_order_bump_inventory_variant_id ON order_bump_inventory(variant_id);
CREATE INDEX idx_order_escalations_order_id ON order_escalations(order_id);
CREATE INDEX idx_order_escalations_raised_by ON order_escalations(raised_by);
CREATE INDEX idx_order_escalations_reason_code_id ON order_escalations(reason_code_id);
CREATE INDEX idx_order_escalations_resolved_by ON order_escalations(resolved_by);
CREATE INDEX idx_order_status_history_changed_by ON order_status_history(changed_by);
CREATE INDEX idx_order_status_history_order_id ON order_status_history(order_id);
CREATE INDEX idx_orders_admin_level_1_id ON orders(admin_level_1_id);
CREATE INDEX idx_orders_admin_level_2_id ON orders(admin_level_2_id);
CREATE INDEX idx_orders_agent_id ON orders(agent_id);
CREATE INDEX idx_orders_assigned_csr_id ON orders(assigned_csr_id);
CREATE INDEX idx_orders_brand_id ON orders(brand_id);
CREATE INDEX idx_orders_country_id ON orders(country_id);
CREATE INDEX idx_orders_customer_id ON orders(customer_id);
CREATE INDEX idx_orders_department_id ON orders(department_id);
CREATE INDEX idx_orders_failure_reason_id ON orders(failure_reason_id);
CREATE INDEX idx_orders_niche_id ON orders(niche_id);
CREATE INDEX idx_orders_order_bump_product_id ON orders(order_bump_product_id);
CREATE INDEX idx_orders_order_bump_variant_id ON orders(order_bump_variant_id);
CREATE INDEX idx_orders_product_id ON orders(product_id);
CREATE INDEX idx_orders_product_variant_id ON orders(product_variant_id);
CREATE INDEX idx_orders_shipping_type_id ON orders(shipping_type_id);
CREATE INDEX idx_orders_source_id ON orders(source_id);
CREATE INDEX idx_pabbly_reconciliation_log_reviewed_by ON pabbly_reconciliation_log(reviewed_by);
CREATE INDEX idx_payroll_director_approved_by ON payroll(director_approved_by);
CREATE INDEX idx_payroll_logged_by ON payroll(logged_by);
CREATE INDEX idx_payroll_user_id ON payroll(user_id);
CREATE INDEX idx_procurement_expenses_logged_by ON procurement_expenses(logged_by);
CREATE INDEX idx_procurement_expenses_niche_id ON procurement_expenses(niche_id);
CREATE INDEX idx_procurement_expenses_product_id ON procurement_expenses(product_id);
CREATE INDEX idx_procurement_expenses_vendor_id ON procurement_expenses(vendor_id);
CREATE INDEX idx_product_variants_product_id ON product_variants(product_id);
CREATE INDEX idx_products_brand_id ON products(brand_id);
CREATE INDEX idx_products_department_id ON products(department_id);
CREATE INDEX idx_session_log_user_id ON session_log(user_id);
CREATE INDEX idx_stock_adjustments_approved_by ON stock_adjustments(approved_by);
CREATE INDEX idx_stock_adjustments_logged_by ON stock_adjustments(logged_by);
CREATE INDEX idx_stock_adjustments_product_id ON stock_adjustments(product_id);
CREATE INDEX idx_stock_adjustments_variant_id ON stock_adjustments(variant_id);
CREATE INDEX idx_taxes_logged_by ON taxes(logged_by);
CREATE INDEX idx_trashed_items_admin_level_1_id ON trashed_items(admin_level_1_id);
CREATE INDEX idx_trashed_items_agent_id ON trashed_items(agent_id);
CREATE INDEX idx_trashed_items_logged_by ON trashed_items(logged_by);
CREATE INDEX idx_trashed_items_product_id ON trashed_items(product_id);
CREATE INDEX idx_trashed_items_variant_id ON trashed_items(variant_id);
CREATE INDEX idx_user_departments_department_id ON user_departments(department_id);
CREATE INDEX idx_user_departments_user_id ON user_departments(user_id);
CREATE INDEX idx_users_created_by ON users(created_by);
CREATE INDEX idx_users_role_id ON users(role_id);
CREATE INDEX idx_vendors_admin_level_1_id ON vendors(admin_level_1_id);
CREATE INDEX idx_vendors_admin_level_2_id ON vendors(admin_level_2_id);
CREATE INDEX idx_vendors_country_id ON vendors(country_id);
CREATE INDEX idx_wati_export_queue_order_id ON wati_export_queue(order_id);
CREATE INDEX idx_waybill_expenses_agent_id ON waybill_expenses(agent_id);
CREATE INDEX idx_waybill_expenses_from_admin_level_1_id ON waybill_expenses(from_admin_level_1_id);
CREATE INDEX idx_waybill_expenses_logged_by ON waybill_expenses(logged_by);
CREATE INDEX idx_waybill_expenses_product_id ON waybill_expenses(product_id);
CREATE INDEX idx_waybill_expenses_to_admin_level_1_id ON waybill_expenses(to_admin_level_1_id);
CREATE INDEX idx_waybill_expenses_variant_id ON waybill_expenses(variant_id);
CREATE INDEX idx_weekly_bonus_log_paid_by ON weekly_bonus_log(paid_by);
CREATE INDEX idx_weekly_bonus_log_user_id ON weekly_bonus_log(user_id);
CREATE INDEX idx_weekly_reports_csr_id ON weekly_reports(csr_id);
CREATE INDEX idx_weekly_reports_department_id ON weekly_reports(department_id);
CREATE INDEX idx_weekly_reports_generated_by ON weekly_reports(generated_by);

-- HIGH-TRAFFIC FILTER / SORT INDEXES
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_orders_phone_number ON orders(phone_number);
CREATE INDEX idx_orders_created_at ON orders(created_at);
CREATE INDEX idx_agent_remittance_status ON agent_remittance(status);
CREATE INDEX idx_audit_log_created_at ON audit_log(created_at);
CREATE INDEX idx_session_log_last_active_at ON session_log(last_active_at);
CREATE INDEX idx_wati_export_queue_status ON wati_export_queue(status);
CREATE INDEX idx_notifications_status ON notifications(status);

-- COMPOSITE INDEXES
CREATE INDEX idx_inventory_product_variant ON inventory(product_id, variant_id);
CREATE INDEX idx_order_bump_inventory_product_variant ON order_bump_inventory(product_id, variant_id);
CREATE INDEX idx_orders_status_department ON orders(status, department_id);
CREATE INDEX idx_orders_assigned_csr_status ON orders(assigned_csr_id, status);

-- =============================================================================
-- FIX 2: updated_at triggers on all editable tables (16 tables)
-- =============================================================================

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_updated_at BEFORE UPDATE ON action_items FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON agent_zone_assignments FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON agents FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON complaints FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON csr_performance_monthly FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON customers FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON employee_profiles FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON inventory FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON lessons_learned FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON loans FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON order_bump_inventory FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON order_id_counter FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON products FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON vendors FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- =============================================================================
-- FIX 3: Stock trigger INSERT blindspot
-- Fire on INSERT OR UPDATE, guard OLD.status with TG_OP check
-- =============================================================================

DROP TRIGGER IF EXISTS trg_orders_stock_management ON orders;

CREATE OR REPLACE FUNCTION fn_orders_stock_management()
RETURNS TRIGGER AS $$
DECLARE
  old_status text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    old_status := '';
  ELSE
    old_status := OLD.status;
    IF old_status = NEW.status THEN
      RETURN NEW;
    END IF;
  END IF;

  -- RESERVE: entering Pending or Scheduled
  IF NEW.status IN ('Pending', 'Scheduled') AND old_status NOT IN ('Pending', 'Scheduled') THEN
    UPDATE inventory SET reserved = reserved + NEW.quantity, updated_at = now()
    WHERE product_id = NEW.product_id AND variant_id IS NOT DISTINCT FROM NEW.product_variant_id;
    IF NEW.has_order_bump AND NEW.order_bump_product_id IS NOT NULL THEN
      UPDATE order_bump_inventory SET reserved = reserved + COALESCE(NEW.order_bump_quantity, 0), updated_at = now()
      WHERE product_id = NEW.order_bump_product_id AND variant_id IS NOT DISTINCT FROM NEW.order_bump_variant_id;
    END IF;
  END IF;

  -- DECREMENT: any status -> Cash Paid
  IF NEW.status = 'Cash Paid' AND old_status <> 'Cash Paid' THEN
    IF old_status IN ('Pending', 'Scheduled') THEN
      UPDATE inventory SET reserved = reserved - NEW.quantity, decremented = decremented + NEW.quantity, updated_at = now()
      WHERE product_id = NEW.product_id AND variant_id IS NOT DISTINCT FROM NEW.product_variant_id;
      IF NEW.has_order_bump AND NEW.order_bump_product_id IS NOT NULL THEN
        UPDATE order_bump_inventory
        SET reserved = reserved - COALESCE(NEW.order_bump_quantity, 0),
            decremented = decremented + COALESCE(NEW.order_bump_quantity, 0), updated_at = now()
        WHERE product_id = NEW.order_bump_product_id AND variant_id IS NOT DISTINCT FROM NEW.order_bump_variant_id;
      END IF;
    ELSE
      UPDATE inventory SET decremented = decremented + NEW.quantity, updated_at = now()
      WHERE product_id = NEW.product_id AND variant_id IS NOT DISTINCT FROM NEW.product_variant_id;
      IF NEW.has_order_bump AND NEW.order_bump_product_id IS NOT NULL THEN
        UPDATE order_bump_inventory
        SET decremented = decremented + COALESCE(NEW.order_bump_quantity, 0), updated_at = now()
        WHERE product_id = NEW.order_bump_product_id AND variant_id IS NOT DISTINCT FROM NEW.order_bump_variant_id;
      END IF;
    END IF;
  END IF;

  -- ROLLBACK DECREMENT: Cash Paid -> any other status
  IF old_status = 'Cash Paid' AND NEW.status <> 'Cash Paid' THEN
    UPDATE inventory SET decremented = decremented - NEW.quantity, updated_at = now()
    WHERE product_id = NEW.product_id AND variant_id IS NOT DISTINCT FROM NEW.product_variant_id;
    IF NEW.has_order_bump AND NEW.order_bump_product_id IS NOT NULL THEN
      UPDATE order_bump_inventory
      SET decremented = decremented - COALESCE(NEW.order_bump_quantity, 0), updated_at = now()
      WHERE product_id = NEW.order_bump_product_id AND variant_id IS NOT DISTINCT FROM NEW.order_bump_variant_id;
    END IF;
  END IF;

  -- RELEASE RESERVE: Pending/Scheduled -> Failed/Cancelled/Abandoned
  IF old_status IN ('Pending', 'Scheduled') AND NEW.status IN ('Failed', 'Cancelled', 'Abandoned') THEN
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

CREATE TRIGGER trg_orders_stock_management
AFTER INSERT OR UPDATE OF status ON orders
FOR EACH ROW
EXECUTE FUNCTION fn_orders_stock_management();
