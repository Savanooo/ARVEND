-- Bütçe revizyonu onayı ayrı bir izin (ürün sahibi kararı, 2026-10-07).
--
-- Bugüne kadar revizyonu OLUŞTURMAK da ONAYLAMAK/REDDETMEK de aynı
-- projects.budget.manage iznine bağlıydı: revizyonu yazan kişi kendi
-- revizyonunu onaylayabiliyordu. Onay artık projects.budget.approve ister
-- (router.go); kişinin KENDİ revizyonuna karar verememesi (Sahip hariç)
-- servis katmanında uygulanır (bkz. project_budget_adjustment_service.go).
--
-- Varsayılan rol matrisi: Sahip + Yönetici + Finans. Sahip/Yönetici,
-- seed_system_roles_for_org'da zaten "SELECT code FROM permissions" ile her
-- izni alır; Finans'ın listesine eklemek için fonksiyon yeniden tanımlanır
-- (gövde 0060'ın birebir kopyası + 'projects.budget.approve'; 0060'ın Finans'a verdiği projects.expenses.approve korunur). Proje
-- Yöneticisi ve Eski Sistem (legacy_user) rolleri BİLİNÇLİ OLARAK almaz:
-- revizyonu önerebilirler, onay finansın/yönetimin kararıdır.

INSERT INTO permissions (code, description, category) VALUES
    ('projects.budget.approve', 'Bütçe revizyonunu onaylama/reddetme', 'Finans')
ON CONFLICT (code) DO NOTHING;

-- Açıklama artık onayı içermiyor -- Roller ekranında iki izin aynı şeyi
-- söylüyormuş gibi görünmesin.
UPDATE permissions
SET description = 'Proje bütçesini oluşturma, baseline alma ve revizyon önerme'
WHERE code = 'projects.budget.manage';

-- MEVCUT firmaların sistem rollerine BACKFILL (seed fonksiyonu yalnızca
-- YENİ firmalarda çalışır; 0039/0048 ile aynı gerekçe).
INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, 'projects.budget.approve'
FROM organization_roles orole
WHERE orole.is_system AND orole.code IN ('owner', 'admin', 'finance')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

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
        'projects.read', 'projects.finance.read', 'projects.finance.manage', 'projects.expenses.approve',
        'projects.budget.read', 'projects.budget.manage', 'projects.budget.approve',
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

