DROP TABLE IF EXISTS project_change_order_email_logs;
DROP TABLE IF EXISTS project_change_order_share_links;

DROP INDEX IF EXISTS idx_subcontractors_change_order;
ALTER TABLE project_subcontractors DROP COLUMN IF EXISTS change_order_id;

DROP INDEX IF EXISTS idx_expenses_change_order;
ALTER TABLE project_expenses DROP COLUMN IF EXISTS change_order_id;

DROP TABLE IF EXISTS project_change_order_items;
DROP TABLE IF EXISTS change_order_counters;
DROP TABLE IF EXISTS project_change_orders;
