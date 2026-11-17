-- User types after 17 Nov 2026: Outlet manager is renamed Store Manager;
-- new types Dispatch and Accounts. The plant sends goods to every outlet.
-- Everything here can be changed later on the head-office page.
BEGIN;
SET search_path = kwik, public;

UPDATE role SET all_locations = true WHERE code IN ('OWNER', 'MANAGER');

UPDATE role SET permissions = ARRAY(SELECT DISTINCT unnest(permissions || ARRAY[
    'stock.view.all','stock.dispatch','stock.return.confirm','stock.count','stock.adjust.request',
    'stock.adjust','audit.view','report.all']))
 WHERE code = 'MANAGER';

UPDATE role SET name = 'Store Manager',
       permissions = ARRAY(SELECT DISTINCT unnest(permissions || ARRAY[
         'stock.receive','stock.count','stock.adjust.request']))
 WHERE code = 'OUTLET';

UPDATE role SET permissions = ARRAY(SELECT DISTINCT unnest(permissions || ARRAY[
    'stock.receive','stock.adjust.request']))
 WHERE code = 'CASHIER';

INSERT INTO role (tenant_id, code, name, permissions, all_locations)
SELECT t.id, v.code, v.name, v.perms, v.all_loc
  FROM tenant t, (VALUES
    ('DISPATCH', 'Dispatch', ARRAY['stock.dispatch','stock.return.confirm','stock.view.all'], false),
    ('ACCOUNTS', 'Accounts', ARRAY['stock.view.all','stock.count','audit.verify','audit.view',
                                   'report.all','accounts.export'], true)) AS v(code, name, perms, all_loc)
 WHERE t.code = 'TROIKA'
ON CONFLICT (tenant_id, code) DO NOTHING;

UPDATE location SET sends_goods = true WHERE code = 'PLANT';
UPDATE location o SET supply_from_id = p.id
  FROM location p
 WHERE p.tenant_id = o.tenant_id AND p.code = 'PLANT' AND o.kind = 'outlet' AND o.supply_from_id IS NULL;

UPDATE company SET brand_name = 'Dugdh Dhara' WHERE code = 'TDPPL' AND brand_name IS NULL;

COMMIT;
