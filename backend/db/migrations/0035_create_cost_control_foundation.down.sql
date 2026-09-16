-- role_permissions satırları, permissions silinince CASCADE ile zaten
-- kaybolur (role_permissions.permission_code -> permissions.code FK,
-- migration 0034: role_permissions.organization_role_id ON DELETE
-- CASCADE tanımlı, permission_code için CASCADE tanımlı DEĞİL -- bu
-- yüzden permissions'ı silmeden ÖNCE role_permissions satırlarını açıkça
-- temizliyoruz).
DELETE FROM role_permissions WHERE permission_code IN (
    'projects.budget.read', 'projects.budget.manage',
    'projects.cost_control.read', 'projects.cost_control.manage',
    'organization.cost_codes.read', 'organization.cost_codes.manage'
);

DELETE FROM permissions WHERE code IN (
    'projects.budget.read', 'projects.budget.manage',
    'projects.cost_control.read', 'projects.cost_control.manage',
    'organization.cost_codes.read', 'organization.cost_codes.manage'
);

-- seed_system_roles_for_org'u migration 0034'teki HALİNE geri döndür
-- (yeni izin WHERE IN listeleri olmadan) -- fonksiyon gövdesi 0034'ten
-- birebir kopyalanmıştır.
CREATE OR REPLACE FUNCTION seed_system_roles_for_org(org_id uuid) RETURNS void AS $$
DECLARE
    r_owner uuid;
    r_admin uuid;
    r_legacy uuid;
    r_pm uuid;
    r_finance uuid;
    r_field uuid;
BEGIN
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'owner', 'Sahip (Owner)', 'Firmadaki tüm izinlere sahiptir; son sahip kaldırılamaz.', true)
    RETURNING id INTO r_owner;
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'admin', 'Yönetici', 'Firmadaki tüm izinlere sahiptir.', true)
    RETURNING id INTO r_admin;
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'legacy_user', 'Kullanıcı (Eski Sistem)', 'Migration öncesi "kullanıcı" rolünün izin karşılığı -- yeni kullanıcılara atanmaz.', true)
    RETURNING id INTO r_legacy;
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'project_manager', 'Proje Yöneticisi', 'Yalnızca atandığı projelerde operasyonel yönetim yapar.', true)
    RETURNING id INTO r_pm;
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'finance', 'Finans', 'Yalnızca atandığı projelerin finansal verilerini yönetir.', true)
    RETURNING id INTO r_finance;
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'field', 'Saha', 'Yalnızca atandığı projelerde saha operasyonu (görev/dosya/fotoğraf) yapar.', true)
    RETURNING id INTO r_field;

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_owner, code FROM permissions;
    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_admin, code FROM permissions;

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_legacy, code FROM permissions WHERE code IN (
        'projects.read', 'projects.create', 'projects.update',
        'projects.finance.read', 'projects.finance.manage',
        'projects.tasks.read', 'projects.tasks.create', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'projects.access.read',
        'offers.read', 'offers.create', 'offers.update', 'offers.approve', 'offers.delete',
        'calculations.read', 'products.read',
        'customers.read', 'customers.manage',
        'employees.read',
        'attendance.read', 'attendance.manage'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_pm, code FROM permissions WHERE code IN (
        'projects.read', 'projects.update',
        'projects.tasks.read', 'projects.tasks.create', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'projects.access.read',
        'calculations.read', 'products.read', 'customers.read'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_finance, code FROM permissions WHERE code IN (
        'projects.read', 'projects.finance.read', 'projects.finance.manage'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_field, code FROM permissions WHERE code IN (
        'projects.read',
        'projects.tasks.read', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'attendance.read'
    );
END;
$$ LANGUAGE plpgsql;

DROP TABLE IF EXISTS organization_events;

ALTER TABLE project_subcontractors DROP COLUMN IF EXISTS cost_code_id;

ALTER TABLE project_expenses DROP COLUMN IF EXISTS budget_line_id;
ALTER TABLE project_expenses DROP COLUMN IF EXISTS cost_code_id;

DROP TABLE IF EXISTS project_cost_forecasts;

DROP TRIGGER IF EXISTS trg_project_commitments_check_consistency ON project_commitments;
DROP FUNCTION IF EXISTS project_commitments_check_consistency();
DROP TABLE IF EXISTS project_commitments;

DROP TABLE IF EXISTS project_budget_adjustments;

DROP TRIGGER IF EXISTS trg_project_budget_lines_check_consistency ON project_budget_lines;
DROP FUNCTION IF EXISTS project_budget_lines_check_consistency();
DROP TABLE IF EXISTS project_budget_lines;

DROP TABLE IF EXISTS project_budgets;

DROP TRIGGER IF EXISTS trg_project_wbs_nodes_check_consistency ON project_wbs_nodes;
DROP FUNCTION IF EXISTS project_wbs_nodes_check_consistency();
DROP TABLE IF EXISTS project_wbs_nodes;

DROP TABLE IF EXISTS organization_cost_codes;
