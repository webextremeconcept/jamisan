--
-- PostgreSQL database dump
--

\restrict ycya37egdNQ1ck9A1q8gz4YlVhzqXFIJBhFEUIbduzNmhmJWhQy0fiqHUjINPpB

-- Dumped from database version 17.9 (Ubuntu 17.9-1.pgdg24.04+1)
-- Dumped by pg_dump version 17.9 (Ubuntu 17.9-1.pgdg24.04+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: fn_agent_ledger_running_balance(); Type: FUNCTION; Schema: public; Owner: jamisan_admin
--

CREATE FUNCTION public.fn_agent_ledger_running_balance() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
$$;


ALTER FUNCTION public.fn_agent_ledger_running_balance() OWNER TO jamisan_admin;

--
-- Name: fn_agent_remittance_verified_cleared(); Type: FUNCTION; Schema: public; Owner: jamisan_admin
--

CREATE FUNCTION public.fn_agent_remittance_verified_cleared() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM 'Verified_Cleared'
     AND NEW.status = 'Verified_Cleared'
  THEN
    INSERT INTO agent_ledger (
      agent_id, transaction_type, reference_id, reference_table,
      credit_amount, notes, logged_by
    ) VALUES (
      NEW.agent_id,
      'Cash_Remitted',
      NEW.id,
      'agent_remittance',
      NEW.final_amount_remitted,
      'Auto-credited on Verified_Cleared',
      NEW.verified_by
    );
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_agent_remittance_verified_cleared() OWNER TO jamisan_admin;

--
-- Name: fn_orders_stock_management(); Type: FUNCTION; Schema: public; Owner: jamisan_admin
--

CREATE FUNCTION public.fn_orders_stock_management() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  old_status text;
BEGIN
  -- On INSERT, OLD is null
  IF TG_OP = 'INSERT' THEN
    old_status := '';
  ELSE
    old_status := OLD.status;
    -- Skip if status did not change on UPDATE
    IF old_status = NEW.status THEN
      RETURN NEW;
    END IF;
  END IF;

  -- === RESERVE: entering Pending or Scheduled ===
  IF NEW.status IN ('Pending', 'Scheduled') AND old_status NOT IN ('Pending', 'Scheduled') THEN
    UPDATE inventory SET reserved = reserved + NEW.quantity, updated_at = now()
    WHERE product_id = NEW.product_id AND variant_id IS NOT DISTINCT FROM NEW.product_variant_id;

    IF NEW.has_order_bump AND NEW.order_bump_product_id IS NOT NULL THEN
      UPDATE order_bump_inventory SET reserved = reserved + COALESCE(NEW.order_bump_quantity, 0), updated_at = now()
      WHERE product_id = NEW.order_bump_product_id AND variant_id IS NOT DISTINCT FROM NEW.order_bump_variant_id;
    END IF;
  END IF;

  -- === DECREMENT: any status -> Cash Paid ===
  IF NEW.status = 'Cash Paid' AND old_status <> 'Cash Paid' THEN
    IF old_status IN ('Pending', 'Scheduled') THEN
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
      -- Late Cash Paid or direct INSERT as Cash Paid -- no reservation to release
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
  IF old_status = 'Cash Paid' AND NEW.status <> 'Cash Paid' THEN
    UPDATE inventory SET decremented = decremented - NEW.quantity, updated_at = now()
    WHERE product_id = NEW.product_id AND variant_id IS NOT DISTINCT FROM NEW.product_variant_id;

    IF NEW.has_order_bump AND NEW.order_bump_product_id IS NOT NULL THEN
      UPDATE order_bump_inventory
      SET decremented = decremented - COALESCE(NEW.order_bump_quantity, 0), updated_at = now()
      WHERE product_id = NEW.order_bump_product_id AND variant_id IS NOT DISTINCT FROM NEW.order_bump_variant_id;
    END IF;
  END IF;

  -- === RELEASE RESERVE: Pending/Scheduled -> Failed/Cancelled/Abandoned ===
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
$$;


ALTER FUNCTION public.fn_orders_stock_management() OWNER TO jamisan_admin;

--
-- Name: fn_orders_wati_export(); Type: FUNCTION; Schema: public; Owner: jamisan_admin
--

CREATE FUNCTION public.fn_orders_wati_export() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM 'Cash Paid'
     AND NEW.status = 'Cash Paid'
     AND NOT COALESCE(NEW.wati_sequence_triggered, false)
     AND NOT COALESCE(NEW.wati_suppressed, false)
  THEN
    INSERT INTO wati_export_queue (order_id) VALUES (NEW.id);
    NEW.wati_sequence_triggered := true;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_orders_wati_export() OWNER TO jamisan_admin;

--
-- Name: fn_stock_adjustments_update_stock(); Type: FUNCTION; Schema: public; Owner: jamisan_admin
--

CREATE FUNCTION public.fn_stock_adjustments_update_stock() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
$$;


ALTER FUNCTION public.fn_stock_adjustments_update_stock() OWNER TO jamisan_admin;

--
-- Name: fn_trashed_items_subtract_stock(); Type: FUNCTION; Schema: public; Owner: jamisan_admin
--

CREATE FUNCTION public.fn_trashed_items_subtract_stock() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE inventory
  SET waybill_stock = waybill_stock - NEW.quantity,
      updated_at = now()
  WHERE product_id = NEW.product_id
    AND variant_id IS NOT DISTINCT FROM NEW.variant_id;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_trashed_items_subtract_stock() OWNER TO jamisan_admin;

--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: jamisan_admin
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_updated_at_column() OWNER TO jamisan_admin;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: action_items; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.action_items (
    id integer NOT NULL,
    title character varying(200) NOT NULL,
    description text,
    assigned_to integer,
    assigned_by integer,
    status character varying(50) DEFAULT 'Open'::character varying,
    priority character varying(50) DEFAULT 'Medium'::character varying,
    due_date date,
    closed_at timestamp without time zone,
    closed_by integer,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.action_items OWNER TO jamisan_admin;

--
-- Name: COLUMN action_items.assigned_to; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.action_items.assigned_to IS 'user_id of staff member responsible';


--
-- Name: COLUMN action_items.assigned_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.action_items.assigned_by IS 'user_id of Director or Ops Manager who created it';


--
-- Name: COLUMN action_items.status; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.action_items.status IS 'Open, In Progress, Closed';


--
-- Name: COLUMN action_items.priority; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.action_items.priority IS 'Low, Medium, High, Critical';


--
-- Name: action_items_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.action_items ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.action_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: ad_expenses; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.ad_expenses (
    id integer NOT NULL,
    product_id integer,
    brand_id integer,
    campaign_name character varying(200),
    time_period character varying(100),
    amount numeric(14,2) NOT NULL,
    platform character varying(50),
    payment_method character varying(100),
    expense_date date NOT NULL,
    month character varying(20),
    year integer,
    comments text,
    receipt_url character varying(500),
    logged_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.ad_expenses OWNER TO jamisan_admin;

--
-- Name: COLUMN ad_expenses.campaign_name; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.ad_expenses.campaign_name IS 'e.g. Stretchmarks Gel ABO, Speaker CBO';


--
-- Name: COLUMN ad_expenses.time_period; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.ad_expenses.time_period IS 'e.g. January, Q1 2025, Week 3';


--
-- Name: COLUMN ad_expenses.platform; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.ad_expenses.platform IS 'Facebook, TikTok, Google etc';


--
-- Name: COLUMN ad_expenses.payment_method; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.ad_expenses.payment_method IS 'Company Card, Bank Transfer, Petty Cash';


--
-- Name: COLUMN ad_expenses.receipt_url; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.ad_expenses.receipt_url IS 'Google Drive link to screenshot from Ads Manager';


--
-- Name: ad_expenses_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.ad_expenses ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.ad_expenses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: admin_level_1; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.admin_level_1 (
    id integer NOT NULL,
    country_id integer NOT NULL,
    name character varying(100) NOT NULL,
    code character varying(20),
    is_active boolean DEFAULT true
);


ALTER TABLE public.admin_level_1 OWNER TO jamisan_admin;

--
-- Name: COLUMN admin_level_1.code; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.admin_level_1.code IS 'e.g. LA for Lagos, AB for Abuja';


--
-- Name: admin_level_1_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.admin_level_1 ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.admin_level_1_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: admin_level_2; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.admin_level_2 (
    id integer NOT NULL,
    admin_level_1_id integer NOT NULL,
    name character varying(100) NOT NULL,
    is_active boolean DEFAULT true
);


ALTER TABLE public.admin_level_2 OWNER TO jamisan_admin;

--
-- Name: admin_level_2_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.admin_level_2 ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.admin_level_2_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: agent_ledger; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.agent_ledger (
    id integer NOT NULL,
    agent_id integer NOT NULL,
    transaction_type character varying(100) NOT NULL,
    reference_id integer,
    reference_table character varying(100),
    debit_amount numeric(14,2) DEFAULT 0,
    credit_amount numeric(14,2) DEFAULT 0,
    running_balance numeric(14,2) NOT NULL,
    currency_code character varying(10) DEFAULT 'NGN'::character varying,
    notes text,
    logged_by integer,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.agent_ledger OWNER TO jamisan_admin;

--
-- Name: COLUMN agent_ledger.transaction_type; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_ledger.transaction_type IS 'Order_Delivered, Logistics_Fee_Retained, Waybill_Paid_By_Agent, Return_Fee_Retained, Cash_Remitted, Manual_Adjustment';


--
-- Name: COLUMN agent_ledger.reference_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_ledger.reference_id IS 'order_id, waybill_id, or remittance_id — links to source record';


--
-- Name: COLUMN agent_ledger.reference_table; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_ledger.reference_table IS 'orders, waybill_expenses, or agent_remittance — identifies which table reference_id points to';


--
-- Name: COLUMN agent_ledger.debit_amount; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_ledger.debit_amount IS 'Cash agent owes Jamisan';


--
-- Name: COLUMN agent_ledger.credit_amount; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_ledger.credit_amount IS 'Cash Jamisan owes agent OR cash agent remitted';


--
-- Name: COLUMN agent_ledger.running_balance; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_ledger.running_balance IS 'Calculated by trigger: previous_balance + debit_amount - credit_amount';


--
-- Name: COLUMN agent_ledger.notes; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_ledger.notes IS 'Auto-populated from source record. Manual entries require explicit reason.';


--
-- Name: COLUMN agent_ledger.logged_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_ledger.logged_by IS 'System for auto-entries. Director user_id for manual adjustments.';


--
-- Name: agent_ledger_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.agent_ledger ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.agent_ledger_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: agent_remittance; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.agent_remittance (
    id integer NOT NULL,
    agent_id integer NOT NULL,
    admin_level_1_id integer,
    amount_remitted numeric(14,2) NOT NULL,
    logistics_fee_paid numeric(14,2) DEFAULT 0,
    final_amount_remitted numeric(14,2) NOT NULL,
    remittance_date date NOT NULL,
    currency_code character varying(10) DEFAULT 'NGN'::character varying,
    status character varying(50) DEFAULT 'Pending_Bank_Verification'::character varying NOT NULL,
    logged_by integer NOT NULL,
    verified_by integer,
    verified_at timestamp without time zone,
    bank_reference character varying(200),
    actual_amount_received numeric(14,2),
    variance_amount numeric(14,2),
    variance_reason_id integer,
    dispute_notes text,
    month character varying(20),
    year integer,
    comments text,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.agent_remittance OWNER TO jamisan_admin;

--
-- Name: COLUMN agent_remittance.admin_level_1_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_remittance.admin_level_1_id IS 'State the remittance covers';


--
-- Name: COLUMN agent_remittance.amount_remitted; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_remittance.amount_remitted IS 'Raw cash received from agent';


--
-- Name: COLUMN agent_remittance.logistics_fee_paid; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_remittance.logistics_fee_paid IS 'Logistics fee deducted from remittance';


--
-- Name: COLUMN agent_remittance.final_amount_remitted; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_remittance.final_amount_remitted IS 'amount_remitted - logistics_fee_paid';


--
-- Name: COLUMN agent_remittance.currency_code; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_remittance.currency_code IS 'NGN for Nigeria, GHS for Ghana etc';


--
-- Name: COLUMN agent_remittance.status; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_remittance.status IS 'Pending_Bank_Verification, Verified_Cleared, Disputed';


--
-- Name: COLUMN agent_remittance.logged_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_remittance.logged_by IS 'Ops Manager user_id who logged the remittance';


--
-- Name: COLUMN agent_remittance.verified_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_remittance.verified_by IS 'Accountant user_id who verified against bank statement';


--
-- Name: COLUMN agent_remittance.verified_at; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_remittance.verified_at IS 'When Accountant clicked Verified and Cleared';


--
-- Name: COLUMN agent_remittance.bank_reference; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_remittance.bank_reference IS 'Bank transfer reference number — added by Accountant on verification';


--
-- Name: COLUMN agent_remittance.actual_amount_received; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_remittance.actual_amount_received IS 'Actual amount seen in bank statement — may differ from amount_remitted';


--
-- Name: COLUMN agent_remittance.variance_amount; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_remittance.variance_amount IS 'actual_amount_received - final_amount_remitted. Negative = shortage, positive = overpayment';


--
-- Name: COLUMN agent_remittance.variance_reason_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_remittance.variance_reason_id IS 'Reason for variance — from remittance_variance_reason_codes table';


--
-- Name: COLUMN agent_remittance.dispute_notes; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_remittance.dispute_notes IS 'Populated when Accountant flags a discrepancy';


--
-- Name: agent_remittance_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.agent_remittance ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.agent_remittance_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: agent_zone_assignments; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.agent_zone_assignments (
    id integer NOT NULL,
    admin_level_1_id integer NOT NULL,
    admin_level_2_id integer,
    primary_agent_id integer NOT NULL,
    overflow_agent_id integer,
    dispatch_rule character varying(50) DEFAULT 'direct_assign'::character varying NOT NULL,
    zone_belt character varying(100),
    notes text,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.agent_zone_assignments OWNER TO jamisan_admin;

--
-- Name: COLUMN agent_zone_assignments.admin_level_1_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_zone_assignments.admin_level_1_id IS 'State';


--
-- Name: COLUMN agent_zone_assignments.admin_level_2_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_zone_assignments.admin_level_2_id IS 'LGA — null means entire state';


--
-- Name: COLUMN agent_zone_assignments.overflow_agent_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_zone_assignments.overflow_agent_id IS 'Activated when primary agent unavailable';


--
-- Name: COLUMN agent_zone_assignments.dispatch_rule; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_zone_assignments.dispatch_rule IS 'direct_assign, round_robin, overflow_only';


--
-- Name: COLUMN agent_zone_assignments.zone_belt; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_zone_assignments.zone_belt IS 'Western, Eastern, Northern, Metro etc';


--
-- Name: COLUMN agent_zone_assignments.notes; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agent_zone_assignments.notes IS 'Routing rationale and special instructions';


--
-- Name: agent_zone_assignments_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.agent_zone_assignments ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.agent_zone_assignments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: agents; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.agents (
    id integer NOT NULL,
    name character varying(200) NOT NULL,
    contact_name character varying(200),
    phone character varying(20),
    email character varying(200),
    address text,
    city character varying(100),
    admin_level_1_id integer,
    admin_level_2_id integer,
    bank_name character varying(100),
    account_number character varying(50),
    account_name character varying(200),
    status character varying(50) DEFAULT 'Active'::character varying,
    ratings numeric(3,1),
    restrictions text,
    source character varying(200),
    whatsapp_group_name character varying(200),
    whatsapp_group_link character varying(255),
    comments text,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.agents OWNER TO jamisan_admin;

--
-- Name: COLUMN agents.name; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agents.name IS 'Company name e.g. Parcel Exchange, RGMARTZ';


--
-- Name: COLUMN agents.contact_name; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agents.contact_name IS 'Individual contact at the agent company';


--
-- Name: COLUMN agents.admin_level_1_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agents.admin_level_1_id IS 'Primary state of operation';


--
-- Name: COLUMN agents.admin_level_2_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agents.admin_level_2_id IS 'Agent warehouse LGA';


--
-- Name: COLUMN agents.status; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agents.status IS 'Active, Inactive';


--
-- Name: COLUMN agents.ratings; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agents.ratings IS 'Performance score out of 5';


--
-- Name: COLUMN agents.restrictions; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agents.restrictions IS 'Any delivery restrictions for this agent';


--
-- Name: COLUMN agents.source; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agents.source IS 'How agent was recruited';


--
-- Name: COLUMN agents.whatsapp_group_name; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agents.whatsapp_group_name IS 'Name of the WhatsApp group for this agent e.g. Shanoma Logistics Jamisan';


--
-- Name: COLUMN agents.whatsapp_group_link; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.agents.whatsapp_group_link IS 'WhatsApp group invite link for CSR copy-paste routing';


--
-- Name: agents_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.agents ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.agents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.audit_log (
    id integer NOT NULL,
    user_id integer,
    action character varying(100) NOT NULL,
    table_name character varying(100),
    record_id integer,
    old_value text,
    new_value text,
    ip_address character varying(50),
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.audit_log OWNER TO jamisan_admin;

--
-- Name: COLUMN audit_log.action; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.audit_log.action IS 'e.g. edit_order, delete_order, login, export_csv';


--
-- Name: COLUMN audit_log.table_name; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.audit_log.table_name IS 'Which table was affected';


--
-- Name: COLUMN audit_log.record_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.audit_log.record_id IS 'Which record was affected';


--
-- Name: COLUMN audit_log.old_value; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.audit_log.old_value IS 'JSON snapshot of record before change';


--
-- Name: COLUMN audit_log.new_value; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.audit_log.new_value IS 'JSON snapshot of record after change';


--
-- Name: audit_log_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.audit_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.audit_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auditor_check_categories; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.auditor_check_categories (
    id integer NOT NULL,
    code character varying(100) NOT NULL,
    description character varying(200) NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.auditor_check_categories OWNER TO jamisan_admin;

--
-- Name: auditor_check_categories_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.auditor_check_categories ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auditor_check_categories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auditor_spot_checks; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.auditor_spot_checks (
    id integer NOT NULL,
    order_id integer NOT NULL,
    auditor_id integer NOT NULL,
    check_date date DEFAULT CURRENT_DATE NOT NULL,
    check_category_id integer NOT NULL,
    result character varying(50) NOT NULL,
    auditor_notes text,
    escalated_to_director boolean DEFAULT false,
    director_reviewed_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.auditor_spot_checks OWNER TO jamisan_admin;

--
-- Name: COLUMN auditor_spot_checks.result; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.auditor_spot_checks.result IS 'Pass, Flagged';


--
-- Name: auditor_spot_checks_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.auditor_spot_checks ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auditor_spot_checks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: backup_log; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.backup_log (
    id integer NOT NULL,
    backup_type character varying(50) NOT NULL,
    file_name character varying(200),
    file_size_mb numeric(8,2),
    status character varying(50) NOT NULL,
    started_at timestamp without time zone NOT NULL,
    completed_at timestamp without time zone,
    error_message text,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.backup_log OWNER TO jamisan_admin;

--
-- Name: COLUMN backup_log.backup_type; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.backup_log.backup_type IS 'local, offsite';


--
-- Name: COLUMN backup_log.status; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.backup_log.status IS 'Success, Failed, In Progress';


--
-- Name: backup_log_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.backup_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.backup_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: brands; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.brands (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    department_id integer NOT NULL,
    niche_id integer NOT NULL,
    is_active boolean DEFAULT true
);


ALTER TABLE public.brands OWNER TO jamisan_admin;

--
-- Name: brands_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.brands ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.brands_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: orders; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.orders (
    id integer NOT NULL,
    order_id character varying(100) NOT NULL,
    row_number integer,
    ordered_at timestamp without time zone NOT NULL,
    order_time character varying(20),
    scheduled_date date,
    date_paid date,
    first_contact_at timestamp without time zone,
    source_id integer,
    assigned_csr_id integer NOT NULL,
    department_id integer NOT NULL,
    brand_id integer,
    country_id integer DEFAULT 1 NOT NULL,
    customer_id integer,
    customer_name character varying(200) NOT NULL,
    phone_number character varying(20) NOT NULL,
    other_phone character varying(20),
    email character varying(200),
    sex character varying(20),
    is_return_customer boolean DEFAULT false,
    admin_level_1_id integer,
    admin_level_2_id integer,
    city character varying(200),
    full_address text,
    status character varying(100) DEFAULT 'Interested'::character varying NOT NULL,
    comments text,
    failure_reason_id integer,
    product_id integer NOT NULL,
    product_variant_id integer,
    quantity integer DEFAULT 1 NOT NULL,
    price numeric(12,2) NOT NULL,
    currency_code character varying(10) DEFAULT 'NGN'::character varying,
    has_order_bump boolean DEFAULT false,
    order_bump_product_id integer,
    order_bump_variant_id integer,
    order_bump_quantity integer DEFAULT 0,
    order_bump_price numeric(12,2) DEFAULT 0,
    order_bump_type character varying(100),
    agent_id integer,
    logistics_fee numeric(12,2),
    shipping_type_id integer,
    niche_id integer,
    wati_sequence_triggered boolean DEFAULT false,
    wati_suppressed boolean DEFAULT false,
    api_batch_id character varying(100),
    late_cash_paid boolean DEFAULT false,
    is_test boolean DEFAULT false,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.orders OWNER TO jamisan_admin;

--
-- Name: COLUMN orders.order_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.order_id IS 'Auto-generated e.g. CJAM1000. C=CRM, JAM=Jamisan, number increments from 1000';


--
-- Name: COLUMN orders.row_number; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.row_number IS 'Sequential display number — mirrors # column in Google Sheets';


--
-- Name: COLUMN orders.ordered_at; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.ordered_at IS 'Date and time order was placed';


--
-- Name: COLUMN orders.order_time; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.order_time IS 'Time string from Jamisan Form';


--
-- Name: COLUMN orders.scheduled_date; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.scheduled_date IS 'For customers who request a callback or later delivery';


--
-- Name: COLUMN orders.date_paid; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.date_paid IS 'Date customer payment was confirmed';


--
-- Name: COLUMN orders.first_contact_at; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.first_contact_at IS 'Auto-stamped when CSR first updates status from Interested';


--
-- Name: COLUMN orders.source_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.source_id IS 'Jamisan Form, WhatsApp Form, Social Media';


--
-- Name: COLUMN orders.assigned_csr_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.assigned_csr_id IS 'Set by Pabbly on order creation';


--
-- Name: COLUMN orders.department_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.department_id IS 'Inherited from product via brand';


--
-- Name: COLUMN orders.brand_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.brand_id IS 'Brand source of the order';


--
-- Name: COLUMN orders.country_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.country_id IS 'Defaults to Nigeria';


--
-- Name: COLUMN orders.customer_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.customer_id IS 'Links to customers table via phone_number lookup';


--
-- Name: COLUMN orders.phone_number; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.phone_number IS 'Auto-formatted to +234XXXXXXXXXX';


--
-- Name: COLUMN orders.other_phone; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.other_phone IS 'Auto-formatted to +234XXXXXXXXXX';


--
-- Name: COLUMN orders.sex; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.sex IS 'Male, Female, Undefined — set by CSR';


--
-- Name: COLUMN orders.is_return_customer; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.is_return_customer IS 'Auto-set by CRM on order creation';


--
-- Name: COLUMN orders.admin_level_1_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.admin_level_1_id IS 'State — drives agent dropdown filter';


--
-- Name: COLUMN orders.admin_level_2_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.admin_level_2_id IS 'LGA — cascades from state selection';


--
-- Name: COLUMN orders.status; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.status IS 'One of 32 statuses. See spec Day 1 Section 4.';


--
-- Name: COLUMN orders.comments; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.comments IS 'CSR adds context when updating status';


--
-- Name: COLUMN orders.failure_reason_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.failure_reason_id IS 'Mandatory for Failed, Cancelled, Returned orders — cannot be blank';


--
-- Name: COLUMN orders.product_variant_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.product_variant_id IS 'Colour selected';


--
-- Name: COLUMN orders.price; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.price IS 'Editable if customer haggles — reason logged in comments';


--
-- Name: COLUMN orders.order_bump_product_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.order_bump_product_id IS 'Order Bump product if applicable';


--
-- Name: COLUMN orders.order_bump_variant_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.order_bump_variant_id IS 'Order Bump colour';


--
-- Name: COLUMN orders.order_bump_price; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.order_bump_price IS 'Editable price for order bump — may differ from product default price. Required for P&L and Copy Order clipboard.';


--
-- Name: COLUMN orders.order_bump_type; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.order_bump_type IS 'Physical or Digital — determines stock deduction logic';


--
-- Name: COLUMN orders.agent_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.agent_id IS 'Assigned by CSR from state-filtered dropdown';


--
-- Name: COLUMN orders.logistics_fee; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.logistics_fee IS 'Delivery fee — logged by CSR after agent confirms';


--
-- Name: COLUMN orders.niche_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.niche_id IS 'Inherited from brand — for reporting';


--
-- Name: COLUMN orders.wati_sequence_triggered; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.wati_sequence_triggered IS 'True when order exported to Cash Paid sheet';


--
-- Name: COLUMN orders.wati_suppressed; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.wati_suppressed IS 'Set true when complaint or refund logged against this order';


--
-- Name: COLUMN orders.api_batch_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.api_batch_id IS 'Pabbly webhook batch ID — traces Round-Robin assignment back to exact webhook payload for debugging. Shown in right panel Part B of slide-out panel.';


--
-- Name: COLUMN orders.late_cash_paid; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.late_cash_paid IS 'Set true when order transitions Abandoned → Cash Paid. Signals CSR neglect or agent delivering outside 72hr SLA. Visible in Auditor Rapid Fail queue and Director dashboard.';


--
-- Name: COLUMN orders.is_test; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.orders.is_test IS 'Test orders filtered from all reports';


--
-- Name: cjam_order_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

CREATE SEQUENCE public.cjam_order_seq
    START WITH 1000
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.cjam_order_seq OWNER TO jamisan_admin;

--
-- Name: cjam_order_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jamisan_admin
--

ALTER SEQUENCE public.cjam_order_seq OWNED BY public.orders.order_id;


--
-- Name: commission_tiers; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.commission_tiers (
    id integer NOT NULL,
    department_id integer NOT NULL,
    payment_rate_min numeric(5,2) NOT NULL,
    payment_rate_max numeric(5,2),
    commission_per_unit numeric(10,2) NOT NULL,
    is_active boolean DEFAULT true,
    notes text
);


ALTER TABLE public.commission_tiers OWNER TO jamisan_admin;

--
-- Name: COLUMN commission_tiers.payment_rate_min; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.commission_tiers.payment_rate_min IS 'Lower bound e.g. 40.00';


--
-- Name: COLUMN commission_tiers.payment_rate_max; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.commission_tiers.payment_rate_max IS 'Upper bound — null means no ceiling';


--
-- Name: COLUMN commission_tiers.commission_per_unit; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.commission_tiers.commission_per_unit IS 'Naira per paid unit';


--
-- Name: COLUMN commission_tiers.notes; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.commission_tiers.notes IS 'e.g. Transition period for gadgets';


--
-- Name: commission_tiers_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.commission_tiers ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.commission_tiers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: complaints; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.complaints (
    id integer NOT NULL,
    order_id integer NOT NULL,
    customer_id integer NOT NULL,
    assigned_csr_id integer,
    complaint_type character varying(100),
    description text NOT NULL,
    resolution text,
    refund_amount numeric(12,2) DEFAULT 0,
    date_of_complaint date,
    replaced_or_refunded boolean DEFAULT false,
    cost_of_return numeric(12,2) DEFAULT 0,
    total_cost numeric(12,2),
    date_of_return date,
    status character varying(50) DEFAULT 'Open'::character varying,
    logged_at timestamp without time zone DEFAULT now(),
    resolved_at timestamp without time zone,
    resolved_by integer,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.complaints OWNER TO jamisan_admin;

--
-- Name: COLUMN complaints.assigned_csr_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.complaints.assigned_csr_id IS 'CSR who logged the complaint';


--
-- Name: COLUMN complaints.complaint_type; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.complaints.complaint_type IS 'Wrong Product, Late Delivery, Damaged Item, Other';


--
-- Name: COLUMN complaints.resolution; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.complaints.resolution IS 'How it was resolved';


--
-- Name: COLUMN complaints.refund_amount; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.complaints.refund_amount IS 'Amount refunded if applicable';


--
-- Name: COLUMN complaints.total_cost; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.complaints.total_cost IS 'cost_of_return + refund_amount';


--
-- Name: COLUMN complaints.status; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.complaints.status IS 'Open, Resolved, Escalated';


--
-- Name: COLUMN complaints.resolved_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.complaints.resolved_by IS 'user_id of CSR or Director who resolved';


--
-- Name: complaints_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.complaints ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.complaints_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: countries; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.countries (
    id integer NOT NULL,
    country_code character varying(10) NOT NULL,
    country_name character varying(100) NOT NULL,
    admin_level_1_label character varying(50) NOT NULL,
    admin_level_2_label character varying(50) NOT NULL,
    phone_code character varying(10) NOT NULL,
    currency_code character varying(10) NOT NULL,
    timezone character varying(50) NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.countries OWNER TO jamisan_admin;

--
-- Name: COLUMN countries.country_code; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.countries.country_code IS 'ISO code e.g. NG, GH, KE';


--
-- Name: COLUMN countries.admin_level_1_label; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.countries.admin_level_1_label IS 'State for Nigeria, Region for Ghana';


--
-- Name: COLUMN countries.admin_level_2_label; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.countries.admin_level_2_label IS 'LGA for Nigeria, District for Ghana';


--
-- Name: COLUMN countries.phone_code; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.countries.phone_code IS '+234 for Nigeria, +233 for Ghana';


--
-- Name: COLUMN countries.currency_code; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.countries.currency_code IS 'NGN, GHS, KES etc';


--
-- Name: COLUMN countries.timezone; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.countries.timezone IS 'Africa/Lagos, Africa/Accra etc';


--
-- Name: countries_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.countries ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.countries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: csr_level_history; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.csr_level_history (
    id integer NOT NULL,
    user_id integer NOT NULL,
    previous_level integer,
    new_level integer NOT NULL,
    changed_at timestamp without time zone DEFAULT now(),
    changed_by integer,
    reason text
);


ALTER TABLE public.csr_level_history OWNER TO jamisan_admin;

--
-- Name: COLUMN csr_level_history.changed_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.csr_level_history.changed_by IS 'Director or Ops Manager user_id for manual changes. NULL for automated promotions triggered by csr_promotion_thresholds.';


--
-- Name: COLUMN csr_level_history.reason; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.csr_level_history.reason IS 'Grace provision applied, sustained performance etc';


--
-- Name: csr_level_history_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.csr_level_history ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.csr_level_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: csr_levels; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.csr_levels (
    id integer NOT NULL,
    level_number integer NOT NULL,
    level_name character varying(50) NOT NULL,
    base_salary numeric(12,2) NOT NULL,
    description text,
    is_active boolean DEFAULT true
);


ALTER TABLE public.csr_levels OWNER TO jamisan_admin;

--
-- Name: COLUMN csr_levels.level_number; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.csr_levels.level_number IS '1 through 5';


--
-- Name: COLUMN csr_levels.level_name; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.csr_levels.level_name IS 'Level 1, Level 2 etc';


--
-- Name: COLUMN csr_levels.base_salary; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.csr_levels.base_salary IS 'L1=100k L2=150k L3=180k L4=220k L5=270k';


--
-- Name: csr_levels_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.csr_levels ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.csr_levels_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: csr_performance_monthly; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.csr_performance_monthly (
    id integer NOT NULL,
    user_id integer NOT NULL,
    department_id integer NOT NULL,
    month character varying(20) NOT NULL,
    year integer NOT NULL,
    total_orders integer DEFAULT 0,
    total_units_ordered integer DEFAULT 0,
    total_units_paid integer DEFAULT 0,
    payment_rate numeric(5,2) DEFAULT 0,
    commission_tier_id integer,
    commission_per_unit numeric(10,2) DEFAULT 0,
    total_commission numeric(12,2) DEFAULT 0,
    base_salary numeric(12,2) DEFAULT 0,
    total_compensation numeric(12,2) DEFAULT 0,
    csr_level_at_time integer,
    is_finalised boolean DEFAULT false,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.csr_performance_monthly OWNER TO jamisan_admin;

--
-- Name: COLUMN csr_performance_monthly.total_units_paid; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.csr_performance_monthly.total_units_paid IS 'Cash Paid orders only';


--
-- Name: COLUMN csr_performance_monthly.payment_rate; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.csr_performance_monthly.payment_rate IS 'total_units_paid / total_units_ordered * 100';


--
-- Name: COLUMN csr_performance_monthly.commission_tier_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.csr_performance_monthly.commission_tier_id IS 'Which tier applied this month';


--
-- Name: COLUMN csr_performance_monthly.total_compensation; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.csr_performance_monthly.total_compensation IS 'base_salary + total_commission';


--
-- Name: COLUMN csr_performance_monthly.csr_level_at_time; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.csr_performance_monthly.csr_level_at_time IS 'Level CSR was at during this month';


--
-- Name: COLUMN csr_performance_monthly.is_finalised; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.csr_performance_monthly.is_finalised IS 'Locked once payroll is processed';


--
-- Name: csr_performance_monthly_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.csr_performance_monthly ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.csr_performance_monthly_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: csr_promotion_thresholds; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.csr_promotion_thresholds (
    id integer NOT NULL,
    department_id integer NOT NULL,
    from_level integer NOT NULL,
    to_level integer NOT NULL,
    direction character varying(10) NOT NULL,
    payment_rate_threshold numeric(5,2) NOT NULL,
    consecutive_months_required integer NOT NULL,
    is_active boolean DEFAULT true
);


ALTER TABLE public.csr_promotion_thresholds OWNER TO jamisan_admin;

--
-- Name: COLUMN csr_promotion_thresholds.from_level; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.csr_promotion_thresholds.from_level IS 'Current level';


--
-- Name: COLUMN csr_promotion_thresholds.to_level; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.csr_promotion_thresholds.to_level IS 'Target level';


--
-- Name: COLUMN csr_promotion_thresholds.direction; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.csr_promotion_thresholds.direction IS 'promotion or demotion';


--
-- Name: COLUMN csr_promotion_thresholds.consecutive_months_required; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.csr_promotion_thresholds.consecutive_months_required IS '3 for promotion, 2 for demotion';


--
-- Name: csr_promotion_thresholds_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.csr_promotion_thresholds ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.csr_promotion_thresholds_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: customers; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.customers (
    id integer NOT NULL,
    phone_number character varying(20) NOT NULL,
    other_phone character varying(20),
    full_name character varying(200),
    email character varying(200),
    sex character varying(20),
    first_order_date timestamp without time zone,
    last_order_date timestamp without time zone,
    total_orders integer DEFAULT 0,
    total_purchases integer DEFAULT 0,
    lifetime_value numeric(14,2) DEFAULT 0,
    customer_tag character varying(50) DEFAULT 'new'::character varying,
    is_banned boolean DEFAULT false,
    ban_reason text,
    banned_at timestamp without time zone,
    banned_by integer,
    csr_notes text,
    wati_opted_out boolean DEFAULT false,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.customers OWNER TO jamisan_admin;

--
-- Name: COLUMN customers.phone_number; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.customers.phone_number IS 'Primary identifier. Format: +234XXXXXXXXXX';


--
-- Name: COLUMN customers.sex; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.customers.sex IS 'Male, Female, Undefined';


--
-- Name: COLUMN customers.total_orders; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.customers.total_orders IS 'All orders ever placed';


--
-- Name: COLUMN customers.total_purchases; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.customers.total_purchases IS 'Cash Paid orders only';


--
-- Name: COLUMN customers.lifetime_value; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.customers.lifetime_value IS 'Total amount paid across all orders';


--
-- Name: COLUMN customers.customer_tag; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.customers.customer_tag IS 'new, ordered_not_bought, bought';


--
-- Name: COLUMN customers.banned_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.customers.banned_by IS 'user_id of Director or CSR who set the ban';


--
-- Name: COLUMN customers.csr_notes; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.customers.csr_notes IS 'Freeform notes at customer level — separate from order comments';


--
-- Name: COLUMN customers.wati_opted_out; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.customers.wati_opted_out IS 'Reset to false on new order';


--
-- Name: customers_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.customers ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.customers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: department_targets; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.department_targets (
    id integer NOT NULL,
    department_id integer NOT NULL,
    base_conversion_rate numeric(5,2) NOT NULL,
    target_conversion_rate numeric(5,2) NOT NULL,
    planned_sales_rate numeric(5,2) DEFAULT 70 NOT NULL,
    effective_from date NOT NULL,
    set_by integer NOT NULL,
    notes text,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.department_targets OWNER TO jamisan_admin;

--
-- Name: COLUMN department_targets.department_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.department_targets.department_id IS 'NOT unique — multiple rows per department allowed for historical tracking. Query uses effective_from to get the active rate at any point in time.';


--
-- Name: COLUMN department_targets.base_conversion_rate; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.department_targets.base_conversion_rate IS 'Minimum acceptable rate e.g. 35.00 for Gadgets';


--
-- Name: COLUMN department_targets.target_conversion_rate; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.department_targets.target_conversion_rate IS 'Strong performer rate e.g. 40.00 for Gadgets';


--
-- Name: COLUMN department_targets.planned_sales_rate; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.department_targets.planned_sales_rate IS 'Used for Planned Sales calc on CSR report. Was hardcoded 70% in Google Sheets.';


--
-- Name: COLUMN department_targets.effective_from; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.department_targets.effective_from IS 'When this target set came into effect';


--
-- Name: COLUMN department_targets.set_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.department_targets.set_by IS 'Director who set the targets';


--
-- Name: COLUMN department_targets.notes; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.department_targets.notes IS 'Reason for target change if applicable';


--
-- Name: department_targets_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.department_targets ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.department_targets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: departments; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.departments (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.departments OWNER TO jamisan_admin;

--
-- Name: departments_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.departments ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.departments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: employee_profiles; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.employee_profiles (
    id integer NOT NULL,
    user_id integer NOT NULL,
    date_of_birth date,
    date_of_employment date,
    contact_address text,
    gender character varying(20),
    marital_status character varying(50),
    nationality character varying(100),
    state_of_origin character varying(100),
    lga_of_origin character varying(100),
    languages_spoken character varying(200),
    nin character varying(255),
    drivers_license character varying(100),
    tax_id character varying(100),
    next_of_kin_name character varying(200),
    next_of_kin_relationship character varying(100),
    next_of_kin_phone character varying(20),
    next_of_kin_address text,
    emergency_contact_name character varying(200),
    emergency_contact_relationship character varying(100),
    emergency_contact_phone_1 character varying(20),
    emergency_contact_phone_2 character varying(20),
    emergency_contact_address text,
    medical_conditions text,
    main_bank_name character varying(100),
    main_account_number character varying(255),
    main_account_type character varying(50),
    alternate_bank_name character varying(100),
    alternate_account_number character varying(255),
    alternate_account_type character varying(50),
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.employee_profiles OWNER TO jamisan_admin;

--
-- Name: COLUMN employee_profiles.nin; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.employee_profiles.nin IS 'ENCRYPTED AT REST — use pgcrypto or app-level encryption before storing';


--
-- Name: COLUMN employee_profiles.medical_conditions; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.employee_profiles.medical_conditions IS 'ENCRYPTED AT REST — sensitive health information';


--
-- Name: COLUMN employee_profiles.main_account_number; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.employee_profiles.main_account_number IS 'ENCRYPTED AT REST — financial PII';


--
-- Name: COLUMN employee_profiles.main_account_type; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.employee_profiles.main_account_type IS 'Savings or Current';


--
-- Name: COLUMN employee_profiles.alternate_account_number; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.employee_profiles.alternate_account_number IS 'ENCRYPTED AT REST — financial PII';


--
-- Name: employee_profiles_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.employee_profiles ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.employee_profiles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: escalation_reason_codes; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.escalation_reason_codes (
    id integer NOT NULL,
    code character varying(100) NOT NULL,
    description character varying(200) NOT NULL,
    is_active boolean DEFAULT true,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.escalation_reason_codes OWNER TO jamisan_admin;

--
-- Name: COLUMN escalation_reason_codes.created_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.escalation_reason_codes.created_by IS 'Director user_id — Directors manage these codes';


--
-- Name: escalation_reason_codes_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.escalation_reason_codes ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.escalation_reason_codes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: expense_categories; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.expense_categories (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    is_system_reserved boolean DEFAULT false,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.expense_categories OWNER TO jamisan_admin;

--
-- Name: COLUMN expense_categories.is_system_reserved; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.expense_categories.is_system_reserved IS 'If true, only automated processes can write to this category. Not shown in manual expense dropdown.';


--
-- Name: expense_categories_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.expense_categories ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.expense_categories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: expenses; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.expenses (
    id integer NOT NULL,
    expense_category_id integer NOT NULL,
    description text,
    amount numeric(14,2) NOT NULL,
    expense_date date NOT NULL,
    currency_code character varying(10) DEFAULT 'NGN'::character varying,
    month character varying(20),
    year integer,
    product_id integer,
    agent_id integer,
    admin_level_1_id integer,
    batch character varying(100),
    comments text,
    receipt_url character varying(500),
    logged_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.expenses OWNER TO jamisan_admin;

--
-- Name: COLUMN expenses.product_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.expenses.product_id IS 'If expense is tied to a specific product';


--
-- Name: COLUMN expenses.agent_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.expenses.agent_id IS 'If expense is tied to a specific agent';


--
-- Name: COLUMN expenses.admin_level_1_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.expenses.admin_level_1_id IS 'If expense is tied to a specific state';


--
-- Name: COLUMN expenses.batch; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.expenses.batch IS 'If expense is tied to a procurement batch';


--
-- Name: COLUMN expenses.receipt_url; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.expenses.receipt_url IS 'Google Drive shareable link to receipt — Accountant uploads to Drive, pastes link here';


--
-- Name: expenses_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.expenses ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.expenses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: failure_reason_codes; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.failure_reason_codes (
    id integer NOT NULL,
    code character varying(50) NOT NULL,
    description character varying(200) NOT NULL,
    applies_to_status character varying(100),
    is_active boolean DEFAULT true
);


ALTER TABLE public.failure_reason_codes OWNER TO jamisan_admin;

--
-- Name: COLUMN failure_reason_codes.description; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.failure_reason_codes.description IS 'e.g. Customer Refused, Wrong Address, Unreachable';


--
-- Name: COLUMN failure_reason_codes.applies_to_status; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.failure_reason_codes.applies_to_status IS 'Failed, Cancelled, Returned etc';


--
-- Name: failure_reason_codes_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.failure_reason_codes ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.failure_reason_codes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: goods_movement; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.goods_movement (
    id integer NOT NULL,
    product_id integer NOT NULL,
    variant_id integer,
    quantity integer NOT NULL,
    movement_type character varying(50) NOT NULL,
    from_agent_id integer,
    to_agent_id integer,
    admin_level_1_id integer,
    shipping_type_id integer,
    movement_date date NOT NULL,
    batch character varying(100),
    month character varying(20),
    year integer,
    comments text,
    logged_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.goods_movement OWNER TO jamisan_admin;

--
-- Name: COLUMN goods_movement.movement_type; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.goods_movement.movement_type IS 'Sent, Returned, Waybill';


--
-- Name: COLUMN goods_movement.from_agent_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.goods_movement.from_agent_id IS 'Null means Jamisan warehouse is the source';


--
-- Name: COLUMN goods_movement.to_agent_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.goods_movement.to_agent_id IS 'Null means returning to Jamisan warehouse';


--
-- Name: COLUMN goods_movement.admin_level_1_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.goods_movement.admin_level_1_id IS 'State goods moved to or from';


--
-- Name: goods_movement_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.goods_movement ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.goods_movement_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: inventory; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.inventory (
    id integer NOT NULL,
    product_id integer NOT NULL,
    variant_id integer,
    waybill_stock integer DEFAULT 0 NOT NULL,
    reserved integer DEFAULT 0 NOT NULL,
    decremented integer DEFAULT 0 NOT NULL,
    batch character varying(100),
    updated_at timestamp without time zone DEFAULT now(),
    available integer GENERATED ALWAYS AS (((waybill_stock - reserved) - decremented)) STORED,
    CONSTRAINT chk_inventory_available_non_negative CHECK ((available >= 0))
);


ALTER TABLE public.inventory OWNER TO jamisan_admin;

--
-- Name: COLUMN inventory.waybill_stock; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.inventory.waybill_stock IS 'Total stock received from supplier';


--
-- Name: COLUMN inventory.reserved; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.inventory.reserved IS 'Soft allocated — order status is Pending';


--
-- Name: COLUMN inventory.decremented; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.inventory.decremented IS 'Permanently removed — order status is Cash Paid';


--
-- Name: COLUMN inventory.batch; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.inventory.batch IS 'Batch One, Batch Two etc';


--
-- Name: inventory_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.inventory ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.inventory_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: investment_inflow; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.investment_inflow (
    id integer NOT NULL,
    amount numeric(14,2) NOT NULL,
    inflow_date date NOT NULL,
    currency_code character varying(10) DEFAULT 'NGN'::character varying,
    month character varying(20),
    year integer,
    comments text,
    logged_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.investment_inflow OWNER TO jamisan_admin;

--
-- Name: COLUMN investment_inflow.comments; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.investment_inflow.comments IS 'e.g. Investment Inflow from Director';


--
-- Name: COLUMN investment_inflow.logged_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.investment_inflow.logged_by IS 'Director user_id';


--
-- Name: investment_inflow_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.investment_inflow ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.investment_inflow_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: lesson_categories; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.lesson_categories (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    is_active boolean DEFAULT true,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.lesson_categories OWNER TO jamisan_admin;

--
-- Name: COLUMN lesson_categories.name; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.lesson_categories.name IS 'Sales Script, Logistics Warning, CRM SOP, Fraud Prevention, Other';


--
-- Name: COLUMN lesson_categories.created_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.lesson_categories.created_by IS 'Director user_id';


--
-- Name: lesson_categories_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.lesson_categories ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.lesson_categories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: lessons_learned; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.lessons_learned (
    id integer NOT NULL,
    title character varying(300) NOT NULL,
    content text NOT NULL,
    category_id integer NOT NULL,
    submitted_by integer NOT NULL,
    status character varying(50) DEFAULT 'Pending'::character varying NOT NULL,
    rejection_reason text,
    reviewed_by integer,
    reviewed_at timestamp without time zone,
    published_at timestamp without time zone,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.lessons_learned OWNER TO jamisan_admin;

--
-- Name: COLUMN lessons_learned.content; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.lessons_learned.content IS 'Rich text — sales scripts, SOPs, warnings, tactics';


--
-- Name: COLUMN lessons_learned.submitted_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.lessons_learned.submitted_by IS 'Any staff member — user_id';


--
-- Name: COLUMN lessons_learned.status; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.lessons_learned.status IS 'Pending, Published, Rejected';


--
-- Name: COLUMN lessons_learned.rejection_reason; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.lessons_learned.rejection_reason IS 'Director must provide reason if rejecting';


--
-- Name: COLUMN lessons_learned.reviewed_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.lessons_learned.reviewed_by IS 'Director user_id';


--
-- Name: lessons_learned_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.lessons_learned ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.lessons_learned_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: loans; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.loans (
    id integer NOT NULL,
    amount numeric(14,2) NOT NULL,
    loan_date date NOT NULL,
    currency_code character varying(10) DEFAULT 'NGN'::character varying,
    lender character varying(200),
    repayment_status character varying(50) DEFAULT 'Outstanding'::character varying,
    amount_repaid numeric(14,2) DEFAULT 0,
    due_date date,
    month character varying(20),
    year integer,
    comments text,
    logged_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.loans OWNER TO jamisan_admin;

--
-- Name: COLUMN loans.repayment_status; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.loans.repayment_status IS 'Outstanding, Partially Paid, Fully Paid';


--
-- Name: loans_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.loans ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.loans_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: niches; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.niches (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    is_active boolean DEFAULT true
);


ALTER TABLE public.niches OWNER TO jamisan_admin;

--
-- Name: niches_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.niches ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.niches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.notifications (
    id integer NOT NULL,
    notification_type character varying(100) NOT NULL,
    channel character varying(50) NOT NULL,
    recipient_type character varying(50) NOT NULL,
    recipient_user_id integer,
    recipient_agent_id integer,
    subject character varying(200),
    message text,
    status character varying(50) DEFAULT 'Sent'::character varying,
    sent_at timestamp without time zone DEFAULT now(),
    error_message text
);


ALTER TABLE public.notifications OWNER TO jamisan_admin;

--
-- Name: COLUMN notifications.notification_type; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.notifications.notification_type IS 'csr_alert, login_alert, agent_summary, daily_hygiene, abandoned_instant';


--
-- Name: COLUMN notifications.channel; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.notifications.channel IS 'email, whatsapp, internal';


--
-- Name: COLUMN notifications.recipient_type; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.notifications.recipient_type IS 'user, agent';


--
-- Name: COLUMN notifications.recipient_user_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.notifications.recipient_user_id IS 'If sent to a staff member';


--
-- Name: COLUMN notifications.recipient_agent_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.notifications.recipient_agent_id IS 'If sent to an agent';


--
-- Name: COLUMN notifications.status; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.notifications.status IS 'Sent, Failed, Pending';


--
-- Name: COLUMN notifications.error_message; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.notifications.error_message IS 'If status is Failed, reason stored here';


--
-- Name: notifications_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.notifications ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.notifications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: order_bump_inventory; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.order_bump_inventory (
    id integer NOT NULL,
    product_id integer NOT NULL,
    variant_id integer,
    waybill_stock integer DEFAULT 0 NOT NULL,
    reserved integer DEFAULT 0 NOT NULL,
    decremented integer DEFAULT 0 NOT NULL,
    batch character varying(100),
    updated_at timestamp without time zone DEFAULT now(),
    available integer GENERATED ALWAYS AS (((waybill_stock - reserved) - decremented)) STORED,
    CONSTRAINT chk_order_bump_inventory_available_non_negative CHECK ((available >= 0))
);


ALTER TABLE public.order_bump_inventory OWNER TO jamisan_admin;

--
-- Name: order_bump_inventory_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.order_bump_inventory ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.order_bump_inventory_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: order_escalations; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.order_escalations (
    id integer NOT NULL,
    order_id integer NOT NULL,
    reason_code_id integer NOT NULL,
    raised_by integer NOT NULL,
    raised_at timestamp without time zone DEFAULT now(),
    csr_notes text NOT NULL,
    status character varying(50) DEFAULT 'Open'::character varying NOT NULL,
    resolved_by integer,
    resolved_at timestamp without time zone,
    resolution_action character varying(100),
    resolution_notes text,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.order_escalations OWNER TO jamisan_admin;

--
-- Name: COLUMN order_escalations.raised_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.order_escalations.raised_by IS 'user_id of staff member who raised the escalation — CSR for order flags, Auditor for Auditor_Flag reason code';


--
-- Name: COLUMN order_escalations.csr_notes; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.order_escalations.csr_notes IS 'Mandatory explanation from CSR — cannot be blank';


--
-- Name: COLUMN order_escalations.status; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.order_escalations.status IS 'Open, Approved, Rejected, Reassigned';


--
-- Name: COLUMN order_escalations.resolved_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.order_escalations.resolved_by IS 'Ops Manager or Director user_id who resolved';


--
-- Name: COLUMN order_escalations.resolution_action; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.order_escalations.resolution_action IS 'Unban_User, Approve_Zero_Fee, Reassign, Reject, Investigate';


--
-- Name: COLUMN order_escalations.resolution_notes; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.order_escalations.resolution_notes IS 'Ops Manager explanation of action taken';


--
-- Name: order_escalations_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.order_escalations ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.order_escalations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: order_id_counter; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.order_id_counter (
    id integer NOT NULL,
    prefix character varying(20) DEFAULT 'CJAM'::character varying NOT NULL,
    last_number integer DEFAULT 999 NOT NULL,
    updated_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.order_id_counter OWNER TO jamisan_admin;

--
-- Name: COLUMN order_id_counter.prefix; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.order_id_counter.prefix IS 'C=CRM, JAM=Jamisan. Never changes.';


--
-- Name: COLUMN order_id_counter.last_number; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.order_id_counter.last_number IS 'Seed value — sequence starts at 1000. Use PostgreSQL SEQUENCE not this field directly.';


--
-- Name: order_id_counter_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.order_id_counter ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.order_id_counter_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: order_sources; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.order_sources (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    is_active boolean DEFAULT true
);


ALTER TABLE public.order_sources OWNER TO jamisan_admin;

--
-- Name: order_sources_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.order_sources ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.order_sources_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: order_status_history; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.order_status_history (
    id integer NOT NULL,
    order_id integer NOT NULL,
    previous_status character varying(100),
    new_status character varying(100) NOT NULL,
    changed_by integer NOT NULL,
    changed_at timestamp without time zone DEFAULT now(),
    notes text
);


ALTER TABLE public.order_status_history OWNER TO jamisan_admin;

--
-- Name: COLUMN order_status_history.changed_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.order_status_history.changed_by IS 'user_id of CSR or system';


--
-- Name: COLUMN order_status_history.notes; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.order_status_history.notes IS 'Optional context for the status change';


--
-- Name: order_status_history_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.order_status_history ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.order_status_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.orders ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: pabbly_reconciliation_log; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.pabbly_reconciliation_log (
    id integer NOT NULL,
    reconciliation_date date NOT NULL,
    crm_order_count integer NOT NULL,
    pabbly_order_count integer NOT NULL,
    discrepancy integer NOT NULL,
    status character varying(50) NOT NULL,
    alert_sent boolean DEFAULT false,
    reviewed_by integer,
    reviewed_at timestamp without time zone,
    notes text,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.pabbly_reconciliation_log OWNER TO jamisan_admin;

--
-- Name: COLUMN pabbly_reconciliation_log.discrepancy; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.pabbly_reconciliation_log.discrepancy IS 'crm_order_count - pabbly_order_count';


--
-- Name: COLUMN pabbly_reconciliation_log.status; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.pabbly_reconciliation_log.status IS 'Matched, Discrepancy Found';


--
-- Name: COLUMN pabbly_reconciliation_log.reviewed_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.pabbly_reconciliation_log.reviewed_by IS 'Ops Manager or Director who reviewed';


--
-- Name: pabbly_reconciliation_log_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.pabbly_reconciliation_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.pabbly_reconciliation_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: payroll; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.payroll (
    id integer NOT NULL,
    user_id integer NOT NULL,
    amount numeric(14,2) NOT NULL,
    commission_amount numeric(12,2) DEFAULT 0,
    total_compensation numeric(12,2),
    payment_date date,
    currency_code character varying(10) DEFAULT 'NGN'::character varying,
    month character varying(20),
    year integer,
    payment_method character varying(100),
    bank_name character varying(100),
    account_number character varying(50),
    bank_reference character varying(200),
    status character varying(50) DEFAULT 'Pending_Director_Approval'::character varying,
    director_approved_by integer,
    director_approved_at timestamp without time zone,
    comments text,
    logged_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.payroll OWNER TO jamisan_admin;

--
-- Name: COLUMN payroll.amount; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.payroll.amount IS 'Base salary';


--
-- Name: COLUMN payroll.commission_amount; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.payroll.commission_amount IS 'Calculated from csr_performance_monthly';


--
-- Name: COLUMN payroll.total_compensation; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.payroll.total_compensation IS 'amount + commission_amount';


--
-- Name: COLUMN payroll.bank_reference; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.payroll.bank_reference IS 'Bank transfer reference number logged by Accountant after external payment';


--
-- Name: COLUMN payroll.status; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.payroll.status IS 'Pending_Director_Approval, Approved, Paid, On_Hold';


--
-- Name: COLUMN payroll.director_approved_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.payroll.director_approved_by IS 'Director user_id who approved the payroll batch';


--
-- Name: COLUMN payroll.director_approved_at; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.payroll.director_approved_at IS 'When Director clicked Approve Batch';


--
-- Name: COLUMN payroll.logged_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.payroll.logged_by IS 'HR user_id who prepared the payroll';


--
-- Name: payroll_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.payroll ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.payroll_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: procurement_expenses; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.procurement_expenses (
    id integer NOT NULL,
    description text NOT NULL,
    vendor_id integer,
    product_id integer,
    batch character varying(100),
    unit_quantity integer NOT NULL,
    unit_price_usd numeric(10,4) NOT NULL,
    shipping_usd numeric(10,2) DEFAULT 0,
    processing_fee_usd numeric(10,2) DEFAULT 0,
    alibaba_cut numeric(10,4) DEFAULT 0,
    total_usd numeric(10,2) NOT NULL,
    exchange_rate numeric(10,2) NOT NULL,
    total_ngn numeric(14,2) NOT NULL,
    procurement_date date NOT NULL,
    month character varying(20),
    year integer,
    niche_id integer,
    comments text,
    receipt_url character varying(500),
    logged_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.procurement_expenses OWNER TO jamisan_admin;

--
-- Name: COLUMN procurement_expenses.vendor_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.procurement_expenses.vendor_id IS 'Links to vendors table — Vendor dropdown in Accountant procurement form. Chain link icon opens vendor profile.';


--
-- Name: COLUMN procurement_expenses.unit_quantity; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.procurement_expenses.unit_quantity IS 'Number of units purchased';


--
-- Name: COLUMN procurement_expenses.unit_price_usd; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.procurement_expenses.unit_price_usd IS 'Cost per unit in USD';


--
-- Name: COLUMN procurement_expenses.shipping_usd; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.procurement_expenses.shipping_usd IS 'Shipping cost in USD';


--
-- Name: COLUMN procurement_expenses.alibaba_cut; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.procurement_expenses.alibaba_cut IS 'Alibaba commission percentage';


--
-- Name: COLUMN procurement_expenses.total_usd; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.procurement_expenses.total_usd IS 'Total cost in USD before conversion';


--
-- Name: COLUMN procurement_expenses.exchange_rate; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.procurement_expenses.exchange_rate IS 'USD to NGN rate at time of purchase';


--
-- Name: COLUMN procurement_expenses.total_ngn; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.procurement_expenses.total_ngn IS 'total_usd * exchange_rate';


--
-- Name: COLUMN procurement_expenses.receipt_url; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.procurement_expenses.receipt_url IS 'Google Drive shareable link to invoice or receipt';


--
-- Name: procurement_expenses_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.procurement_expenses ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.procurement_expenses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: product_variants; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.product_variants (
    id integer NOT NULL,
    product_id integer NOT NULL,
    colour character varying(100) NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.product_variants OWNER TO jamisan_admin;

--
-- Name: product_variants_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.product_variants ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.product_variants_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: products; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.products (
    id integer NOT NULL,
    name character varying(200) NOT NULL,
    department_id integer NOT NULL,
    brand_id integer NOT NULL,
    type character varying(50) NOT NULL,
    category character varying(100),
    sku character varying(100),
    price numeric(12,2) NOT NULL,
    status character varying(50) DEFAULT 'Active'::character varying NOT NULL,
    description text,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.products OWNER TO jamisan_admin;

--
-- Name: COLUMN products.type; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.products.type IS 'Main, Order Bump, Upsell';


--
-- Name: COLUMN products.status; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.products.status IS 'Active, Inactive, Out of Stock';


--
-- Name: products_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.products ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: remittance_variance_reason_codes; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.remittance_variance_reason_codes (
    id integer NOT NULL,
    code character varying(100) NOT NULL,
    description character varying(200) NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.remittance_variance_reason_codes OWNER TO jamisan_admin;

--
-- Name: remittance_variance_reason_codes_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.remittance_variance_reason_codes ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.remittance_variance_reason_codes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: roles; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.roles (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    can_edit_orders boolean DEFAULT false,
    can_delete_orders boolean DEFAULT false,
    can_view_finance boolean DEFAULT false,
    can_view_payroll boolean DEFAULT false,
    can_export_csv boolean DEFAULT false,
    can_manage_users boolean DEFAULT false,
    is_active boolean DEFAULT true
);


ALTER TABLE public.roles OWNER TO jamisan_admin;

--
-- Name: roles_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.roles ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: session_log; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.session_log (
    id integer NOT NULL,
    user_id integer NOT NULL,
    logged_in_at timestamp without time zone NOT NULL,
    logged_out_at timestamp without time zone,
    session_duration_minutes integer,
    last_active_at timestamp without time zone,
    ip_address character varying(50),
    device_info text
);


ALTER TABLE public.session_log OWNER TO jamisan_admin;

--
-- Name: COLUMN session_log.session_duration_minutes; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.session_log.session_duration_minutes IS 'Calculated on logout';


--
-- Name: COLUMN session_log.last_active_at; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.session_log.last_active_at IS 'Updated on every API request. CSR status: Green <20min, Yellow 20-45min, Red >45min since now()';


--
-- Name: session_log_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.session_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.session_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shipping_types; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.shipping_types (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    is_active boolean DEFAULT true
);


ALTER TABLE public.shipping_types OWNER TO jamisan_admin;

--
-- Name: shipping_types_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.shipping_types ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shipping_types_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: stock_adjustments; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.stock_adjustments (
    id integer NOT NULL,
    product_id integer NOT NULL,
    variant_id integer,
    quantity_adjusted integer NOT NULL,
    adjustment_type character varying(100) NOT NULL,
    comments text NOT NULL,
    logged_by integer NOT NULL,
    approved_by integer,
    approved_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now(),
    inventory_type character varying(20) DEFAULT 'main'::character varying NOT NULL,
    CONSTRAINT stock_adjustments_inventory_type_check CHECK (((inventory_type)::text = ANY ((ARRAY['main'::character varying, 'order_bump'::character varying])::text[])))
);


ALTER TABLE public.stock_adjustments OWNER TO jamisan_admin;

--
-- Name: COLUMN stock_adjustments.quantity_adjusted; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.stock_adjustments.quantity_adjusted IS 'Positive = surplus found. Negative = shrinkage/loss.';


--
-- Name: COLUMN stock_adjustments.adjustment_type; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.stock_adjustments.adjustment_type IS 'Shrinkage/Missing, Damaged_In_Warehouse, Marketing_Sample, Found/Surplus, Initial_Count_Correction';


--
-- Name: COLUMN stock_adjustments.comments; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.stock_adjustments.comments IS 'Mandatory — must explain reason for adjustment';


--
-- Name: COLUMN stock_adjustments.logged_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.stock_adjustments.logged_by IS 'Warehouse Coordinator, Ops Manager, or Director';


--
-- Name: COLUMN stock_adjustments.approved_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.stock_adjustments.approved_by IS 'Director approval required if adjustment pushes available below zero';


--
-- Name: stock_adjustments_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.stock_adjustments ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.stock_adjustments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: taxes; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.taxes (
    id integer NOT NULL,
    tax_type character varying(100) NOT NULL,
    amount numeric(14,2) NOT NULL,
    tax_date date NOT NULL,
    currency_code character varying(10) DEFAULT 'NGN'::character varying,
    month character varying(20),
    year integer,
    comments text,
    receipt_url character varying(500),
    logged_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.taxes OWNER TO jamisan_admin;

--
-- Name: COLUMN taxes.tax_type; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.taxes.tax_type IS 'VAT, Corporate Tax, PAYE etc';


--
-- Name: COLUMN taxes.receipt_url; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.taxes.receipt_url IS 'Google Drive link to tax payment receipt or assessment document';


--
-- Name: taxes_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.taxes ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.taxes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: trashed_items; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.trashed_items (
    id integer NOT NULL,
    product_id integer NOT NULL,
    variant_id integer,
    quantity integer NOT NULL,
    agent_id integer NOT NULL,
    admin_level_1_id integer,
    status character varying(50) DEFAULT 'Trashed'::character varying NOT NULL,
    month character varying(20),
    year integer,
    comments text,
    logged_by integer NOT NULL,
    logged_at date NOT NULL,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.trashed_items OWNER TO jamisan_admin;

--
-- Name: COLUMN trashed_items.agent_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.trashed_items.agent_id IS 'Agent who returned the item';


--
-- Name: COLUMN trashed_items.admin_level_1_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.trashed_items.admin_level_1_id IS 'State the item was returned from';


--
-- Name: COLUMN trashed_items.status; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.trashed_items.status IS 'Trashed, Redistributed';


--
-- Name: COLUMN trashed_items.logged_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.trashed_items.logged_by IS 'Warehouse Coordinator user_id';


--
-- Name: trashed_items_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.trashed_items ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.trashed_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: user_departments; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.user_departments (
    id integer NOT NULL,
    user_id integer NOT NULL,
    department_id integer NOT NULL,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.user_departments OWNER TO jamisan_admin;

--
-- Name: user_departments_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.user_departments ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.user_departments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.users (
    id integer NOT NULL,
    role_id integer NOT NULL,
    username character varying(100) NOT NULL,
    display_name character varying(100) NOT NULL,
    full_name character varying(200) NOT NULL,
    email character varying(200) NOT NULL,
    phone character varying(20),
    password_hash character varying(255) NOT NULL,
    is_active boolean DEFAULT true,
    two_fa_enabled boolean DEFAULT false,
    two_fa_secret character varying(255),
    trusted_device_expires_at timestamp without time zone,
    last_login_at timestamp without time zone,
    last_logout_at timestamp without time zone,
    csr_level integer DEFAULT 1,
    is_on_break boolean DEFAULT false,
    created_by integer,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now(),
    token_version integer DEFAULT 0 NOT NULL,
    failed_login_attempts integer DEFAULT 0 NOT NULL,
    locked_until timestamp without time zone,
    pending_2fa_secret character varying(255) DEFAULT NULL::character varying
);


ALTER TABLE public.users OWNER TO jamisan_admin;

--
-- Name: COLUMN users.username; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.users.username IS 'Auto-generated: firstname.lastinitial e.g. ohambele.f';


--
-- Name: COLUMN users.display_name; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.users.display_name IS 'Short name shown in dropdowns e.g. Ohambele';


--
-- Name: COLUMN users.full_name; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.users.full_name IS 'Legal name e.g. Ohambele Faith Chinonye';


--
-- Name: COLUMN users.email; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.users.email IS 'Company email e.g. ohambele.chinonye@jamisan.com';


--
-- Name: COLUMN users.is_active; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.users.is_active IS 'Director can disable instantly';


--
-- Name: COLUMN users.trusted_device_expires_at; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.users.trusted_device_expires_at IS '30-day trusted device period for 2FA roles';


--
-- Name: COLUMN users.csr_level; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.users.csr_level IS 'Current CSR level 1-5. Only relevant for CSR role.';


--
-- Name: COLUMN users.is_on_break; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.users.is_on_break IS 'CSR-only. Clicking On Break toggle sets this to true instantly. Overrides last_active_at timer and sets status to Away (Yellow) immediately. Cleared on next CRM action.';


--
-- Name: COLUMN users.created_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.users.created_by IS 'user_id of Director or HR Manager who created this account';


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.users ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: vendors; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.vendors (
    id integer NOT NULL,
    name character varying(200) NOT NULL,
    vendor_type character varying(100),
    phone_1 character varying(20),
    phone_2 character varying(20),
    address text,
    city character varying(100),
    admin_level_1_id integer,
    admin_level_2_id integer,
    country_id integer,
    comments text,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.vendors OWNER TO jamisan_admin;

--
-- Name: COLUMN vendors.vendor_type; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.vendors.vendor_type IS 'Shipping Agent, Warehouse Agent, Packaging Supplier, Print Supplier, Other';


--
-- Name: COLUMN vendors.admin_level_1_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.vendors.admin_level_1_id IS 'State/Region';


--
-- Name: COLUMN vendors.admin_level_2_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.vendors.admin_level_2_id IS 'LGA/District';


--
-- Name: COLUMN vendors.country_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.vendors.country_id IS 'Defaults to Nigeria';


--
-- Name: COLUMN vendors.comments; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.vendors.comments IS 'Describe the service this vendor provides';


--
-- Name: vendors_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.vendors ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.vendors_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: wati_export_log; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.wati_export_log (
    id integer NOT NULL,
    export_type character varying(50) NOT NULL,
    export_date date NOT NULL,
    records_exported integer NOT NULL,
    status character varying(50) NOT NULL,
    error_message text,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.wati_export_log OWNER TO jamisan_admin;

--
-- Name: COLUMN wati_export_log.export_type; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.wati_export_log.export_type IS 'cash_paid_orders, complaints_refunds';


--
-- Name: COLUMN wati_export_log.status; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.wati_export_log.status IS 'Success, Failed';


--
-- Name: wati_export_log_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.wati_export_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.wati_export_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: wati_export_queue; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.wati_export_queue (
    id integer NOT NULL,
    order_id integer NOT NULL,
    status character varying(50) DEFAULT 'pending'::character varying NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    processed_at timestamp without time zone
);


ALTER TABLE public.wati_export_queue OWNER TO jamisan_admin;

--
-- Name: TABLE wati_export_queue; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON TABLE public.wati_export_queue IS 'Queue for WATI export service. Rows inserted by trigger, consumed by Module 8 integration.';


--
-- Name: wati_export_queue_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.wati_export_queue ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.wati_export_queue_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: waybill_expenses; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.waybill_expenses (
    id integer NOT NULL,
    waybill_type character varying(50) NOT NULL,
    product_id integer,
    variant_id integer,
    quantity integer,
    batch character varying(100),
    colour character varying(100),
    waybill_status character varying(50),
    product_type character varying(20),
    from_admin_level_1_id integer,
    to_admin_level_1_id integer,
    agent_id integer,
    amount numeric(14,2) NOT NULL,
    currency_code character varying(10) DEFAULT 'NGN'::character varying,
    courier character varying(100),
    waybill_date date NOT NULL,
    payment_method character varying(100),
    month character varying(20),
    year integer,
    comments text,
    receipt_url character varying(500),
    logged_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.waybill_expenses OWNER TO jamisan_admin;

--
-- Name: COLUMN waybill_expenses.waybill_type; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.waybill_expenses.waybill_type IS 'Sending, Receiving';


--
-- Name: COLUMN waybill_expenses.waybill_status; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.waybill_expenses.waybill_status IS 'Warehouse, Signed Receipt, In Transit';


--
-- Name: COLUMN waybill_expenses.product_type; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.waybill_expenses.product_type IS 'Main or Order Bump';


--
-- Name: COLUMN waybill_expenses.from_admin_level_1_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.waybill_expenses.from_admin_level_1_id IS 'State goods shipped from';


--
-- Name: COLUMN waybill_expenses.to_admin_level_1_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.waybill_expenses.to_admin_level_1_id IS 'State goods shipped to';


--
-- Name: COLUMN waybill_expenses.agent_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.waybill_expenses.agent_id IS 'Agent involved in the waybill';


--
-- Name: COLUMN waybill_expenses.amount; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.waybill_expenses.amount IS 'Cost of the waybill';


--
-- Name: COLUMN waybill_expenses.courier; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.waybill_expenses.courier IS 'Courier company used';


--
-- Name: COLUMN waybill_expenses.payment_method; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.waybill_expenses.payment_method IS 'Company paid, Agent to Pay and Deduct, Petty Cash';


--
-- Name: COLUMN waybill_expenses.receipt_url; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.waybill_expenses.receipt_url IS 'Google Drive link to waybill receipt or transport invoice';


--
-- Name: waybill_expenses_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.waybill_expenses ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.waybill_expenses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: weekly_bonus_log; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.weekly_bonus_log (
    id integer NOT NULL,
    user_id integer NOT NULL,
    week_start_date date NOT NULL,
    week_end_date date NOT NULL,
    payment_rate_achieved numeric(5,2) NOT NULL,
    bonus_amount numeric(10,2) DEFAULT 10000 NOT NULL,
    qualified boolean NOT NULL,
    announced_at timestamp without time zone,
    paid_at timestamp without time zone,
    paid_by integer,
    notes text,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.weekly_bonus_log OWNER TO jamisan_admin;

--
-- Name: COLUMN weekly_bonus_log.qualified; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.weekly_bonus_log.qualified IS 'False if nobody crossed 40% that week';


--
-- Name: COLUMN weekly_bonus_log.paid_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.weekly_bonus_log.paid_by IS 'Ops Manager user_id';


--
-- Name: weekly_bonus_log_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.weekly_bonus_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.weekly_bonus_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: weekly_reports; Type: TABLE; Schema: public; Owner: jamisan_admin
--

CREATE TABLE public.weekly_reports (
    id integer NOT NULL,
    report_type character varying(50) NOT NULL,
    department_id integer,
    csr_id integer,
    week_start_date date NOT NULL,
    week_end_date date NOT NULL,
    providus_inflow numeric(14,2),
    providus_outflow numeric(14,2),
    providus_comments text,
    moniepoint_inflow numeric(14,2),
    moniepoint_outflow numeric(14,2),
    moniepoint_comments text,
    accountant_notes text,
    cash_flow_logged boolean DEFAULT false,
    ops_aob text,
    csr_aob text,
    generated_by integer NOT NULL,
    pdf_url character varying(500),
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.weekly_reports OWNER TO jamisan_admin;

--
-- Name: COLUMN weekly_reports.report_type; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.weekly_reports.report_type IS 'CSR_Personal, Ops_Full';


--
-- Name: COLUMN weekly_reports.department_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.weekly_reports.department_id IS 'Department this report covers';


--
-- Name: COLUMN weekly_reports.csr_id; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.weekly_reports.csr_id IS 'For CSR_Personal reports — which CSR this belongs to';


--
-- Name: COLUMN weekly_reports.providus_inflow; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.weekly_reports.providus_inflow IS 'Total cash received into Providus account for the week';


--
-- Name: COLUMN weekly_reports.providus_outflow; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.weekly_reports.providus_outflow IS 'Total cash paid out of Providus account for the week';


--
-- Name: COLUMN weekly_reports.providus_comments; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.weekly_reports.providus_comments IS 'Accountant narrative on Providus activity e.g. major receipts or payments';


--
-- Name: COLUMN weekly_reports.moniepoint_inflow; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.weekly_reports.moniepoint_inflow IS 'Total cash received into Moniepoint account for the week';


--
-- Name: COLUMN weekly_reports.moniepoint_outflow; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.weekly_reports.moniepoint_outflow IS 'Total cash paid out of Moniepoint account for the week';


--
-- Name: COLUMN weekly_reports.moniepoint_comments; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.weekly_reports.moniepoint_comments IS 'Accountant narrative on Moniepoint activity';


--
-- Name: COLUMN weekly_reports.accountant_notes; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.weekly_reports.accountant_notes IS 'Section 9 closing notes — mandatory before Generate button activates';


--
-- Name: COLUMN weekly_reports.cash_flow_logged; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.weekly_reports.cash_flow_logged IS 'Set true when Accountant saves Section 9 fields. Generate button blocked until true. Clears Pending Actions reminder.';


--
-- Name: COLUMN weekly_reports.ops_aob; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.weekly_reports.ops_aob IS 'Section 10 — Any Other Business entered by Ops Manager before PDF generation';


--
-- Name: COLUMN weekly_reports.csr_aob; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.weekly_reports.csr_aob IS 'Any Other Business entered by CSR for their Section 3 personal report';


--
-- Name: COLUMN weekly_reports.generated_by; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.weekly_reports.generated_by IS 'user_id of whoever clicked Generate';


--
-- Name: COLUMN weekly_reports.pdf_url; Type: COMMENT; Schema: public; Owner: jamisan_admin
--

COMMENT ON COLUMN public.weekly_reports.pdf_url IS 'Google Drive link to archived PDF — same pattern as expense receipts';


--
-- Name: weekly_reports_id_seq; Type: SEQUENCE; Schema: public; Owner: jamisan_admin
--

ALTER TABLE public.weekly_reports ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.weekly_reports_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: action_items action_items_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.action_items
    ADD CONSTRAINT action_items_pkey PRIMARY KEY (id);


--
-- Name: ad_expenses ad_expenses_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.ad_expenses
    ADD CONSTRAINT ad_expenses_pkey PRIMARY KEY (id);


--
-- Name: admin_level_1 admin_level_1_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.admin_level_1
    ADD CONSTRAINT admin_level_1_pkey PRIMARY KEY (id);


--
-- Name: admin_level_2 admin_level_2_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.admin_level_2
    ADD CONSTRAINT admin_level_2_pkey PRIMARY KEY (id);


--
-- Name: agent_ledger agent_ledger_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.agent_ledger
    ADD CONSTRAINT agent_ledger_pkey PRIMARY KEY (id);


--
-- Name: agent_remittance agent_remittance_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.agent_remittance
    ADD CONSTRAINT agent_remittance_pkey PRIMARY KEY (id);


--
-- Name: agent_zone_assignments agent_zone_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.agent_zone_assignments
    ADD CONSTRAINT agent_zone_assignments_pkey PRIMARY KEY (id);


--
-- Name: agents agents_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_pkey PRIMARY KEY (id);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


--
-- Name: auditor_check_categories auditor_check_categories_code_key; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.auditor_check_categories
    ADD CONSTRAINT auditor_check_categories_code_key UNIQUE (code);


--
-- Name: auditor_check_categories auditor_check_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.auditor_check_categories
    ADD CONSTRAINT auditor_check_categories_pkey PRIMARY KEY (id);


--
-- Name: auditor_spot_checks auditor_spot_checks_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.auditor_spot_checks
    ADD CONSTRAINT auditor_spot_checks_pkey PRIMARY KEY (id);


--
-- Name: backup_log backup_log_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.backup_log
    ADD CONSTRAINT backup_log_pkey PRIMARY KEY (id);


--
-- Name: brands brands_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.brands
    ADD CONSTRAINT brands_pkey PRIMARY KEY (id);


--
-- Name: commission_tiers commission_tiers_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.commission_tiers
    ADD CONSTRAINT commission_tiers_pkey PRIMARY KEY (id);


--
-- Name: complaints complaints_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.complaints
    ADD CONSTRAINT complaints_pkey PRIMARY KEY (id);


--
-- Name: countries countries_country_code_key; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.countries
    ADD CONSTRAINT countries_country_code_key UNIQUE (country_code);


--
-- Name: countries countries_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.countries
    ADD CONSTRAINT countries_pkey PRIMARY KEY (id);


--
-- Name: csr_level_history csr_level_history_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.csr_level_history
    ADD CONSTRAINT csr_level_history_pkey PRIMARY KEY (id);


--
-- Name: csr_levels csr_levels_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.csr_levels
    ADD CONSTRAINT csr_levels_pkey PRIMARY KEY (id);


--
-- Name: csr_performance_monthly csr_performance_monthly_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.csr_performance_monthly
    ADD CONSTRAINT csr_performance_monthly_pkey PRIMARY KEY (id);


--
-- Name: csr_promotion_thresholds csr_promotion_thresholds_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.csr_promotion_thresholds
    ADD CONSTRAINT csr_promotion_thresholds_pkey PRIMARY KEY (id);


--
-- Name: customers customers_phone_number_key; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_phone_number_key UNIQUE (phone_number);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: department_targets department_targets_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.department_targets
    ADD CONSTRAINT department_targets_pkey PRIMARY KEY (id);


--
-- Name: departments departments_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.departments
    ADD CONSTRAINT departments_pkey PRIMARY KEY (id);


--
-- Name: employee_profiles employee_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.employee_profiles
    ADD CONSTRAINT employee_profiles_pkey PRIMARY KEY (id);


--
-- Name: employee_profiles employee_profiles_user_id_key; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.employee_profiles
    ADD CONSTRAINT employee_profiles_user_id_key UNIQUE (user_id);


--
-- Name: escalation_reason_codes escalation_reason_codes_code_key; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.escalation_reason_codes
    ADD CONSTRAINT escalation_reason_codes_code_key UNIQUE (code);


--
-- Name: escalation_reason_codes escalation_reason_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.escalation_reason_codes
    ADD CONSTRAINT escalation_reason_codes_pkey PRIMARY KEY (id);


--
-- Name: expense_categories expense_categories_name_key; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.expense_categories
    ADD CONSTRAINT expense_categories_name_key UNIQUE (name);


--
-- Name: expense_categories expense_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.expense_categories
    ADD CONSTRAINT expense_categories_pkey PRIMARY KEY (id);


--
-- Name: expenses expenses_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_pkey PRIMARY KEY (id);


--
-- Name: failure_reason_codes failure_reason_codes_code_key; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.failure_reason_codes
    ADD CONSTRAINT failure_reason_codes_code_key UNIQUE (code);


--
-- Name: failure_reason_codes failure_reason_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.failure_reason_codes
    ADD CONSTRAINT failure_reason_codes_pkey PRIMARY KEY (id);


--
-- Name: goods_movement goods_movement_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.goods_movement
    ADD CONSTRAINT goods_movement_pkey PRIMARY KEY (id);


--
-- Name: inventory inventory_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.inventory
    ADD CONSTRAINT inventory_pkey PRIMARY KEY (id);


--
-- Name: investment_inflow investment_inflow_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.investment_inflow
    ADD CONSTRAINT investment_inflow_pkey PRIMARY KEY (id);


--
-- Name: lesson_categories lesson_categories_name_key; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.lesson_categories
    ADD CONSTRAINT lesson_categories_name_key UNIQUE (name);


--
-- Name: lesson_categories lesson_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.lesson_categories
    ADD CONSTRAINT lesson_categories_pkey PRIMARY KEY (id);


--
-- Name: lessons_learned lessons_learned_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.lessons_learned
    ADD CONSTRAINT lessons_learned_pkey PRIMARY KEY (id);


--
-- Name: loans loans_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.loans
    ADD CONSTRAINT loans_pkey PRIMARY KEY (id);


--
-- Name: niches niches_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.niches
    ADD CONSTRAINT niches_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: order_bump_inventory order_bump_inventory_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.order_bump_inventory
    ADD CONSTRAINT order_bump_inventory_pkey PRIMARY KEY (id);


--
-- Name: order_escalations order_escalations_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.order_escalations
    ADD CONSTRAINT order_escalations_pkey PRIMARY KEY (id);


--
-- Name: order_id_counter order_id_counter_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.order_id_counter
    ADD CONSTRAINT order_id_counter_pkey PRIMARY KEY (id);


--
-- Name: order_sources order_sources_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.order_sources
    ADD CONSTRAINT order_sources_pkey PRIMARY KEY (id);


--
-- Name: order_status_history order_status_history_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.order_status_history
    ADD CONSTRAINT order_status_history_pkey PRIMARY KEY (id);


--
-- Name: orders orders_order_id_key; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_order_id_key UNIQUE (order_id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: pabbly_reconciliation_log pabbly_reconciliation_log_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.pabbly_reconciliation_log
    ADD CONSTRAINT pabbly_reconciliation_log_pkey PRIMARY KEY (id);


--
-- Name: payroll payroll_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.payroll
    ADD CONSTRAINT payroll_pkey PRIMARY KEY (id);


--
-- Name: procurement_expenses procurement_expenses_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.procurement_expenses
    ADD CONSTRAINT procurement_expenses_pkey PRIMARY KEY (id);


--
-- Name: product_variants product_variants_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.product_variants
    ADD CONSTRAINT product_variants_pkey PRIMARY KEY (id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: products products_sku_key; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_sku_key UNIQUE (sku);


--
-- Name: remittance_variance_reason_codes remittance_variance_reason_codes_code_key; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.remittance_variance_reason_codes
    ADD CONSTRAINT remittance_variance_reason_codes_code_key UNIQUE (code);


--
-- Name: remittance_variance_reason_codes remittance_variance_reason_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.remittance_variance_reason_codes
    ADD CONSTRAINT remittance_variance_reason_codes_pkey PRIMARY KEY (id);


--
-- Name: roles roles_name_key; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_name_key UNIQUE (name);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: session_log session_log_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.session_log
    ADD CONSTRAINT session_log_pkey PRIMARY KEY (id);


--
-- Name: shipping_types shipping_types_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.shipping_types
    ADD CONSTRAINT shipping_types_pkey PRIMARY KEY (id);


--
-- Name: stock_adjustments stock_adjustments_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.stock_adjustments
    ADD CONSTRAINT stock_adjustments_pkey PRIMARY KEY (id);


--
-- Name: taxes taxes_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.taxes
    ADD CONSTRAINT taxes_pkey PRIMARY KEY (id);


--
-- Name: trashed_items trashed_items_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.trashed_items
    ADD CONSTRAINT trashed_items_pkey PRIMARY KEY (id);


--
-- Name: user_departments user_departments_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.user_departments
    ADD CONSTRAINT user_departments_pkey PRIMARY KEY (id);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: users users_username_key; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_username_key UNIQUE (username);


--
-- Name: vendors vendors_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT vendors_pkey PRIMARY KEY (id);


--
-- Name: wati_export_log wati_export_log_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.wati_export_log
    ADD CONSTRAINT wati_export_log_pkey PRIMARY KEY (id);


--
-- Name: wati_export_queue wati_export_queue_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.wati_export_queue
    ADD CONSTRAINT wati_export_queue_pkey PRIMARY KEY (id);


--
-- Name: waybill_expenses waybill_expenses_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.waybill_expenses
    ADD CONSTRAINT waybill_expenses_pkey PRIMARY KEY (id);


--
-- Name: weekly_bonus_log weekly_bonus_log_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.weekly_bonus_log
    ADD CONSTRAINT weekly_bonus_log_pkey PRIMARY KEY (id);


--
-- Name: weekly_reports weekly_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.weekly_reports
    ADD CONSTRAINT weekly_reports_pkey PRIMARY KEY (id);


--
-- Name: idx_action_items_assigned_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_action_items_assigned_by ON public.action_items USING btree (assigned_by);


--
-- Name: idx_action_items_assigned_to; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_action_items_assigned_to ON public.action_items USING btree (assigned_to);


--
-- Name: idx_action_items_closed_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_action_items_closed_by ON public.action_items USING btree (closed_by);


--
-- Name: idx_ad_expenses_brand_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_ad_expenses_brand_id ON public.ad_expenses USING btree (brand_id);


--
-- Name: idx_ad_expenses_logged_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_ad_expenses_logged_by ON public.ad_expenses USING btree (logged_by);


--
-- Name: idx_ad_expenses_product_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_ad_expenses_product_id ON public.ad_expenses USING btree (product_id);


--
-- Name: idx_admin_level_1_country_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_admin_level_1_country_id ON public.admin_level_1 USING btree (country_id);


--
-- Name: idx_admin_level_2_admin_level_1_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_admin_level_2_admin_level_1_id ON public.admin_level_2 USING btree (admin_level_1_id);


--
-- Name: idx_agent_ledger_agent_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_agent_ledger_agent_id ON public.agent_ledger USING btree (agent_id);


--
-- Name: idx_agent_ledger_logged_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_agent_ledger_logged_by ON public.agent_ledger USING btree (logged_by);


--
-- Name: idx_agent_remittance_admin_level_1_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_agent_remittance_admin_level_1_id ON public.agent_remittance USING btree (admin_level_1_id);


--
-- Name: idx_agent_remittance_agent_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_agent_remittance_agent_id ON public.agent_remittance USING btree (agent_id);


--
-- Name: idx_agent_remittance_logged_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_agent_remittance_logged_by ON public.agent_remittance USING btree (logged_by);


--
-- Name: idx_agent_remittance_status; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_agent_remittance_status ON public.agent_remittance USING btree (status);


--
-- Name: idx_agent_remittance_variance_reason_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_agent_remittance_variance_reason_id ON public.agent_remittance USING btree (variance_reason_id);


--
-- Name: idx_agent_zone_assignments_admin_level_1_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_agent_zone_assignments_admin_level_1_id ON public.agent_zone_assignments USING btree (admin_level_1_id);


--
-- Name: idx_agent_zone_assignments_admin_level_2_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_agent_zone_assignments_admin_level_2_id ON public.agent_zone_assignments USING btree (admin_level_2_id);


--
-- Name: idx_agent_zone_assignments_overflow_agent_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_agent_zone_assignments_overflow_agent_id ON public.agent_zone_assignments USING btree (overflow_agent_id);


--
-- Name: idx_agent_zone_assignments_primary_agent_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_agent_zone_assignments_primary_agent_id ON public.agent_zone_assignments USING btree (primary_agent_id);


--
-- Name: idx_agents_admin_level_1_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_agents_admin_level_1_id ON public.agents USING btree (admin_level_1_id);


--
-- Name: idx_agents_admin_level_2_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_agents_admin_level_2_id ON public.agents USING btree (admin_level_2_id);


--
-- Name: idx_audit_log_created_at; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_audit_log_created_at ON public.audit_log USING btree (created_at);


--
-- Name: idx_audit_log_login_failures; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_audit_log_login_failures ON public.audit_log USING btree (action, new_value, created_at) WHERE ((action)::text = 'login_failed'::text);


--
-- Name: idx_audit_log_user_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_audit_log_user_id ON public.audit_log USING btree (user_id);


--
-- Name: idx_auditor_spot_checks_auditor_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_auditor_spot_checks_auditor_id ON public.auditor_spot_checks USING btree (auditor_id);


--
-- Name: idx_auditor_spot_checks_check_category_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_auditor_spot_checks_check_category_id ON public.auditor_spot_checks USING btree (check_category_id);


--
-- Name: idx_auditor_spot_checks_order_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_auditor_spot_checks_order_id ON public.auditor_spot_checks USING btree (order_id);


--
-- Name: idx_brands_department_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_brands_department_id ON public.brands USING btree (department_id);


--
-- Name: idx_brands_niche_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_brands_niche_id ON public.brands USING btree (niche_id);


--
-- Name: idx_commission_tiers_department_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_commission_tiers_department_id ON public.commission_tiers USING btree (department_id);


--
-- Name: idx_complaints_assigned_csr_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_complaints_assigned_csr_id ON public.complaints USING btree (assigned_csr_id);


--
-- Name: idx_complaints_customer_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_complaints_customer_id ON public.complaints USING btree (customer_id);


--
-- Name: idx_complaints_order_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_complaints_order_id ON public.complaints USING btree (order_id);


--
-- Name: idx_complaints_resolved_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_complaints_resolved_by ON public.complaints USING btree (resolved_by);


--
-- Name: idx_csr_level_history_changed_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_csr_level_history_changed_by ON public.csr_level_history USING btree (changed_by);


--
-- Name: idx_csr_level_history_user_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_csr_level_history_user_id ON public.csr_level_history USING btree (user_id);


--
-- Name: idx_csr_performance_monthly_commission_tier_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_csr_performance_monthly_commission_tier_id ON public.csr_performance_monthly USING btree (commission_tier_id);


--
-- Name: idx_csr_performance_monthly_department_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_csr_performance_monthly_department_id ON public.csr_performance_monthly USING btree (department_id);


--
-- Name: idx_csr_performance_monthly_user_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_csr_performance_monthly_user_id ON public.csr_performance_monthly USING btree (user_id);


--
-- Name: idx_csr_promotion_thresholds_department_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_csr_promotion_thresholds_department_id ON public.csr_promotion_thresholds USING btree (department_id);


--
-- Name: idx_customers_banned_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_customers_banned_by ON public.customers USING btree (banned_by);


--
-- Name: idx_department_targets_department_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_department_targets_department_id ON public.department_targets USING btree (department_id);


--
-- Name: idx_department_targets_set_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_department_targets_set_by ON public.department_targets USING btree (set_by);


--
-- Name: idx_escalation_reason_codes_created_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_escalation_reason_codes_created_by ON public.escalation_reason_codes USING btree (created_by);


--
-- Name: idx_expenses_admin_level_1_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_expenses_admin_level_1_id ON public.expenses USING btree (admin_level_1_id);


--
-- Name: idx_expenses_agent_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_expenses_agent_id ON public.expenses USING btree (agent_id);


--
-- Name: idx_expenses_expense_category_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_expenses_expense_category_id ON public.expenses USING btree (expense_category_id);


--
-- Name: idx_expenses_logged_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_expenses_logged_by ON public.expenses USING btree (logged_by);


--
-- Name: idx_expenses_product_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_expenses_product_id ON public.expenses USING btree (product_id);


--
-- Name: idx_goods_movement_admin_level_1_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_goods_movement_admin_level_1_id ON public.goods_movement USING btree (admin_level_1_id);


--
-- Name: idx_goods_movement_from_agent_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_goods_movement_from_agent_id ON public.goods_movement USING btree (from_agent_id);


--
-- Name: idx_goods_movement_logged_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_goods_movement_logged_by ON public.goods_movement USING btree (logged_by);


--
-- Name: idx_goods_movement_product_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_goods_movement_product_id ON public.goods_movement USING btree (product_id);


--
-- Name: idx_goods_movement_shipping_type_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_goods_movement_shipping_type_id ON public.goods_movement USING btree (shipping_type_id);


--
-- Name: idx_goods_movement_to_agent_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_goods_movement_to_agent_id ON public.goods_movement USING btree (to_agent_id);


--
-- Name: idx_goods_movement_variant_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_goods_movement_variant_id ON public.goods_movement USING btree (variant_id);


--
-- Name: idx_inventory_product_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_inventory_product_id ON public.inventory USING btree (product_id);


--
-- Name: idx_inventory_product_variant; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_inventory_product_variant ON public.inventory USING btree (product_id, variant_id);


--
-- Name: idx_inventory_variant_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_inventory_variant_id ON public.inventory USING btree (variant_id);


--
-- Name: idx_investment_inflow_logged_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_investment_inflow_logged_by ON public.investment_inflow USING btree (logged_by);


--
-- Name: idx_lesson_categories_created_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_lesson_categories_created_by ON public.lesson_categories USING btree (created_by);


--
-- Name: idx_lessons_learned_category_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_lessons_learned_category_id ON public.lessons_learned USING btree (category_id);


--
-- Name: idx_lessons_learned_reviewed_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_lessons_learned_reviewed_by ON public.lessons_learned USING btree (reviewed_by);


--
-- Name: idx_lessons_learned_submitted_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_lessons_learned_submitted_by ON public.lessons_learned USING btree (submitted_by);


--
-- Name: idx_loans_logged_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_loans_logged_by ON public.loans USING btree (logged_by);


--
-- Name: idx_notifications_recipient_agent_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_notifications_recipient_agent_id ON public.notifications USING btree (recipient_agent_id);


--
-- Name: idx_notifications_recipient_user_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_notifications_recipient_user_id ON public.notifications USING btree (recipient_user_id);


--
-- Name: idx_notifications_status; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_notifications_status ON public.notifications USING btree (status);


--
-- Name: idx_order_bump_inventory_product_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_order_bump_inventory_product_id ON public.order_bump_inventory USING btree (product_id);


--
-- Name: idx_order_bump_inventory_product_variant; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_order_bump_inventory_product_variant ON public.order_bump_inventory USING btree (product_id, variant_id);


--
-- Name: idx_order_bump_inventory_variant_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_order_bump_inventory_variant_id ON public.order_bump_inventory USING btree (variant_id);


--
-- Name: idx_order_escalations_order_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_order_escalations_order_id ON public.order_escalations USING btree (order_id);


--
-- Name: idx_order_escalations_raised_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_order_escalations_raised_by ON public.order_escalations USING btree (raised_by);


--
-- Name: idx_order_escalations_reason_code_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_order_escalations_reason_code_id ON public.order_escalations USING btree (reason_code_id);


--
-- Name: idx_order_escalations_resolved_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_order_escalations_resolved_by ON public.order_escalations USING btree (resolved_by);


--
-- Name: idx_order_status_history_changed_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_order_status_history_changed_by ON public.order_status_history USING btree (changed_by);


--
-- Name: idx_order_status_history_order_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_order_status_history_order_id ON public.order_status_history USING btree (order_id);


--
-- Name: idx_orders_admin_level_1_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_admin_level_1_id ON public.orders USING btree (admin_level_1_id);


--
-- Name: idx_orders_admin_level_2_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_admin_level_2_id ON public.orders USING btree (admin_level_2_id);


--
-- Name: idx_orders_agent_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_agent_id ON public.orders USING btree (agent_id);


--
-- Name: idx_orders_assigned_csr_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_assigned_csr_id ON public.orders USING btree (assigned_csr_id);


--
-- Name: idx_orders_assigned_csr_status; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_assigned_csr_status ON public.orders USING btree (assigned_csr_id, status);


--
-- Name: idx_orders_brand_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_brand_id ON public.orders USING btree (brand_id);


--
-- Name: idx_orders_country_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_country_id ON public.orders USING btree (country_id);


--
-- Name: idx_orders_created_at; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_created_at ON public.orders USING btree (created_at);


--
-- Name: idx_orders_customer_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_customer_id ON public.orders USING btree (customer_id);


--
-- Name: idx_orders_department_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_department_id ON public.orders USING btree (department_id);


--
-- Name: idx_orders_failure_reason_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_failure_reason_id ON public.orders USING btree (failure_reason_id);


--
-- Name: idx_orders_niche_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_niche_id ON public.orders USING btree (niche_id);


--
-- Name: idx_orders_order_bump_product_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_order_bump_product_id ON public.orders USING btree (order_bump_product_id);


--
-- Name: idx_orders_order_bump_variant_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_order_bump_variant_id ON public.orders USING btree (order_bump_variant_id);


--
-- Name: idx_orders_phone_number; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_phone_number ON public.orders USING btree (phone_number);


--
-- Name: idx_orders_product_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_product_id ON public.orders USING btree (product_id);


--
-- Name: idx_orders_product_variant_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_product_variant_id ON public.orders USING btree (product_variant_id);


--
-- Name: idx_orders_shipping_type_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_shipping_type_id ON public.orders USING btree (shipping_type_id);


--
-- Name: idx_orders_source_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_source_id ON public.orders USING btree (source_id);


--
-- Name: idx_orders_status; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_status ON public.orders USING btree (status);


--
-- Name: idx_orders_status_department; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_orders_status_department ON public.orders USING btree (status, department_id);


--
-- Name: idx_pabbly_reconciliation_log_reviewed_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_pabbly_reconciliation_log_reviewed_by ON public.pabbly_reconciliation_log USING btree (reviewed_by);


--
-- Name: idx_payroll_director_approved_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_payroll_director_approved_by ON public.payroll USING btree (director_approved_by);


--
-- Name: idx_payroll_logged_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_payroll_logged_by ON public.payroll USING btree (logged_by);


--
-- Name: idx_payroll_user_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_payroll_user_id ON public.payroll USING btree (user_id);


--
-- Name: idx_procurement_expenses_logged_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_procurement_expenses_logged_by ON public.procurement_expenses USING btree (logged_by);


--
-- Name: idx_procurement_expenses_niche_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_procurement_expenses_niche_id ON public.procurement_expenses USING btree (niche_id);


--
-- Name: idx_procurement_expenses_product_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_procurement_expenses_product_id ON public.procurement_expenses USING btree (product_id);


--
-- Name: idx_procurement_expenses_vendor_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_procurement_expenses_vendor_id ON public.procurement_expenses USING btree (vendor_id);


--
-- Name: idx_product_variants_product_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_product_variants_product_id ON public.product_variants USING btree (product_id);


--
-- Name: idx_products_brand_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_products_brand_id ON public.products USING btree (brand_id);


--
-- Name: idx_products_department_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_products_department_id ON public.products USING btree (department_id);


--
-- Name: idx_session_log_last_active_at; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_session_log_last_active_at ON public.session_log USING btree (last_active_at);


--
-- Name: idx_session_log_user_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_session_log_user_id ON public.session_log USING btree (user_id);


--
-- Name: idx_stock_adjustments_approved_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_stock_adjustments_approved_by ON public.stock_adjustments USING btree (approved_by);


--
-- Name: idx_stock_adjustments_logged_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_stock_adjustments_logged_by ON public.stock_adjustments USING btree (logged_by);


--
-- Name: idx_stock_adjustments_product_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_stock_adjustments_product_id ON public.stock_adjustments USING btree (product_id);


--
-- Name: idx_stock_adjustments_variant_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_stock_adjustments_variant_id ON public.stock_adjustments USING btree (variant_id);


--
-- Name: idx_taxes_logged_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_taxes_logged_by ON public.taxes USING btree (logged_by);


--
-- Name: idx_trashed_items_admin_level_1_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_trashed_items_admin_level_1_id ON public.trashed_items USING btree (admin_level_1_id);


--
-- Name: idx_trashed_items_agent_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_trashed_items_agent_id ON public.trashed_items USING btree (agent_id);


--
-- Name: idx_trashed_items_logged_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_trashed_items_logged_by ON public.trashed_items USING btree (logged_by);


--
-- Name: idx_trashed_items_product_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_trashed_items_product_id ON public.trashed_items USING btree (product_id);


--
-- Name: idx_trashed_items_variant_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_trashed_items_variant_id ON public.trashed_items USING btree (variant_id);


--
-- Name: idx_user_departments_department_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_user_departments_department_id ON public.user_departments USING btree (department_id);


--
-- Name: idx_user_departments_user_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_user_departments_user_id ON public.user_departments USING btree (user_id);


--
-- Name: idx_users_created_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_users_created_by ON public.users USING btree (created_by);


--
-- Name: idx_users_role_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_users_role_id ON public.users USING btree (role_id);


--
-- Name: idx_vendors_admin_level_1_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_vendors_admin_level_1_id ON public.vendors USING btree (admin_level_1_id);


--
-- Name: idx_vendors_admin_level_2_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_vendors_admin_level_2_id ON public.vendors USING btree (admin_level_2_id);


--
-- Name: idx_vendors_country_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_vendors_country_id ON public.vendors USING btree (country_id);


--
-- Name: idx_wati_export_queue_order_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_wati_export_queue_order_id ON public.wati_export_queue USING btree (order_id);


--
-- Name: idx_wati_export_queue_status; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_wati_export_queue_status ON public.wati_export_queue USING btree (status);


--
-- Name: idx_waybill_expenses_agent_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_waybill_expenses_agent_id ON public.waybill_expenses USING btree (agent_id);


--
-- Name: idx_waybill_expenses_from_admin_level_1_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_waybill_expenses_from_admin_level_1_id ON public.waybill_expenses USING btree (from_admin_level_1_id);


--
-- Name: idx_waybill_expenses_logged_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_waybill_expenses_logged_by ON public.waybill_expenses USING btree (logged_by);


--
-- Name: idx_waybill_expenses_product_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_waybill_expenses_product_id ON public.waybill_expenses USING btree (product_id);


--
-- Name: idx_waybill_expenses_to_admin_level_1_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_waybill_expenses_to_admin_level_1_id ON public.waybill_expenses USING btree (to_admin_level_1_id);


--
-- Name: idx_waybill_expenses_variant_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_waybill_expenses_variant_id ON public.waybill_expenses USING btree (variant_id);


--
-- Name: idx_weekly_bonus_log_paid_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_weekly_bonus_log_paid_by ON public.weekly_bonus_log USING btree (paid_by);


--
-- Name: idx_weekly_bonus_log_user_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_weekly_bonus_log_user_id ON public.weekly_bonus_log USING btree (user_id);


--
-- Name: idx_weekly_reports_csr_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_weekly_reports_csr_id ON public.weekly_reports USING btree (csr_id);


--
-- Name: idx_weekly_reports_department_id; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_weekly_reports_department_id ON public.weekly_reports USING btree (department_id);


--
-- Name: idx_weekly_reports_generated_by; Type: INDEX; Schema: public; Owner: jamisan_admin
--

CREATE INDEX idx_weekly_reports_generated_by ON public.weekly_reports USING btree (generated_by);


--
-- Name: audit_log prevent_audit_delete; Type: RULE; Schema: public; Owner: jamisan_admin
--

CREATE RULE prevent_audit_delete AS
    ON DELETE TO public.audit_log DO INSTEAD NOTHING;


--
-- Name: audit_log prevent_audit_update; Type: RULE; Schema: public; Owner: jamisan_admin
--

CREATE RULE prevent_audit_update AS
    ON UPDATE TO public.audit_log DO INSTEAD NOTHING;


--
-- Name: action_items set_updated_at; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.action_items FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: agent_zone_assignments set_updated_at; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.agent_zone_assignments FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: agents set_updated_at; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.agents FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: complaints set_updated_at; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.complaints FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: csr_performance_monthly set_updated_at; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.csr_performance_monthly FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: customers set_updated_at; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: employee_profiles set_updated_at; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.employee_profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: inventory set_updated_at; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.inventory FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: lessons_learned set_updated_at; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.lessons_learned FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: loans set_updated_at; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.loans FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: order_bump_inventory set_updated_at; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.order_bump_inventory FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: order_id_counter set_updated_at; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.order_id_counter FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: orders set_updated_at; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: products set_updated_at; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: users set_updated_at; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: vendors set_updated_at; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.vendors FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: agent_ledger trg_agent_ledger_running_balance; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER trg_agent_ledger_running_balance BEFORE INSERT ON public.agent_ledger FOR EACH ROW EXECUTE FUNCTION public.fn_agent_ledger_running_balance();


--
-- Name: agent_remittance trg_agent_remittance_verified_cleared; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER trg_agent_remittance_verified_cleared AFTER UPDATE OF status ON public.agent_remittance FOR EACH ROW EXECUTE FUNCTION public.fn_agent_remittance_verified_cleared();


--
-- Name: orders trg_orders_stock_management; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER trg_orders_stock_management AFTER INSERT OR UPDATE OF status ON public.orders FOR EACH ROW EXECUTE FUNCTION public.fn_orders_stock_management();


--
-- Name: orders trg_orders_wati_export; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER trg_orders_wati_export BEFORE UPDATE OF status ON public.orders FOR EACH ROW EXECUTE FUNCTION public.fn_orders_wati_export();


--
-- Name: stock_adjustments trg_stock_adjustments_update_stock; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER trg_stock_adjustments_update_stock AFTER INSERT ON public.stock_adjustments FOR EACH ROW EXECUTE FUNCTION public.fn_stock_adjustments_update_stock();


--
-- Name: trashed_items trg_trashed_items_subtract_stock; Type: TRIGGER; Schema: public; Owner: jamisan_admin
--

CREATE TRIGGER trg_trashed_items_subtract_stock AFTER INSERT ON public.trashed_items FOR EACH ROW EXECUTE FUNCTION public.fn_trashed_items_subtract_stock();


--
-- Name: action_items action_items_assigned_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.action_items
    ADD CONSTRAINT action_items_assigned_by_fkey FOREIGN KEY (assigned_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: action_items action_items_assigned_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.action_items
    ADD CONSTRAINT action_items_assigned_to_fkey FOREIGN KEY (assigned_to) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: action_items action_items_closed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.action_items
    ADD CONSTRAINT action_items_closed_by_fkey FOREIGN KEY (closed_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: ad_expenses ad_expenses_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.ad_expenses
    ADD CONSTRAINT ad_expenses_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) DEFERRABLE;


--
-- Name: ad_expenses ad_expenses_logged_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.ad_expenses
    ADD CONSTRAINT ad_expenses_logged_by_fkey FOREIGN KEY (logged_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: ad_expenses ad_expenses_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.ad_expenses
    ADD CONSTRAINT ad_expenses_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) DEFERRABLE;


--
-- Name: admin_level_1 admin_level_1_country_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.admin_level_1
    ADD CONSTRAINT admin_level_1_country_id_fkey FOREIGN KEY (country_id) REFERENCES public.countries(id) DEFERRABLE;


--
-- Name: admin_level_2 admin_level_2_admin_level_1_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.admin_level_2
    ADD CONSTRAINT admin_level_2_admin_level_1_id_fkey FOREIGN KEY (admin_level_1_id) REFERENCES public.admin_level_1(id) DEFERRABLE;


--
-- Name: agent_ledger agent_ledger_agent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.agent_ledger
    ADD CONSTRAINT agent_ledger_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES public.agents(id) DEFERRABLE;


--
-- Name: agent_ledger agent_ledger_logged_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.agent_ledger
    ADD CONSTRAINT agent_ledger_logged_by_fkey FOREIGN KEY (logged_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: agent_remittance agent_remittance_admin_level_1_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.agent_remittance
    ADD CONSTRAINT agent_remittance_admin_level_1_id_fkey FOREIGN KEY (admin_level_1_id) REFERENCES public.admin_level_1(id) DEFERRABLE;


--
-- Name: agent_remittance agent_remittance_agent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.agent_remittance
    ADD CONSTRAINT agent_remittance_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES public.agents(id) DEFERRABLE;


--
-- Name: agent_remittance agent_remittance_logged_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.agent_remittance
    ADD CONSTRAINT agent_remittance_logged_by_fkey FOREIGN KEY (logged_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: agent_remittance agent_remittance_variance_reason_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.agent_remittance
    ADD CONSTRAINT agent_remittance_variance_reason_id_fkey FOREIGN KEY (variance_reason_id) REFERENCES public.remittance_variance_reason_codes(id) DEFERRABLE;


--
-- Name: agent_zone_assignments agent_zone_assignments_admin_level_1_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.agent_zone_assignments
    ADD CONSTRAINT agent_zone_assignments_admin_level_1_id_fkey FOREIGN KEY (admin_level_1_id) REFERENCES public.admin_level_1(id) DEFERRABLE;


--
-- Name: agent_zone_assignments agent_zone_assignments_admin_level_2_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.agent_zone_assignments
    ADD CONSTRAINT agent_zone_assignments_admin_level_2_id_fkey FOREIGN KEY (admin_level_2_id) REFERENCES public.admin_level_2(id) DEFERRABLE;


--
-- Name: agent_zone_assignments agent_zone_assignments_overflow_agent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.agent_zone_assignments
    ADD CONSTRAINT agent_zone_assignments_overflow_agent_id_fkey FOREIGN KEY (overflow_agent_id) REFERENCES public.agents(id) DEFERRABLE;


--
-- Name: agent_zone_assignments agent_zone_assignments_primary_agent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.agent_zone_assignments
    ADD CONSTRAINT agent_zone_assignments_primary_agent_id_fkey FOREIGN KEY (primary_agent_id) REFERENCES public.agents(id) DEFERRABLE;


--
-- Name: agents agents_admin_level_1_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_admin_level_1_id_fkey FOREIGN KEY (admin_level_1_id) REFERENCES public.admin_level_1(id) DEFERRABLE;


--
-- Name: agents agents_admin_level_2_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_admin_level_2_id_fkey FOREIGN KEY (admin_level_2_id) REFERENCES public.admin_level_2(id) DEFERRABLE;


--
-- Name: audit_log audit_log_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: auditor_spot_checks auditor_spot_checks_auditor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.auditor_spot_checks
    ADD CONSTRAINT auditor_spot_checks_auditor_id_fkey FOREIGN KEY (auditor_id) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: auditor_spot_checks auditor_spot_checks_check_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.auditor_spot_checks
    ADD CONSTRAINT auditor_spot_checks_check_category_id_fkey FOREIGN KEY (check_category_id) REFERENCES public.auditor_check_categories(id) DEFERRABLE;


--
-- Name: auditor_spot_checks auditor_spot_checks_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.auditor_spot_checks
    ADD CONSTRAINT auditor_spot_checks_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) DEFERRABLE;


--
-- Name: brands brands_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.brands
    ADD CONSTRAINT brands_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id) DEFERRABLE;


--
-- Name: brands brands_niche_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.brands
    ADD CONSTRAINT brands_niche_id_fkey FOREIGN KEY (niche_id) REFERENCES public.niches(id) DEFERRABLE;


--
-- Name: commission_tiers commission_tiers_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.commission_tiers
    ADD CONSTRAINT commission_tiers_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id) DEFERRABLE;


--
-- Name: complaints complaints_assigned_csr_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.complaints
    ADD CONSTRAINT complaints_assigned_csr_id_fkey FOREIGN KEY (assigned_csr_id) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: complaints complaints_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.complaints
    ADD CONSTRAINT complaints_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) DEFERRABLE;


--
-- Name: complaints complaints_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.complaints
    ADD CONSTRAINT complaints_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) DEFERRABLE;


--
-- Name: complaints complaints_resolved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.complaints
    ADD CONSTRAINT complaints_resolved_by_fkey FOREIGN KEY (resolved_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: csr_level_history csr_level_history_changed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.csr_level_history
    ADD CONSTRAINT csr_level_history_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: csr_level_history csr_level_history_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.csr_level_history
    ADD CONSTRAINT csr_level_history_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: csr_performance_monthly csr_performance_monthly_commission_tier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.csr_performance_monthly
    ADD CONSTRAINT csr_performance_monthly_commission_tier_id_fkey FOREIGN KEY (commission_tier_id) REFERENCES public.commission_tiers(id) DEFERRABLE;


--
-- Name: csr_performance_monthly csr_performance_monthly_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.csr_performance_monthly
    ADD CONSTRAINT csr_performance_monthly_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id) DEFERRABLE;


--
-- Name: csr_performance_monthly csr_performance_monthly_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.csr_performance_monthly
    ADD CONSTRAINT csr_performance_monthly_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: csr_promotion_thresholds csr_promotion_thresholds_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.csr_promotion_thresholds
    ADD CONSTRAINT csr_promotion_thresholds_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id) DEFERRABLE;


--
-- Name: customers customers_banned_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_banned_by_fkey FOREIGN KEY (banned_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: department_targets department_targets_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.department_targets
    ADD CONSTRAINT department_targets_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id) DEFERRABLE;


--
-- Name: department_targets department_targets_set_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.department_targets
    ADD CONSTRAINT department_targets_set_by_fkey FOREIGN KEY (set_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: employee_profiles employee_profiles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.employee_profiles
    ADD CONSTRAINT employee_profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: escalation_reason_codes escalation_reason_codes_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.escalation_reason_codes
    ADD CONSTRAINT escalation_reason_codes_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: expenses expenses_admin_level_1_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_admin_level_1_id_fkey FOREIGN KEY (admin_level_1_id) REFERENCES public.admin_level_1(id) DEFERRABLE;


--
-- Name: expenses expenses_agent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES public.agents(id) DEFERRABLE;


--
-- Name: expenses expenses_expense_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_expense_category_id_fkey FOREIGN KEY (expense_category_id) REFERENCES public.expense_categories(id) DEFERRABLE;


--
-- Name: expenses expenses_logged_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_logged_by_fkey FOREIGN KEY (logged_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: expenses expenses_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) DEFERRABLE;


--
-- Name: goods_movement goods_movement_admin_level_1_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.goods_movement
    ADD CONSTRAINT goods_movement_admin_level_1_id_fkey FOREIGN KEY (admin_level_1_id) REFERENCES public.admin_level_1(id) DEFERRABLE;


--
-- Name: goods_movement goods_movement_from_agent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.goods_movement
    ADD CONSTRAINT goods_movement_from_agent_id_fkey FOREIGN KEY (from_agent_id) REFERENCES public.agents(id) DEFERRABLE;


--
-- Name: goods_movement goods_movement_logged_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.goods_movement
    ADD CONSTRAINT goods_movement_logged_by_fkey FOREIGN KEY (logged_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: goods_movement goods_movement_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.goods_movement
    ADD CONSTRAINT goods_movement_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) DEFERRABLE;


--
-- Name: goods_movement goods_movement_shipping_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.goods_movement
    ADD CONSTRAINT goods_movement_shipping_type_id_fkey FOREIGN KEY (shipping_type_id) REFERENCES public.shipping_types(id) DEFERRABLE;


--
-- Name: goods_movement goods_movement_to_agent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.goods_movement
    ADD CONSTRAINT goods_movement_to_agent_id_fkey FOREIGN KEY (to_agent_id) REFERENCES public.agents(id) DEFERRABLE;


--
-- Name: goods_movement goods_movement_variant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.goods_movement
    ADD CONSTRAINT goods_movement_variant_id_fkey FOREIGN KEY (variant_id) REFERENCES public.product_variants(id) DEFERRABLE;


--
-- Name: inventory inventory_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.inventory
    ADD CONSTRAINT inventory_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) DEFERRABLE;


--
-- Name: inventory inventory_variant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.inventory
    ADD CONSTRAINT inventory_variant_id_fkey FOREIGN KEY (variant_id) REFERENCES public.product_variants(id) DEFERRABLE;


--
-- Name: investment_inflow investment_inflow_logged_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.investment_inflow
    ADD CONSTRAINT investment_inflow_logged_by_fkey FOREIGN KEY (logged_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: lesson_categories lesson_categories_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.lesson_categories
    ADD CONSTRAINT lesson_categories_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: lessons_learned lessons_learned_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.lessons_learned
    ADD CONSTRAINT lessons_learned_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.lesson_categories(id) DEFERRABLE;


--
-- Name: lessons_learned lessons_learned_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.lessons_learned
    ADD CONSTRAINT lessons_learned_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: lessons_learned lessons_learned_submitted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.lessons_learned
    ADD CONSTRAINT lessons_learned_submitted_by_fkey FOREIGN KEY (submitted_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: loans loans_logged_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.loans
    ADD CONSTRAINT loans_logged_by_fkey FOREIGN KEY (logged_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: notifications notifications_recipient_agent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_recipient_agent_id_fkey FOREIGN KEY (recipient_agent_id) REFERENCES public.agents(id) DEFERRABLE;


--
-- Name: notifications notifications_recipient_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_recipient_user_id_fkey FOREIGN KEY (recipient_user_id) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: order_bump_inventory order_bump_inventory_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.order_bump_inventory
    ADD CONSTRAINT order_bump_inventory_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) DEFERRABLE;


--
-- Name: order_bump_inventory order_bump_inventory_variant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.order_bump_inventory
    ADD CONSTRAINT order_bump_inventory_variant_id_fkey FOREIGN KEY (variant_id) REFERENCES public.product_variants(id) DEFERRABLE;


--
-- Name: order_escalations order_escalations_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.order_escalations
    ADD CONSTRAINT order_escalations_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) DEFERRABLE;


--
-- Name: order_escalations order_escalations_raised_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.order_escalations
    ADD CONSTRAINT order_escalations_raised_by_fkey FOREIGN KEY (raised_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: order_escalations order_escalations_reason_code_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.order_escalations
    ADD CONSTRAINT order_escalations_reason_code_id_fkey FOREIGN KEY (reason_code_id) REFERENCES public.escalation_reason_codes(id) DEFERRABLE;


--
-- Name: order_escalations order_escalations_resolved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.order_escalations
    ADD CONSTRAINT order_escalations_resolved_by_fkey FOREIGN KEY (resolved_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: order_status_history order_status_history_changed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.order_status_history
    ADD CONSTRAINT order_status_history_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: order_status_history order_status_history_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.order_status_history
    ADD CONSTRAINT order_status_history_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) DEFERRABLE;


--
-- Name: orders orders_admin_level_1_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_admin_level_1_id_fkey FOREIGN KEY (admin_level_1_id) REFERENCES public.admin_level_1(id) DEFERRABLE;


--
-- Name: orders orders_admin_level_2_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_admin_level_2_id_fkey FOREIGN KEY (admin_level_2_id) REFERENCES public.admin_level_2(id) DEFERRABLE;


--
-- Name: orders orders_agent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES public.agents(id) DEFERRABLE;


--
-- Name: orders orders_assigned_csr_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_assigned_csr_id_fkey FOREIGN KEY (assigned_csr_id) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: orders orders_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) DEFERRABLE;


--
-- Name: orders orders_country_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_country_id_fkey FOREIGN KEY (country_id) REFERENCES public.countries(id) DEFERRABLE;


--
-- Name: orders orders_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) DEFERRABLE;


--
-- Name: orders orders_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id) DEFERRABLE;


--
-- Name: orders orders_failure_reason_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_failure_reason_id_fkey FOREIGN KEY (failure_reason_id) REFERENCES public.failure_reason_codes(id) DEFERRABLE;


--
-- Name: orders orders_niche_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_niche_id_fkey FOREIGN KEY (niche_id) REFERENCES public.niches(id) DEFERRABLE;


--
-- Name: orders orders_order_bump_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_order_bump_product_id_fkey FOREIGN KEY (order_bump_product_id) REFERENCES public.products(id) DEFERRABLE;


--
-- Name: orders orders_order_bump_variant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_order_bump_variant_id_fkey FOREIGN KEY (order_bump_variant_id) REFERENCES public.product_variants(id) DEFERRABLE;


--
-- Name: orders orders_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) DEFERRABLE;


--
-- Name: orders orders_product_variant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_product_variant_id_fkey FOREIGN KEY (product_variant_id) REFERENCES public.product_variants(id) DEFERRABLE;


--
-- Name: orders orders_shipping_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_shipping_type_id_fkey FOREIGN KEY (shipping_type_id) REFERENCES public.shipping_types(id) DEFERRABLE;


--
-- Name: orders orders_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.order_sources(id) DEFERRABLE;


--
-- Name: pabbly_reconciliation_log pabbly_reconciliation_log_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.pabbly_reconciliation_log
    ADD CONSTRAINT pabbly_reconciliation_log_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: payroll payroll_director_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.payroll
    ADD CONSTRAINT payroll_director_approved_by_fkey FOREIGN KEY (director_approved_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: payroll payroll_logged_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.payroll
    ADD CONSTRAINT payroll_logged_by_fkey FOREIGN KEY (logged_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: payroll payroll_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.payroll
    ADD CONSTRAINT payroll_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: procurement_expenses procurement_expenses_logged_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.procurement_expenses
    ADD CONSTRAINT procurement_expenses_logged_by_fkey FOREIGN KEY (logged_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: procurement_expenses procurement_expenses_niche_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.procurement_expenses
    ADD CONSTRAINT procurement_expenses_niche_id_fkey FOREIGN KEY (niche_id) REFERENCES public.niches(id) DEFERRABLE;


--
-- Name: procurement_expenses procurement_expenses_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.procurement_expenses
    ADD CONSTRAINT procurement_expenses_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) DEFERRABLE;


--
-- Name: procurement_expenses procurement_expenses_vendor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.procurement_expenses
    ADD CONSTRAINT procurement_expenses_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES public.vendors(id) DEFERRABLE;


--
-- Name: product_variants product_variants_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.product_variants
    ADD CONSTRAINT product_variants_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) DEFERRABLE;


--
-- Name: products products_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) DEFERRABLE;


--
-- Name: products products_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id) DEFERRABLE;


--
-- Name: session_log session_log_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.session_log
    ADD CONSTRAINT session_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: stock_adjustments stock_adjustments_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.stock_adjustments
    ADD CONSTRAINT stock_adjustments_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: stock_adjustments stock_adjustments_logged_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.stock_adjustments
    ADD CONSTRAINT stock_adjustments_logged_by_fkey FOREIGN KEY (logged_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: stock_adjustments stock_adjustments_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.stock_adjustments
    ADD CONSTRAINT stock_adjustments_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) DEFERRABLE;


--
-- Name: stock_adjustments stock_adjustments_variant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.stock_adjustments
    ADD CONSTRAINT stock_adjustments_variant_id_fkey FOREIGN KEY (variant_id) REFERENCES public.product_variants(id) DEFERRABLE;


--
-- Name: taxes taxes_logged_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.taxes
    ADD CONSTRAINT taxes_logged_by_fkey FOREIGN KEY (logged_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: trashed_items trashed_items_admin_level_1_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.trashed_items
    ADD CONSTRAINT trashed_items_admin_level_1_id_fkey FOREIGN KEY (admin_level_1_id) REFERENCES public.admin_level_1(id) DEFERRABLE;


--
-- Name: trashed_items trashed_items_agent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.trashed_items
    ADD CONSTRAINT trashed_items_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES public.agents(id) DEFERRABLE;


--
-- Name: trashed_items trashed_items_logged_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.trashed_items
    ADD CONSTRAINT trashed_items_logged_by_fkey FOREIGN KEY (logged_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: trashed_items trashed_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.trashed_items
    ADD CONSTRAINT trashed_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) DEFERRABLE;


--
-- Name: trashed_items trashed_items_variant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.trashed_items
    ADD CONSTRAINT trashed_items_variant_id_fkey FOREIGN KEY (variant_id) REFERENCES public.product_variants(id) DEFERRABLE;


--
-- Name: user_departments user_departments_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.user_departments
    ADD CONSTRAINT user_departments_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id) DEFERRABLE;


--
-- Name: user_departments user_departments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.user_departments
    ADD CONSTRAINT user_departments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: users users_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: users users_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id) DEFERRABLE;


--
-- Name: vendors vendors_admin_level_1_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT vendors_admin_level_1_id_fkey FOREIGN KEY (admin_level_1_id) REFERENCES public.admin_level_1(id) DEFERRABLE;


--
-- Name: vendors vendors_admin_level_2_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT vendors_admin_level_2_id_fkey FOREIGN KEY (admin_level_2_id) REFERENCES public.admin_level_2(id) DEFERRABLE;


--
-- Name: vendors vendors_country_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT vendors_country_id_fkey FOREIGN KEY (country_id) REFERENCES public.countries(id) DEFERRABLE;


--
-- Name: wati_export_queue wati_export_queue_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.wati_export_queue
    ADD CONSTRAINT wati_export_queue_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id);


--
-- Name: waybill_expenses waybill_expenses_agent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.waybill_expenses
    ADD CONSTRAINT waybill_expenses_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES public.agents(id) DEFERRABLE;


--
-- Name: waybill_expenses waybill_expenses_from_admin_level_1_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.waybill_expenses
    ADD CONSTRAINT waybill_expenses_from_admin_level_1_id_fkey FOREIGN KEY (from_admin_level_1_id) REFERENCES public.admin_level_1(id) DEFERRABLE;


--
-- Name: waybill_expenses waybill_expenses_logged_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.waybill_expenses
    ADD CONSTRAINT waybill_expenses_logged_by_fkey FOREIGN KEY (logged_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: waybill_expenses waybill_expenses_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.waybill_expenses
    ADD CONSTRAINT waybill_expenses_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) DEFERRABLE;


--
-- Name: waybill_expenses waybill_expenses_to_admin_level_1_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.waybill_expenses
    ADD CONSTRAINT waybill_expenses_to_admin_level_1_id_fkey FOREIGN KEY (to_admin_level_1_id) REFERENCES public.admin_level_1(id) DEFERRABLE;


--
-- Name: waybill_expenses waybill_expenses_variant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.waybill_expenses
    ADD CONSTRAINT waybill_expenses_variant_id_fkey FOREIGN KEY (variant_id) REFERENCES public.product_variants(id) DEFERRABLE;


--
-- Name: weekly_bonus_log weekly_bonus_log_paid_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.weekly_bonus_log
    ADD CONSTRAINT weekly_bonus_log_paid_by_fkey FOREIGN KEY (paid_by) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: weekly_bonus_log weekly_bonus_log_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.weekly_bonus_log
    ADD CONSTRAINT weekly_bonus_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: weekly_reports weekly_reports_csr_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.weekly_reports
    ADD CONSTRAINT weekly_reports_csr_id_fkey FOREIGN KEY (csr_id) REFERENCES public.users(id) DEFERRABLE;


--
-- Name: weekly_reports weekly_reports_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.weekly_reports
    ADD CONSTRAINT weekly_reports_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id) DEFERRABLE;


--
-- Name: weekly_reports weekly_reports_generated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jamisan_admin
--

ALTER TABLE ONLY public.weekly_reports
    ADD CONSTRAINT weekly_reports_generated_by_fkey FOREIGN KEY (generated_by) REFERENCES public.users(id) DEFERRABLE;


--
-- PostgreSQL database dump complete
--

\unrestrict ycya37egdNQ1ck9A1q8gz4YlVhzqXFIJBhFEUIbduzNmhmJWhQy0fiqHUjINPpB

