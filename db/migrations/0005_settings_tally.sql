-- Per-company settings (for now: Tally ledger names) and a log of Tally exports.
SET search_path = kwik, public;

CREATE TABLE IF NOT EXISTS tenant_setting (
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  key         text NOT NULL,
  value       jsonb NOT NULL,
  updated_by  uuid REFERENCES app_user(id),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, key)
);

CREATE TABLE IF NOT EXISTS tally_export (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  from_date   date NOT NULL,
  to_date     date NOT NULL,
  location_ids uuid[],                 -- NULL = all outlets
  vouchers    int NOT NULL,
  total       numeric(14,2) NOT NULL,
  exported_by uuid REFERENCES app_user(id),
  exported_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE tenant_setting ENABLE ROW LEVEL SECURITY;
ALTER TABLE tally_export ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'tenant_setting' AND policyname = 'tenant_isolation') THEN
    CREATE POLICY tenant_isolation ON tenant_setting
      USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant());
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'tally_export' AND policyname = 'tenant_isolation') THEN
    CREATE POLICY tenant_isolation ON tally_export
      USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant());
  END IF;
END $$;
GRANT SELECT, INSERT, UPDATE ON tenant_setting, tally_export TO kwik_app;
