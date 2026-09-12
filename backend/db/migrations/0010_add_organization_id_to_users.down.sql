DROP INDEX IF EXISTS idx_users_organization_id;
ALTER TABLE users DROP COLUMN organization_id;
