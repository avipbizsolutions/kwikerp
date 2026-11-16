-- Customer types can be switched off; rates and customer types are managed by
-- owners and managers (permission rates.manage).
SET search_path = kwik, public;
ALTER TABLE customer_category ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;
UPDATE role SET permissions = permissions || ARRAY['rates.manage']
 WHERE code = 'MANAGER' AND NOT ('rates.manage' = ANY (permissions));
