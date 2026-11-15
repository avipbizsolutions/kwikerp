-- KwikERP core + Phase 1 (POS) schema
-- PostgreSQL 16
--
-- Design rules (see docs/data-model.md):
--   * Multi-tenant: every business table carries tenant_id; row-level security
--     isolates tenants using the session setting app.tenant_id.
--   * Offline-first: primary keys are UUIDs generated on the device, so a bill
--     created offline keeps its id when it syncs. Never use serial ids for
--     records a device can create.
--   * Sync: every syncable table has server_seq (set by trigger from one global
--     sequence on insert/update). Devices pull "everything with server_seq > my
--     cursor". Deletes are soft (deleted_at) so they sync too.
--   * Nothing business-specific is hard-coded: price levels, customer
--     categories, units, credit limits, commission rates are all rows.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS kwik;
SET search_path = kwik, public;

-- ---------------------------------------------------------------------------
-- Sync plumbing
-- ---------------------------------------------------------------------------

CREATE SEQUENCE sync_seq AS bigint;

CREATE FUNCTION touch_row() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.server_seq := nextval('kwik.sync_seq');
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- Helper: current tenant from the session (set by the API per request).
CREATE FUNCTION current_tenant() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('app.tenant_id', true), '')::uuid
$$;

-- ---------------------------------------------------------------------------
-- Tenancy and organisation
-- ---------------------------------------------------------------------------

CREATE TABLE tenant (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,              -- e.g. TROIKA
  name        text NOT NULL,
  settings    jsonb NOT NULL DEFAULT '{}',       -- tenant-wide switches
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- A legal entity that issues invoices (own GSTIN). One tenant may have several.
CREATE TABLE company (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  code        text NOT NULL,
  legal_name  text NOT NULL,
  gstin       text,
  state_code  char(2) NOT NULL,                  -- GST state code, Bihar = 10
  address     text,
  phone       text,
  email       text,
  fssai_no    text,
  invoice_footer text,
  server_seq  bigint NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  UNIQUE (tenant_id, code)
);

-- Any place that holds stock or does business: plant, outlet, franchise,
-- milk centre, godown.
CREATE TABLE location (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  company_id  uuid NOT NULL REFERENCES company(id),
  code        text NOT NULL,                     -- DD1, DD3, PLANT
  name        text NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('plant','outlet','franchise','centre','godown')),
  address     text,
  phone       text,
  fssai_no    text,
  default_price_level_id uuid,                   -- FK added below
  is_active   boolean NOT NULL DEFAULT true,
  server_seq  bigint NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  UNIQUE (tenant_id, code)
);

-- A tablet/phone registered to a location. Its code is part of every
-- document number it issues, so offline devices never clash.
CREATE TABLE device (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  location_id uuid NOT NULL REFERENCES location(id),
  code        text NOT NULL,                     -- T1, T2
  name        text,
  last_seen_at timestamptz,
  last_pull_seq bigint NOT NULL DEFAULT 0,
  is_active   boolean NOT NULL DEFAULT true,
  server_seq  bigint NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  UNIQUE (location_id, code)
);

-- ---------------------------------------------------------------------------
-- Users, roles, permissions
-- ---------------------------------------------------------------------------

CREATE TABLE role (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  code        text NOT NULL,                     -- OWNER, MANAGER, CASHIER
  name        text NOT NULL,
  permissions text[] NOT NULL DEFAULT '{}',      -- e.g. {'bill.create','price.override'}
  server_seq  bigint NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  UNIQUE (tenant_id, code)
);

CREATE TABLE app_user (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  name        text NOT NULL,
  phone       text NOT NULL,
  pin_hash    text,                              -- quick PIN login on tablets
  password_hash text,                            -- web/head-office login
  is_active   boolean NOT NULL DEFAULT true,
  server_seq  bigint NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  UNIQUE (tenant_id, phone)
);

-- Role assignment, optionally limited to one location (NULL = all).
CREATE TABLE user_role (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  user_id     uuid NOT NULL REFERENCES app_user(id),
  role_id     uuid NOT NULL REFERENCES role(id),
  location_id uuid REFERENCES location(id),
  server_seq  bigint NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz
);

-- ---------------------------------------------------------------------------
-- Item master
-- ---------------------------------------------------------------------------

