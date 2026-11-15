-- Tenant #1: Troika Dairy Products Pvt Ltd (Dugdh Dhara)
-- Masters that are settings, not code: price levels, units, categories,
-- customer categories, roles, locations, default credit limits.
-- Run as a superuser/owner (bypasses RLS) right after the migrations.

BEGIN;
SET search_path = kwik, public;

INSERT INTO tenant (code, name) VALUES ('TROIKA', 'Troika Dairy Products Pvt Ltd');

-- Every row below belongs to this tenant.
CREATE TEMP TABLE t AS SELECT id FROM tenant WHERE code = 'TROIKA';

INSERT INTO company (tenant_id, code, legal_name, state_code, address, email, invoice_footer)
SELECT id, 'TDPPL', 'Troika Dairy Products Pvt Ltd', '10',
       'Dugdh Dhara, Vill + PO Amhara, near Amhara Pustakalaya, Block + PS Bihta, Patna 801103',
       'contact@dugdhdhara.com', 'Thank you! Dugdh Dhara - Dairy, Sweets, Namkeen'
  FROM t;
-- GSTIN and FSSAI numbers are entered from the admin screen, not seeded.

-- Price levels (open-ended: add rows for new channels)
INSERT INTO price_level (tenant_id, code, name, sort_order)
SELECT t.id, v.code, v.name, v.ord FROM t, (VALUES
  ('CONSUMER',    'Consumer (MRP)', 1),
  ('RETAILER',    'Retailer',       2),
  ('DISTRIBUTOR', 'Distributor',    3),
  ('FRANCHISE',   'Franchisee',     4),
  ('SPECIAL',     'Special rate',   5)) AS v(code, name, ord);

INSERT INTO unit (tenant_id, code, name, decimals)
SELECT t.id, v.code, v.name, v.dec FROM t, (VALUES
  ('PC',   'Piece',  0),
  ('KG',   'Kg',     3),
  ('L',    'Litre',  3),
  ('TRAY', 'Tray',   0),
  ('BOX',  'Box',    0)) AS v(code, name, dec);

INSERT INTO item_category (tenant_id, code, name, sort_order, pos_colour)
SELECT t.id, v.code, v.name, v.ord, v.colour FROM t, (VALUES
  ('MILK',           'Milk',               1, '#DDEBF7'),
  ('DAHI',           'Dahi',               2, '#E2F0D9'),
  ('DAHI_BULK',      'Dahi bulk',          3, '#E2F0D9'),
  ('LASSI',          'Lassi',              4, '#FFF2CC'),
  ('FLAV_MILK',      'Flavoured milk',     5, '#FFF2CC'),
  ('SWEETS_COUNTER', 'Counter sweets',     6, '#FCE4D6'),
  ('SWEETS_PACKED',  'Packed sweets',      7, '#FCE4D6'),
  ('PANEER',         'Paneer',             8, '#EDEDED'),
  ('KHOA',           'Khoa',               9, '#EDEDED'),
  ('GHEE',           'Ghee',              10, '#FFE699'),
  ('NAMKEEN',        'Namkeen & snacks',  11, '#F8CBAD'),
  ('BAKERY',         'Bakery',            12, '#E4DFEC'),
  ('FROZEN',         'Frozen',            13, '#D9E1F2'),
  ('THIRD_PARTY',    'Other brands',      14, '#D9D9D9'),
  ('PROCUREMENT',    'Centre supplies',   15, '#D9D9D9')) AS v(code, name, ord, colour);

-- Customer categories (open-ended) with their default price level
INSERT INTO customer_category (tenant_id, code, name, default_price_level_id, credit_allowed)
SELECT t.id, v.code, v.name, pl.id, v.credit
  FROM t, (VALUES
    ('CONSUMER',    'Consumer',    'CONSUMER',    true),
    ('RETAILER',    'Retailer',    'RETAILER',    true),
    ('DISTRIBUTOR', 'Distributor', 'DISTRIBUTOR', true),
    ('SAHYOGI',     'Sahyogi',     'RETAILER',    true),
    ('FRANCHISE',   'Franchisee',  'FRANCHISE',   true)) AS v(code, name, level, credit)
  JOIN price_level pl ON pl.code = v.level;

-- Default category credit limits: Rs 0 until management sets real values,
-- so every credit bill goes for approval rather than being silently allowed.
INSERT INTO credit_limit (tenant_id, customer_category_id, max_outstanding, max_days, note)
SELECT cc.tenant_id, cc.id, 0, NULL, 'Placeholder - set by management before go-live'
  FROM customer_category cc;

-- Locations
INSERT INTO location (tenant_id, company_id, code, name, kind, address, default_price_level_id)
SELECT t.id, c.id, v.code, v.name, v.kind, v.addr, pl.id
  FROM t
  JOIN company c ON c.code = 'TDPPL'
  JOIN price_level pl ON pl.code = 'CONSUMER',
  (VALUES
    ('PLANT', 'Amhara plant',           'plant',  'Vill + PO Amhara, Bihta, Patna 801103'),
    ('DD1',   'DD1 Amhara plant outlet','outlet', 'Amhara plant, Bihta'),
    ('DD2',   'DD2 Opp. NIELIT College','outlet', 'Plot 3, opp. NIELIT College, Kanpa-Bihta Road, Amhara'),
    ('DD3',   'DD3 Bihta',              'outlet', 'Opp. Dr Lalit Mohan Sharma, Bihta'),
    ('DD4',   'DD4 Gultera',            'outlet', 'Gultera'),
    ('DD5',   'DD5 Chiraura counter',   'outlet', 'Chiraura, Naubatpur')) AS v(code, name, kind, addr);
-- Bikram franchise is added after the company parlours are stable.

-- First pilot device: DD3, tablet T1
INSERT INTO device (tenant_id, location_id, code, name)
SELECT l.tenant_id, l.id, 'T1', 'DD3 counter tablet' FROM location l WHERE l.code = 'DD3';

-- Roles and permissions
INSERT INTO role (tenant_id, code, name, permissions)
SELECT t.id, v.code, v.name, v.perms FROM t, (VALUES
  ('OWNER',   'Owner',          ARRAY['*']),
  ('MANAGER', 'Manager',        ARRAY['bill.create','bill.cancel','price.override','discount.any',
                                      'credit.approve','credit.limit.set','report.all','stock.adjust',
                                      'customer.edit','shift.close.any']),
  ('OUTLET',  'Outlet manager', ARRAY['bill.create','bill.cancel','discount.small','report.outlet',
                                      'stock.receive','stock.count','customer.edit','shift.close.any']),
  ('CASHIER', 'Cashier',        ARRAY['bill.create','report.own_shift','customer.create'])) AS v(code, name, perms);

COMMIT;
