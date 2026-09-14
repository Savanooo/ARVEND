DROP INDEX IF EXISTS idx_offer_revision_items_calc_category;
ALTER TABLE offer_revision_items
    DROP COLUMN IF EXISTS calc_snapshot,
    DROP COLUMN IF EXISTS calc_category_id,
    DROP COLUMN IF EXISTS section_label,
    DROP COLUMN IF EXISTS unit;