CREATE TABLE unit (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  code        text NOT NULL,                     -- PC, KG, L, TRAY, BOX
  name        text NOT NULL,
  decimals    smallint NOT NULL DEFAULT 0,       -- 3 for KG/L, 0 for PC
  server_seq  bigint NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  UNIQUE (tenant_id, code)
);

CREATE TABLE item_category (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  parent_id   uuid REFERENCES item_category(id),
  code        text NOT NULL,
  name        text NOT NULL,
  sort_order  int NOT NULL DEFAULT 0,
  pos_colour  text,                              -- tile colour on the POS grid
  server_seq  bigint NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  UNIQUE (tenant_id, code)
);

CREATE TABLE item (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant(id),
  code          text NOT NULL,                   -- legacy ProdID kept here
  name          text NOT NULL,
  name_local    text,                            -- Hindi name for bills
  category_id   uuid NOT NULL REFERENCES item_category(id),
  kind          text NOT NULL DEFAULT 'own'
                CHECK (kind IN ('own','resale','supply','service')),
  base_unit_id  uuid NOT NULL REFERENCES unit(id),
  sold_by_weight boolean NOT NULL DEFAULT false, -- read scale / allow decimals
  hsn           text,
  gst_rate      numeric(5,2),                    -- NULL until confirmed
  cess_rate     numeric(5,2) NOT NULL DEFAULT 0,
  price_includes_tax boolean NOT NULL DEFAULT true,
  shelf_life_days int,
  track_batch   boolean NOT NULL DEFAULT false,
  order_multiple numeric(12,3) NOT NULL DEFAULT 1,
  reorder_level numeric(12,3),
  is_active     boolean NOT NULL DEFAULT true,
  show_on_pos   boolean NOT NULL DEFAULT true,
  pos_sort      int NOT NULL DEFAULT 0,
  image_url     text,
  server_seq    bigint NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz,
  UNIQUE (tenant_id, code)
);

-- Units an item is sold or moved in, with conversion to the base unit.
-- e.g. Dahi 200 g: base PC; TRAY factor 6.  Peda 250 g: base PC; KG factor 4.
CREATE TABLE item_pack (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  item_id     uuid NOT NULL REFERENCES item(id),
  unit_id     uuid NOT NULL REFERENCES unit(id),
  factor      numeric(14,6) NOT NULL CHECK (factor > 0),  -- base units per 1 of this unit
  barcode     text,
  is_default_sale  boolean NOT NULL DEFAULT false,   -- counter sale unit
  is_default_trade boolean NOT NULL DEFAULT false,   -- distributor/retailer unit
  server_seq  bigint NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  UNIQUE (item_id, unit_id)
);
CREATE INDEX item_pack_barcode ON item_pack (tenant_id, barcode) WHERE barcode IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Pricing: open-ended price levels with dated prices
-- ---------------------------------------------------------------------------

CREATE TABLE price_level (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  code        text NOT NULL,                     -- CONSUMER, RETAILER, ...
  name        text NOT NULL,
  sort_order  int NOT NULL DEFAULT 0,
  -- optional rule to derive missing prices: base level and % adjustment
  derive_from_id uuid REFERENCES price_level(id),
  derive_pct  numeric(6,2),
  is_active   boolean NOT NULL DEFAULT true,
  server_seq  bigint NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  UNIQUE (tenant_id, code)
);

ALTER TABLE location
  ADD CONSTRAINT location_price_level_fk FOREIGN KEY (default_price_level_id) REFERENCES price_level(id);

-- One price for an item, in a unit, at a level, from a date.
-- location_id NULL = applies everywhere; set it for an outlet/territory override.
CREATE TABLE item_price (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES tenant(id),
  item_id        uuid NOT NULL REFERENCES item(id),
  unit_id        uuid NOT NULL REFERENCES unit(id),
  price_level_id uuid NOT NULL REFERENCES price_level(id),
  location_id    uuid REFERENCES location(id),
  price          numeric(12,2) NOT NULL CHECK (price >= 0),
  valid_from     date NOT NULL,
  note           text,                           -- e.g. "rate chart 11.10.26"
  server_seq     bigint NOT NULL DEFAULT 0,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz
);
CREATE UNIQUE INDEX item_price_unique
  ON item_price (item_id, unit_id, price_level_id, coalesce(location_id, '00000000-0000-0000-0000-000000000000'::uuid), valid_from)
  WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- Customers and credit control
