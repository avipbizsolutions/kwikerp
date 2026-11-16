-- Company product photos (small JPEGs) and a version per item so tablets
-- download only photos that changed.
SET search_path = kwik, public;
ALTER TABLE item ADD COLUMN IF NOT EXISTS image_version text;

CREATE TABLE IF NOT EXISTS item_image (
  item_id     uuid PRIMARY KEY REFERENCES item(id),
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  mime        text NOT NULL,
  data        bytea NOT NULL,
  updated_by  uuid REFERENCES app_user(id),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE item_image ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'item_image' AND policyname = 'tenant_isolation') THEN
    CREATE POLICY tenant_isolation ON item_image
      USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant());
  END IF;
END $$;
GRANT SELECT, INSERT, UPDATE, DELETE ON item_image TO kwik_app;
