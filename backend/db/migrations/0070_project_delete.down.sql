DROP TABLE IF EXISTS project_delete_requests;
DELETE FROM user_permission_overrides WHERE permission_code = 'projects.delete';
DELETE FROM role_permissions WHERE permission_code = 'projects.delete';
DELETE FROM permissions WHERE code = 'projects.delete';