-- ---------------------------------------------------------------------------

-- Distributor, Retailer, Sahyogi, Consumer, Franchise ... (open-ended)
CREATE TABLE customer_category (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES tenant(id),
  code           text NOT NULL,
  name           text NOT NULL,
  default_price_level_id uuid NOT NULL REFERENCES price_level(id),
  credit_allowed boolean NOT NULL DEFAULT true,
  server_seq     bigint NOT NULL DEFAULT 0,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  UNIQUE (tenant_id, code)
);

CREATE TABLE customer (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES tenant(id),
  code           text,
  name           text NOT NULL,
  category_id    uuid NOT NULL REFERENCES customer_category(id),
  price_level_id uuid REFERENCES price_level(id), -- NULL = category default
  phone          text,
  gstin          text,
  state_code     char(2),
  address        text,
  home_location_id uuid REFERENCES location(id),  -- outlet/route that serves them
  security_amount numeric(12,2) NOT NULL DEFAULT 0, -- deposit/cheques held
  opening_balance numeric(12,2) NOT NULL DEFAULT 0,
  is_active      boolean NOT NULL DEFAULT true,
  server_seq     bigint NOT NULL DEFAULT 0,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz
);
CREATE INDEX customer_phone ON customer (tenant_id, phone);

-- Credit limit at category level (customer_id NULL) or customer level
-- (overrides category). Each check is optional (NULL = not checked).
CREATE TABLE credit_limit (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES tenant(id),
  customer_category_id uuid REFERENCES customer_category(id),
  customer_id        uuid REFERENCES customer(id),
  max_outstanding    numeric(12,2),            -- amount check
  max_days           int,                      -- oldest unpaid bill age
  cap_to_security    boolean NOT NULL DEFAULT false,
  valid_from         date NOT NULL DEFAULT current_date,
  valid_to           date,                     -- for temporary raises
  set_by             uuid REFERENCES app_user(id),
  note               text,
  server_seq         bigint NOT NULL DEFAULT 0,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  deleted_at         timestamptz,
  CHECK ((customer_category_id IS NULL) <> (customer_id IS NULL))
);

-- Approval request for a bill that breaks a credit limit.
CREATE TABLE credit_approval (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenant(id),
  invoice_id      uuid NOT NULL,                -- FK added after sales_invoice
  customer_id     uuid NOT NULL REFERENCES customer(id),
  location_id     uuid NOT NULL REFERENCES location(id),
  requested_by    uuid NOT NULL REFERENCES app_user(id),
  requested_at    timestamptz NOT NULL DEFAULT now(),
  reasons         text[] NOT NULL,              -- {'amount','days','security'}
  outstanding     numeric(12,2) NOT NULL,
  bill_amount     numeric(12,2) NOT NULL,
  limit_amount    numeric(12,2),
  oldest_due_days int,
  status          text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','approved','rejected','expired','withdrawn')),
  decision        text CHECK (decision IN ('once','raise_limit')),
  decided_by      uuid REFERENCES app_user(id),
  decided_at      timestamptz,
  decision_note   text,
  offline_request_code text,                    -- shown on tablet when offline
  server_seq      bigint NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz
);

-- ---------------------------------------------------------------------------
-- Document numbering (per location + device + doc type + financial year)
-- ---------------------------------------------------------------------------

CREATE TABLE doc_series (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  device_id   uuid NOT NULL REFERENCES device(id),
  doc_type    text NOT NULL,                     -- INV, RET, RCPT, TRF
  fin_year    text NOT NULL,                     -- '2627' for FY 2026-27
  prefix      text NOT NULL,                     -- DD3-T1-2627-
  last_no     int NOT NULL DEFAULT 0,            -- highest number synced
  server_seq  bigint NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (device_id, doc_type, fin_year)
);

-- ---------------------------------------------------------------------------
-- Shifts and sales
-- ---------------------------------------------------------------------------

CREATE TABLE shift (
  id              uuid PRIMARY KEY,              -- generated on device
  tenant_id       uuid NOT NULL REFERENCES tenant(id),
  location_id     uuid NOT NULL REFERENCES location(id),
  device_id       uuid NOT NULL REFERENCES device(id),
  user_id         uuid NOT NULL REFERENCES app_user(id),
  opened_at       timestamptz NOT NULL,
  opening_cash    numeric(12,2) NOT NULL DEFAULT 0,
  closed_at       timestamptz,
  counted_cash    numeric(12,2),
  expected_cash   numeric(12,2),
  note            text,
  server_seq      bigint NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz
);

