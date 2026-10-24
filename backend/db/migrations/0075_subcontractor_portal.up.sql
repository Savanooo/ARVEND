-- Taşeron Paneli, aşama 1 (2026-10; bkz. docs/taseron-paneli.md): taşeron
-- firmalar kendi hesaplarıyla girer, yalnızca kendi işlerini ve ödemelerini
-- görür.
--
-- Güvenlik modeli (varsayılan ret):
--   * users.supplier_id dolu = taşeron hesabı. Oturum kapısı (RequireOnboarded/
--     RequireActiveUser) bu hesabı yalnızca açıkça izin verilen uçlara
--     (kendi hesabı, bildirimler, telefon kaydı, /portal) geçirir.
--   * Taşeron rolü (subcontractor) işletme izni taşımaz: subcontractor.portal
--     + notifications.read.
--   * Proje izni subcontractor_project_access'tedir -- project_users'tan
--     BİLEREK ayrıdır (proje üyeliği proje uçlarını açar, bu açmaz).

INSERT INTO permissions (code, description, category) VALUES
    ('subcontractor.portal', 'Taşeron Paneli: kendi işlerini ve ödemelerini görme (yalnızca taşeron hesapları)', 'Taşeron')
ON CONFLICT (code) DO NOTHING;

-- Taşeron hesabı yalnızca kaba 'kullanici' rolünde olabilir (yönetici ya da
-- platform hesabı taşeron kartına bağlanamaz).
ALTER TABLE users
    ADD COLUMN supplier_id uuid REFERENCES suppliers(id),
    ADD CONSTRAINT users_supplier_only_kullanici CHECK (supplier_id IS NULL OR role = 'kullanici');
CREATE INDEX idx_users_supplier ON users (supplier_id) WHERE supplier_id IS NOT NULL;

-- Mevcut firmalara Taşeron sistem rolü.
INSERT INTO organization_roles (organization_id, code, name, description, is_system)
SELECT o.id, 'subcontractor', 'Taşeron',
       'Taşeron firmanın girişi: yalnızca kendi işlerini ve ödemelerini görür (Taşeron Paneli).', true
FROM organizations o
WHERE EXISTS (SELECT 1 FROM organization_roles r WHERE r.organization_id = o.id AND r.is_system)
ON CONFLICT (organization_id, code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN (VALUES ('subcontractor.portal'), ('notifications.read')) AS p(code)
WHERE orole.is_system AND orole.code = 'subcontractor'
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

-- Yeni firmalar: seed fonksiyonu (0074 gövdesi + Taşeron rolü).
CREATE OR REPLACE FUNCTION seed_system_roles_for_org(org_id uuid) RETURNS void AS $$
DECLARE
    r_owner uuid;
    r_admin uuid;
    r_legacy uuid;
    r_pm uuid;
    r_finance uuid;
    r_field uuid;
    r_subcontractor uuid;
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
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'subcontractor', 'Taşeron', 'Taşeron firmanın girişi: yalnızca kendi işlerini ve ödemelerini görür (Taşeron Paneli).', true)
    RETURNING id INTO r_subcontractor;

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_owner, code FROM permissions;
    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_admin, code FROM permissions;

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_legacy, code FROM permissions WHERE code IN (
        'projects.expenses.create',
        'projects.read', 'projects.create', 'projects.update',
        'projects.finance.read', 'projects.finance.manage',
        'projects.tasks.read', 'projects.tasks.create', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'projects.access.read',
        'offers.read', 'offers.create', 'offers.update', 'offers.approve', 'offers.delete',
        'calculations.read', 'products.read',
        'customers.read', 'customers.manage',
        'employees.read',
        'attendance.read', 'attendance.manage',
        'projects.budget.read', 'projects.budget.manage',
        'projects.cost_control.read', 'projects.cost_control.manage',
        'organization.cost_codes.read',
        'projects.contracts.read', 'projects.contracts.manage',
        'organization.suppliers.read',
        'projects.procurement.read', 'projects.procurement.manage', 'projects.procurement.receive',
        'projects.subcontracts.read', 'projects.subcontracts.manage',
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage',
        'projects.subcontract_payments.read',
        'inventory.read', 'inventory.manage',
        'notifications.read'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_pm, code FROM permissions WHERE code IN (
        'projects.expenses.create',
        'projects.read', 'projects.update',
        'projects.tasks.read', 'projects.tasks.create', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'projects.access.read',
        'calculations.read', 'products.read', 'customers.read',
        'projects.budget.read', 'projects.cost_control.read',
        'organization.cost_codes.read',
        'projects.contracts.read', 'projects.contracts.manage',
        'organization.suppliers.read',
        'projects.procurement.read', 'projects.procurement.manage', 'projects.procurement.receive',
        'projects.subcontracts.read', 'projects.subcontracts.manage',
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage',
        'projects.subcontract_payments.read',
        'inventory.read', 'inventory.manage',
        'notifications.read'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_finance, code FROM permissions WHERE code IN (
        'projects.expenses.create',
        'projects.read', 'projects.finance.read', 'projects.finance.manage',
        'projects.budget.read', 'projects.budget.manage', 'projects.budget.approve',
        'projects.cost_control.read', 'projects.cost_control.manage',
        'organization.cost_codes.read', 'organization.cost_codes.manage',
        'projects.contracts.read', 'projects.contracts.manage', 'projects.contracts.lifecycle',
        'organization.suppliers.read', 'organization.suppliers.manage',
        'projects.procurement.read', 'projects.procurement.manage', 'projects.procurement.approve',
        'projects.procurement.receive',
        'projects.subcontracts.read', 'projects.subcontracts.manage', 'projects.subcontracts.approve',
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage', 'projects.subcontract_claims.certify',
        'projects.subcontract_payments.read', 'projects.subcontract_payments.manage',
        'offers.internal_pricing.read', 'offers.internal_pricing.manage',
        'inventory.read', 'inventory.manage',
        'notifications.read'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_field, code FROM permissions WHERE code IN (
        'projects.expenses.create',
        'projects.read',
        'projects.tasks.read', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'attendance.read',
        'inventory.read',
        'notifications.read'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_subcontractor, code FROM permissions WHERE code IN (
        'subcontractor.portal',
        'notifications.read'
    );
END;
$$ LANGUAGE plpgsql;

-- Firmanın taşerona verdiği proje izni. Taşeron Paneli yalnızca bu
-- projelerdeki kendi kayıtlarını gösterir.
CREATE TABLE subcontractor_project_access (
    organization_id uuid NOT NULL REFERENCES organizations(id),
    supplier_id     uuid NOT NULL REFERENCES suppliers(id) ON DELETE CASCADE,
    project_id      uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    granted_by      uuid REFERENCES users(id) ON DELETE SET NULL,
    granted_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (supplier_id, project_id)
);
CREATE INDEX idx_subcontractor_project_access_project ON subcontractor_project_access (project_id);
