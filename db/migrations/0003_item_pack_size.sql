-- Pack size shown on the POS tile when the item name doesn't say it,
-- e.g. "500 ml" for "Milk Cow H". Free text, set per item by head office.
SET search_path = kwik, public;
ALTER TABLE item ADD COLUMN IF NOT EXISTS pack_size text;