CREATE TABLE sales_invoice (
  id              uuid PRIMARY KEY,              -- generated on device
  tenant_id       uuid NOT NULL REFERENCES tenant(id),
  company_id      uuid NOT NULL REFERENCES company(id),
  location_id     uuid NOT NULL REFERENCES location(id),
  device_id       uuid NOT NULL REFERENCES device(id),
  shift_id        uuid REFERENCES shift(id),
  doc_type        text NOT NULL DEFAULT 'INV' CHECK (doc_type IN ('INV','RET','EST')),
  doc_no          text,                          -- set when finalised
  doc_date        date NOT NULL,
  status          text NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft','held','pending_approval','final','cancelled')),
  customer_id     uuid REFERENCES customer(id),  -- NULL = walk-in
  price_level_id  uuid NOT NULL REFERENCES price_level(id),
  place_of_supply char(2) NOT NULL,
  against_invoice_id uuid REFERENCES sales_invoice(id),  -- for returns
  subtotal        numeric(12,2) NOT NULL DEFAULT 0, -- before discounts, incl. tax
  discount        numeric(12,2) NOT NULL DEFAULT 0,
  taxable         numeric(12,2) NOT NULL DEFAULT 0,
  cgst            numeric(12,2) NOT NULL DEFAULT 0,
  sgst            numeric(12,2) NOT NULL DEFAULT 0,
  igst            numeric(12,2) NOT NULL DEFAULT 0,
  cess            numeric(12,2) NOT NULL DEFAULT 0,
  round_off       numeric(6,2)  NOT NULL DEFAULT 0,
  total           numeric(12,2) NOT NULL DEFAULT 0,
  paid            numeric(12,2) NOT NULL DEFAULT 0,
  balance         numeric(12,2) NOT NULL DEFAULT 0, -- on credit
  created_by      uuid NOT NULL REFERENCES app_user(id),
  finalised_at    timestamptz,
  cancelled_by    uuid REFERENCES app_user(id),
  cancel_reason   text,
  note            text,
  server_seq      bigint NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz
);
CREATE UNIQUE INDEX sales_invoice_doc_no ON sales_invoice (tenant_id, doc_no) WHERE doc_no IS NOT NULL;
CREATE INDEX sales_invoice_loc_date ON sales_invoice (location_id, doc_date);
CREATE INDEX sales_invoice_customer ON sales_invoice (customer_id) WHERE customer_id IS NOT NULL;

ALTER TABLE credit_approval
  ADD CONSTRAINT credit_approval_invoice_fk FOREIGN KEY (invoice_id) REFERENCES sales_invoice(id);

CREATE TABLE sales_invoice_line (
  id              uuid PRIMARY KEY,
  tenant_id       uuid NOT NULL REFERENCES tenant(id),
  invoice_id      uuid NOT NULL REFERENCES sales_invoice(id),
  line_no         int NOT NULL,
  item_id         uuid NOT NULL REFERENCES item(id),
  unit_id         uuid NOT NULL REFERENCES unit(id),
  qty             numeric(12,3) NOT NULL,        -- in unit_id
  factor          numeric(14,6) NOT NULL,        -- base units per unit (copied)
  rate            numeric(12,2) NOT NULL,        -- price used (tax-inclusive if item says so)
  list_rate       numeric(12,2) NOT NULL,        -- price-list rate before override
  rate_overridden_by uuid REFERENCES app_user(id),
  discount        numeric(12,2) NOT NULL DEFAULT 0,
  hsn             text,
  gst_rate        numeric(5,2) NOT NULL DEFAULT 0,
  taxable         numeric(12,2) NOT NULL,
  cgst            numeric(12,2) NOT NULL DEFAULT 0,
  sgst            numeric(12,2) NOT NULL DEFAULT 0,
  igst            numeric(12,2) NOT NULL DEFAULT 0,
  cess            numeric(12,2) NOT NULL DEFAULT 0,
  amount          numeric(12,2) NOT NULL,        -- line total incl. tax
  batch_id        uuid,
  server_seq      bigint NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  UNIQUE (invoice_id, line_no)
);

