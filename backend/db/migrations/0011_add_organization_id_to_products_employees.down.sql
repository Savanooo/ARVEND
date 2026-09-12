DROP INDEX IF EXISTS idx_attendance_logs_organization_id;
ALTER TABLE attendance_logs DROP COLUMN organization_id;

DROP INDEX IF EXISTS idx_employees_organization_id;
ALTER TABLE employees DROP COLUMN organization_id;

DROP INDEX IF EXISTS idx_products_organization_id;
ALTER TABLE products DROP COLUMN organization_id;
