DROP INDEX IF EXISTS idx_collections_one_per_invoice;
ALTER TABLE project_collections DROP COLUMN IF EXISTS invoice_id;