-- Money received: against a bill at the counter, or later against dues.
CREATE TABLE receipt (
  id              uuid PRIMARY KEY,
  tenant_id       uuid NOT NULL REFERENCES tenant(id),
  location_id     uuid NOT NULL REFERENCES location(id),
  device_id       uuid REFERENCES device(id),
  shift_id        uuid REFERENCES shift(id),
  doc_no          text,
  doc_date        date NOT NULL,
  customer_id     uuid REFERENCES customer(id),
  invoice_id      uuid REFERENCES sales_invoice(id),
  mode            text NOT NULL CHECK (mode IN ('cash','upi','card','cheque','bank','adjust')),
  amount          numeric(12,2) NOT NULL,        -- negative for refunds
  reference       text,                          -- UPI ref, cheque no.
  created_by      uuid NOT NULL REFERENCES app_user(id),
  status          text NOT NULL DEFAULT 'final' CHECK (status IN ('final','cancelled')),
  server_seq      bigint NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz
);
CREATE INDEX receipt_customer ON receipt (customer_id) WHERE customer_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Stock (Phase 1b uses transfers, batches and counts; ledger used from 1a)
-- ---------------------------------------------------------------------------

CREATE TABLE batch (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  item_id     uuid NOT NULL REFERENCES item(id),
  batch_no    text NOT NULL,
  made_on     date,
  expires_on  date,
  server_seq  bigint NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  UNIQUE (item_id, batch_no)
);

ALTER TABLE sales_invoice_line
  ADD CONSTRAINT sales_invoice_line_batch_fk FOREIGN KEY (batch_id) REFERENCES batch(id);

-- Every stock change, in base units. Stock on hand = sum(qty).
CREATE TABLE stock_move (
  id          uuid PRIMARY KEY,
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  location_id uuid NOT NULL REFERENCES location(id),
  item_id     uuid NOT NULL REFERENCES item(id),
  batch_id    uuid REFERENCES batch(id),
  qty         numeric(14,3) NOT NULL,            -- + in, - out, base unit
  move_type   text NOT NULL CHECK (move_type IN
              ('opening','sale','sale_return','transfer_in','transfer_out',
               'purchase','wastage','adjustment','count')),
  doc_id      uuid,                              -- invoice/transfer/count id
  move_date   date NOT NULL,
  reason      text,
  created_by  uuid REFERENCES app_user(id),
  server_seq  bigint NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz
);
CREATE INDEX stock_move_loc_item ON stock_move (location_id, item_id);

CREATE TABLE stock_transfer (
  id               uuid PRIMARY KEY,
  tenant_id        uuid NOT NULL REFERENCES tenant(id),
  from_location_id uuid NOT NULL REFERENCES location(id),
  to_location_id   uuid NOT NULL REFERENCES location(id),
  doc_no           text,
  doc_date         date NOT NULL,
  status           text NOT NULL DEFAULT 'draft'
                   CHECK (status IN ('draft','dispatched','received','cancelled')),
  dispatched_by    uuid REFERENCES app_user(id),
  received_by      uuid REFERENCES app_user(id),
  received_at      timestamptz,
  note             text,
  server_seq       bigint NOT NULL DEFAULT 0,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz
);

CREATE TABLE stock_transfer_line (
  id            uuid PRIMARY KEY,
  tenant_id     uuid NOT NULL REFERENCES tenant(id),
  transfer_id   uuid NOT NULL REFERENCES stock_transfer(id),
  item_id       uuid NOT NULL REFERENCES item(id),
  unit_id       uuid NOT NULL REFERENCES unit(id),
  factor        numeric(14,6) NOT NULL,
  qty_sent      numeric(12,3) NOT NULL,
  qty_received  numeric(12,3),
  batch_id      uuid REFERENCES batch(id),
  server_seq    bigint NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz
);

-- ---------------------------------------------------------------------------
-- Audit
-- ---------------------------------------------------------------------------

CREATE TABLE audit_log (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  at          timestamptz NOT NULL DEFAULT now(),
  user_id     uuid REFERENCES app_user(id),
  device_id   uuid REFERENCES device(id),
  action      text NOT NULL,                     -- bill.cancel, price.override, limit.change
  entity      text NOT NULL,
  entity_id   uuid,
  detail      jsonb NOT NULL DEFAULT '{}'
);

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

