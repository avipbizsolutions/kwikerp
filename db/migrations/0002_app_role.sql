-- Group role the API connects through. It does not own the tables, so
-- row-level security applies to every query it makes.
-- Create the actual login on the server (not in the repo, it has a password):
--   CREATE ROLE kwik_api LOGIN PASSWORD '<strong password>' IN ROLE kwik_app;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kwik_app') THEN
    CREATE ROLE kwik_app NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA kwik TO kwik_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA kwik TO kwik_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA kwik TO kwik_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA kwik TO kwik_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA kwik GRANT SELECT, INSERT, UPDATE ON TABLES TO kwik_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA kwik GRANT USAGE, SELECT ON SEQUENCES TO kwik_app;

-- The tenant table has no tenant_id; the API only reads it to resolve the
-- company code at login.
REVOKE INSERT, UPDATE ON kwik.tenant FROM kwik_app;
