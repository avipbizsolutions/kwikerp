-- When two limits for the same customer (or category) start on the same day,
-- the one set last wins. Happens when a limit is raised while approving a bill.
SET search_path = kwik, public;
CREATE OR REPLACE VIEW customer_credit_limit AS
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
         ORDER BY l.valid_from DESC, l.created_at DESC LIMIT 1) cl_c ON true
  LEFT JOIN LATERAL (
        SELECT * FROM credit_limit l
         WHERE l.customer_category_id = c.category_id AND l.deleted_at IS NULL
           AND l.valid_from <= current_date AND (l.valid_to IS NULL OR l.valid_to >= current_date)
         ORDER BY l.valid_from DESC, l.created_at DESC LIMIT 1) cl_g ON true;


-- Views check row-level security as the caller, not as their owner, so a
-- query through them can never see another tenant's rows.
ALTER VIEW customer_credit_limit SET (security_invoker = true);
ALTER VIEW customer_outstanding SET (security_invoker = true);
ALTER VIEW item_price_current SET (security_invoker = true);
ALTER VIEW stock_on_hand SET (security_invoker = true);
