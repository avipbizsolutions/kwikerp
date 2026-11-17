-- User types editable from the head-office page; stock movement between the
-- plant/godowns and counters (dispatch, receipt, return); stock adjustments
-- that need approval; stock counts; Accounts' outlet-day audit.
SET search_path = kwik, public;

-- User types (roles)
ALTER TABLE role ADD COLUMN IF NOT EXISTS all_locations boolean NOT NULL DEFAULT false; -- false: one location per login
ALTER TABLE role ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;
ALTER TABLE role ADD COLUMN IF NOT EXISTS description text;

-- Locations that send goods (plant, godowns) and where a counter gets goods from
ALTER TABLE location ADD COLUMN IF NOT EXISTS sends_goods boolean NOT NULL DEFAULT false;
ALTER TABLE location ADD COLUMN IF NOT EXISTS supply_from_id uuid REFERENCES location(id);

-- Company (entity) details
ALTER TABLE company ADD COLUMN IF NOT EXISTS brand_name text;
ALTER TABLE company ADD COLUMN IF NOT EXISTS pan text;

-- Dispatch (plant/godown -> counter) and return (counter -> plant/godown).
-- Quantities are in the item's base unit (pieces); packs are only for entry.
ALTER TABLE stock_transfer ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'dispatch';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'stock_transfer_kind_check') THEN
    ALTER TABLE stock_transfer ADD CONSTRAINT stock_transfer_kind_check CHECK (kind IN ('dispatch','return'));
  END IF;
END $$;
ALTER TABLE stock_transfer ADD COLUMN IF NOT EXISTS vehicle text;
ALTER TABLE stock_transfer ADD COLUMN IF NOT EXISTS driver text;
ALTER TABLE stock_transfer ADD COLUMN IF NOT EXISTS sent_at timestamptz;
ALTER TABLE stock_transfer ADD COLUMN IF NOT EXISTS has_difference boolean NOT NULL DEFAULT false;
ALTER TABLE stock_transfer_line ADD COLUMN IF NOT EXISTS line_no int NOT NULL DEFAULT 0;
ALTER TABLE stock_transfer_line ADD COLUMN IF NOT EXISTS reason text;   -- short, damaged, extra, wrong
CREATE INDEX IF NOT EXISTS stock_transfer_to ON stock_transfer (to_location_id, status);
CREATE INDEX IF NOT EXISTS stock_transfer_line_transfer ON stock_transfer_line (transfer_id);
CREATE INDEX IF NOT EXISTS stock_move_loc_item ON stock_move (location_id, item_id, move_date);

-- Stock adjustment requests. Stock changes only once approved.
CREATE TABLE IF NOT EXISTS stock_adjustment (
  id            uuid PRIMARY KEY,                 -- made on the tablet / page
  tenant_id     uuid NOT NULL REFERENCES tenant(id),
  location_id   uuid NOT NULL REFERENCES location(id),
  item_id       uuid NOT NULL REFERENCES item(id),
  qty           numeric(12,3) NOT NULL CHECK (qty <> 0), -- + found, - lost
  reason        text NOT NULL,                     -- wastage, expired, broken, count, sample, other
  note          text,
  value         numeric(12,2) NOT NULL DEFAULT 0,  -- at MRP, positive
  needs_owner   boolean NOT NULL DEFAULT false,
  count_id      uuid,                              -- set when it came from a stock count
  device_id     uuid REFERENCES device(id),
  requested_by  uuid NOT NULL REFERENCES app_user(id),
  requested_at  timestamptz NOT NULL DEFAULT now(),
  status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  decided_by    uuid REFERENCES app_user(id),
  decided_at    timestamptz,
  decision_note text,
  server_seq    bigint NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz
);
CREATE INDEX IF NOT EXISTS stock_adjustment_status ON stock_adjustment (status, location_id);

-- Stock counts (blind: the counter does not see the system quantity)
CREATE TABLE IF NOT EXISTS stock_count (
  id            uuid PRIMARY KEY,
  tenant_id     uuid NOT NULL REFERENCES tenant(id),
  location_id   uuid NOT NULL REFERENCES location(id),
  device_id     uuid REFERENCES device(id),
  counted_by    uuid NOT NULL REFERENCES app_user(id),
  started_at    timestamptz NOT NULL DEFAULT now(),
  finished_at   timestamptz NOT NULL DEFAULT now(),
  note          text,
  server_seq    bigint NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz
);
CREATE TABLE IF NOT EXISTS stock_count_line (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant(id),
  count_id      uuid NOT NULL REFERENCES stock_count(id),
  item_id       uuid NOT NULL REFERENCES item(id),
  counted       numeric(12,3) NOT NULL,
  system_qty    numeric(12,3) NOT NULL,            -- on hand when the count was finished
  server_seq    bigint NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz,
  UNIQUE (count_id, item_id)
);

-- Accounts' check of one outlet for one day
CREATE TABLE IF NOT EXISTS audit_day (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant(id),
  location_id   uuid NOT NULL REFERENCES location(id),
  day           date NOT NULL,
  status        text NOT NULL CHECK (status IN ('verified','query')),
  upi_matched   boolean NOT NULL DEFAULT false,
  note          text,
  checked_by    uuid NOT NULL REFERENCES app_user(id),
  checked_at    timestamptz NOT NULL DEFAULT now(),
  server_seq    bigint NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz,
  UNIQUE (location_id, day)
);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['stock_adjustment','stock_count','stock_count_line','audit_day'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = t || '_touch') THEN
      EXECUTE format('CREATE TRIGGER %I_touch BEFORE INSERT OR UPDATE ON kwik.%I
                      FOR EACH ROW EXECUTE FUNCTION kwik.touch_row()', t, t);
      EXECUTE format('CREATE INDEX %I_sync ON kwik.%I (tenant_id, server_seq)', t, t);
      EXECUTE format('ALTER TABLE kwik.%I ENABLE ROW LEVEL SECURITY', t);
      EXECUTE format('CREATE POLICY tenant_isolation ON kwik.%I
                      USING (tenant_id = kwik.current_tenant())
                      WITH CHECK (tenant_id = kwik.current_tenant())', t);
    END IF;
  END LOOP;
END $$;
GRANT SELECT, INSERT, UPDATE ON stock_adjustment, stock_count, stock_count_line, audit_day TO kwik_app;
