-- Fills item.pack_size on a database where 0002 ran before the column existed.
-- Same source as 0002: db/seed/troika_items.csv (built by tools/build_item_master.py).
-- Run from the repository root.
BEGIN;
SET search_path = kwik, public;
CREATE TEMP TABLE stg_size (
  code text, name text, sheet_category text, category_code text, kind text,
  base_unit text, sold_by_weight text, trade_unit text, trade_factor numeric,
  pack_note text, pack_size text, pack_status text, hsn text, gst_rate numeric, gst_status text,
  shelf_life_days int, order_multiple numeric, reorder_level numeric,
  is_active text, show_on_pos text, notes text);
\copy stg_size FROM 'db/seed/troika_items.csv' WITH (FORMAT csv, HEADER true)
UPDATE item i SET pack_size = nullif(s.pack_size, ''), updated_at = now()
  FROM stg_size s, tenant tn
 WHERE tn.code = 'TROIKA' AND i.tenant_id = tn.id AND i.code = s.code
   AND i.pack_size IS DISTINCT FROM nullif(s.pack_size, '');
COMMIT;
