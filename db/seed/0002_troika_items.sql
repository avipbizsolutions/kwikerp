-- Load the Troika item master and prices built by tools/build_item_master.py.
-- Run from the repository root:  psql -d kwikerp -f db/seed/0002_troika_items.sql

BEGIN;
SET search_path = kwik, public;

CREATE TEMP TABLE stg_item (
  code text, name text, sheet_category text, category_code text, kind text,
  base_unit text, sold_by_weight text, trade_unit text, trade_factor numeric,
  pack_note text, pack_status text, hsn text, gst_rate numeric, gst_status text,
  shelf_life_days int, order_multiple numeric, reorder_level numeric,
  is_active text, show_on_pos text, notes text);

CREATE TEMP TABLE stg_price (
  item_code text, unit text, level text, price numeric, valid_from date, source text);

\copy stg_item FROM 'db/seed/troika_items.csv' WITH (FORMAT csv, HEADER true)
\copy stg_price FROM 'db/seed/troika_prices.csv' WITH (FORMAT csv, HEADER true)

INSERT INTO item (tenant_id, code, name, category_id, kind, base_unit_id, sold_by_weight,
                  hsn, gst_rate, shelf_life_days, order_multiple, reorder_level,
                  is_active, show_on_pos, pos_sort)
SELECT tn.id, s.code, s.name, ic.id, s.kind, u.id, s.sold_by_weight = 'Y',
       nullif(s.hsn, ''), s.gst_rate, s.shelf_life_days, s.order_multiple, s.reorder_level,
       s.is_active = 'Y', s.show_on_pos = 'Y', s.code::int
  FROM stg_item s
  JOIN tenant tn ON tn.code = 'TROIKA'
  JOIN item_category ic ON ic.tenant_id = tn.id AND ic.code = s.category_code
  JOIN unit u ON u.tenant_id = tn.id AND u.code = s.base_unit;

-- Base unit pack (factor 1) for every item
INSERT INTO item_pack (tenant_id, item_id, unit_id, factor, is_default_sale, is_default_trade)
SELECT i.tenant_id, i.id, i.base_unit_id, 1, true, s.trade_unit = s.base_unit
  FROM item i JOIN stg_item s ON s.code = i.code;

-- Trade pack where the sheet unit differs (tray, box, litre, kg)
INSERT INTO item_pack (tenant_id, item_id, unit_id, factor, is_default_sale, is_default_trade)
SELECT i.tenant_id, i.id, u.id, s.trade_factor, false, true
  FROM item i
  JOIN stg_item s ON s.code = i.code AND s.trade_unit <> s.base_unit
  JOIN unit u ON u.tenant_id = i.tenant_id AND u.code = s.trade_unit;

INSERT INTO item_price (tenant_id, item_id, unit_id, price_level_id, price, valid_from, note)
SELECT i.tenant_id, i.id, u.id, pl.id, p.price, p.valid_from, p.source
  FROM stg_price p
  JOIN item i ON i.code = p.item_code
  JOIN unit u ON u.tenant_id = i.tenant_id AND u.code = p.unit
  JOIN price_level pl ON pl.tenant_id = i.tenant_id AND pl.code = p.level;

COMMIT;
