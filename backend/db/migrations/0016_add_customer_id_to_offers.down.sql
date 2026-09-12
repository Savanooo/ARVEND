DROP INDEX IF EXISTS idx_offers_customer_id;
ALTER TABLE offers DROP COLUMN customer_id;
