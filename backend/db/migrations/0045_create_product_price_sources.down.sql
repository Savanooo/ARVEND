DROP TABLE IF EXISTS organization_price_source_category_markups;
DROP TABLE IF EXISTS organization_price_sources;

DROP INDEX IF EXISTS idx_products_org_source;
ALTER TABLE products DROP COLUMN IF EXISTS source_synced_at;
