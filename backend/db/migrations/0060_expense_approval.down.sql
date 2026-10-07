-- Kişiye özel izin satırları da permissions'a FK taşır (migration 0044) --
-- önce onlar, sonra rol izinleri, en son izin kodunun kendisi.
DELETE FROM user_permission_overrides WHERE permission_code = 'projects.expenses.approve';
DELETE FROM role_permissions WHERE permission_code = 'projects.expenses.approve';
DELETE FROM permissions WHERE code = 'projects.expenses.approve';

-- seed_system_roles_for_org'u migration 0042'deki HALİNE geri döndür --
-- fonksiyon gövdesi 0042'nin up dosyasından birebir kopyalanmıştır.
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
        'attendance.read', 'attendance.manage',
        'projects.budget.read', 'projects.budget.manage',
        'projects.cost_control.read', 'projects.cost_control.manage',
        'organization.cost_codes.read',
        'projects.contracts.read', 'projects.contracts.manage',
        'organization.suppliers.read',
        'projects.procurement.read', 'projects.procurement.manage',
        'projects.subcontracts.read', 'projects.subcontracts.manage',
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage',
        'projects.subcontract_payments.read',
        'notifications.read'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_pm, code FROM permissions WHERE code IN (
        'projects.read', 'projects.update',
        'projects.tasks.read', 'projects.tasks.create', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'projects.access.read',
        'calculations.read', 'products.read', 'customers.read',
        'projects.budget.read', 'projects.cost_control.read',
        'organization.cost_codes.read',
        'projects.contracts.read', 'projects.contracts.manage',
        'organization.suppliers.read',
        'projects.procurement.read', 'projects.procurement.manage',
        'projects.subcontracts.read', 'projects.subcontracts.manage',
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage',
        'projects.subcontract_payments.read',
        'notifications.read'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_finance, code FROM permissions WHERE code IN (
        'projects.read', 'projects.finance.read', 'projects.finance.manage',
        'projects.budget.read', 'projects.budget.manage',
        'projects.cost_control.read', 'projects.cost_control.manage',
        'organization.cost_codes.read', 'organization.cost_codes.manage',
        'projects.contracts.read', 'projects.contracts.manage', 'projects.contracts.lifecycle',
        'organization.suppliers.read', 'organization.suppliers.manage',
        'projects.procurement.read', 'projects.procurement.manage', 'projects.procurement.approve',
        'projects.subcontracts.read', 'projects.subcontracts.manage', 'projects.subcontracts.approve',
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage', 'projects.subcontract_claims.certify',
        'projects.subcontract_payments.read', 'projects.subcontract_payments.manage',
        'offers.internal_pricing.read', 'offers.internal_pricing.manage',
        'notifications.read'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_field, code FROM permissions WHERE code IN (
        'projects.read',
        'projects.tasks.read', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'attendance.read',
        'notifications.read'
    );
END;
$$ LANGUAGE plpgsql;

-- Reddedilmiş masraflar onay kolonu olmadan yeniden toplamlara girerdi:
-- kararı kaybetmemek için İPTAL (void) olarak işaretlenir -- eski kodun
-- tanıdığı tek "sayılmaz" durumu budur. Onay bekleyenler eskisi gibi
-- sayılmaya başlar (onay akışından önceki davranış).
UPDATE project_expenses
SET voided_at = COALESCE(decided_at, now()),
    voided_by = decided_by,
    void_reason = left('Onay reddedildi' || CASE WHEN decision_note <> '' THEN ': ' || decision_note ELSE '' END, 500)
WHERE approval_status = 'rejected' AND voided_at IS NULL;

DROP INDEX IF EXISTS idx_expenses_pending;
ALTER TABLE project_expenses DROP CONSTRAINT IF EXISTS project_expenses_approval_status_check;
ALTER TABLE project_expenses
    DROP COLUMN IF EXISTS decision_note,
    DROP COLUMN IF EXISTS decided_at,
    DROP COLUMN IF EXISTS decided_by,
    DROP COLUMN IF EXISTS approval_status;
