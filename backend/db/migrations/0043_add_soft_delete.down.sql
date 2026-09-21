DROP INDEX IF EXISTS idx_organizations_deleted_at;
DROP INDEX IF EXISTS idx_users_deleted_at;

ALTER TABLE organizations DROP COLUMN deleted_by;
ALTER TABLE organizations DROP COLUMN deleted_at;

ALTER TABLE users DROP COLUMN deleted_by;
ALTER TABLE users DROP COLUMN deleted_at;
