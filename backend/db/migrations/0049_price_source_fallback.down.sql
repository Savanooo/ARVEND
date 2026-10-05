DROP TABLE IF EXISTS price_source_snapshots;
ALTER TABLE organization_price_sources DROP COLUMN IF EXISTS last_list_as_of;