-- Outstanding per customer: opening balance + bills on credit - receipts not
-- tied to a counter payment. Cancelled documents excluded.
CREATE VIEW customer_outstanding AS
SELECT c.tenant_id,
       c.id AS customer_id,
       c.opening_balance
       + coalesce((SELECT sum(CASE WHEN i.doc_type = 'RET' THEN -i.total ELSE i.total END)
                     FROM sales_invoice i
                    WHERE i.customer_id = c.id AND i.status = 'final' AND i.deleted_at IS NULL), 0)
       - coalesce((SELECT sum(r.amount)
                     FROM receipt r
                    WHERE r.customer_id = c.id AND r.status = 'final' AND r.deleted_at IS NULL), 0)
       AS outstanding
  FROM customer c;

-- Effective credit limit: customer row if one is valid today, else category.
CREATE VIEW customer_credit_limit AS
SELECT c.tenant_id,
       c.id AS customer_id,
       coalesce(cl_c.max_outstanding, CASE WHEN cl_c.id IS NULL THEN cl_g.max_outstanding END) AS max_outstanding,
       coalesce(cl_c.max_days,        CASE WHEN cl_c.id IS NULL THEN cl_g.max_days END)        AS max_days,
       coalesce(cl_c.cap_to_security, cl_g.cap_to_security, false)                             AS cap_to_security,
       CASE WHEN cl_c.id IS NOT NULL THEN 'customer'
            WHEN cl_g.id IS NOT NULL THEN 'category'
            ELSE 'none' END AS source
  FROM customer c
  LEFT JOIN LATERAL (
        SELECT * FROM credit_limit l
         WHERE l.customer_id = c.id AND l.deleted_at IS NULL
           AND l.valid_from <= current_date AND (l.valid_to IS NULL OR l.valid_to >= current_date)
         ORDER BY l.valid_from DESC LIMIT 1) cl_c ON true
  LEFT JOIN LATERAL (
        SELECT * FROM credit_limit l
         WHERE l.customer_category_id = c.category_id AND l.deleted_at IS NULL
           AND l.valid_from <= current_date AND (l.valid_to IS NULL OR l.valid_to >= current_date)
         ORDER BY l.valid_from DESC LIMIT 1) cl_g ON true;

-- Price in force today for each item/unit/level (all-location prices only;
-- the API applies location overrides on top).
CREATE VIEW item_price_current AS
SELECT DISTINCT ON (p.item_id, p.unit_id, p.price_level_id)
       p.tenant_id, p.item_id, p.unit_id, p.price_level_id, p.price, p.valid_from
  FROM item_price p
 WHERE p.location_id IS NULL AND p.deleted_at IS NULL AND p.valid_from <= current_date
 ORDER BY p.item_id, p.unit_id, p.price_level_id, p.valid_from DESC;

CREATE VIEW stock_on_hand AS
SELECT tenant_id, location_id, item_id, sum(qty) AS qty
  FROM stock_move WHERE deleted_at IS NULL
 GROUP BY tenant_id, location_id, item_id;

-- ---------------------------------------------------------------------------
-- Triggers and row-level security for every tenant table
-- ---------------------------------------------------------------------------

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'company','location','device','role','app_user','user_role','unit',
    'item_category','item','item_pack','price_level','item_price',
    'customer_category','customer','credit_limit','credit_approval',
    'doc_series','shift','sales_invoice','sales_invoice_line','receipt',
    'batch','stock_move','stock_transfer','stock_transfer_line']
  LOOP
    EXECUTE format('CREATE TRIGGER %I_touch BEFORE INSERT OR UPDATE ON kwik.%I
                    FOR EACH ROW EXECUTE FUNCTION kwik.touch_row()', t, t);
    EXECUTE format('CREATE INDEX %I_sync ON kwik.%I (tenant_id, server_seq)', t, t);
    EXECUTE format('ALTER TABLE kwik.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY tenant_isolation ON kwik.%I
                    USING (tenant_id = kwik.current_tenant())
                    WITH CHECK (tenant_id = kwik.current_tenant())', t);
  END LOOP;
  ALTER TABLE kwik.audit_log ENABLE ROW LEVEL SECURITY;
  CREATE POLICY tenant_isolation ON kwik.audit_log
    USING (tenant_id = kwik.current_tenant()) WITH CHECK (tenant_id = kwik.current_tenant());
END $$;

COMMIT;
