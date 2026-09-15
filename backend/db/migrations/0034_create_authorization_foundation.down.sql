DROP TRIGGER IF EXISTS trg_project_users_check_org_consistency ON project_users;
DROP FUNCTION IF EXISTS project_users_check_org_consistency();
DROP FUNCTION IF EXISTS seed_system_roles_for_org(uuid);

DROP TABLE IF EXISTS project_users;

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_super_admin_has_no_org_role;
DROP INDEX IF EXISTS idx_users_organization_role;
ALTER TABLE users DROP COLUMN IF EXISTS organization_role_id;

DROP TABLE IF EXISTS role_permissions;

DROP TRIGGER IF EXISTS organization_roles_set_updated_at ON organization_roles;
DROP TABLE IF EXISTS organization_roles;

DROP TABLE IF EXISTS permissions;
