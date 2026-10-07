-- Masraf: HERKES girer, YALNIZCA en üst yönetim onaylar (ürün sahibi
-- kararı, 2026-10-07): "masrafı herkes girsin ama beklemede/incelemede
-- olsun; onaylamayı sadece yönetici, en üst kişi yapacak".
--
-- 1) Yeni izin projects.expenses.create. Masraf girmek bugüne kadar
--    projects.finance.manage istiyordu; o izin tahsilat, ödeme planı,
--    sözleşme tutarı ve ek işleri de açıyor -- sahadaki ustaya masraf
--    girdirmek için finansı açmak olmaz. Bu izin YALNIZCA masraf girmeyi
--    (ve kişinin kendi girdiği bekleyen/reddedilen masrafı düzeltmesini)
--    açar. Varsayılan: BÜTÜN roller (sistem + firmanın kendi rolleri) --
--    "herkes". Firma isterse Roller & Yetkiler'den bir rolden kaldırır.
-- 2) projects.expenses.approve artık yalnızca Sahip + Yönetici'de: 0060
--    Finans'a da vermişti, kaldırılır. Kişiye özel verilmiş izinlere
--    DOKUNULMAZ; yalnızca sistem Finans rolünün varsayılanı kalkar. Kimse
--    kendi masrafını onaylayamaz (Sahip hariç -- üstünde kimse yok); bu
--    servis katmanında (bütçe revizyonuyla aynı kural).
--
-- Bekleyen masraflar olduğu gibi kalır; onları artık Sahip/Yönetici
-- onaylar (onaylayıcı bildirimi izne göre çözülür, bkz.
-- project_expense_approval.go).

INSERT INTO permissions (code, description, category) VALUES
    ('projects.expenses.create', 'Projeye masraf girme (onaya düşer)', 'Finans')
ON CONFLICT (code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, 'projects.expenses.create'
FROM organization_roles orole
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

DELETE FROM role_permissions
WHERE permission_code = 'projects.expenses.approve'
  AND organization_role_id IN (
      SELECT id FROM organization_roles WHERE is_system AND code = 'finance'
  );

-- Yeni firmalar: gövde 0062'nin birebir kopyası; Finans listesinden
-- 'projects.expenses.approve' çıkarıldı, Sahip/Yönetici dışındaki her role
-- 'projects.expenses.create' eklendi (Sahip/Yönetici zaten her izni alır).
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
        'projects.procurement.read', 'projects.procurement.manage',
        'projects.subcontracts.read', 'projects.subcontracts.manage',
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage',
        'projects.subcontract_payments.read',
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
        'projects.procurement.read', 'projects.procurement.manage',
        'projects.subcontracts.read', 'projects.subcontracts.manage',
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage',
        'projects.subcontract_payments.read',
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
        'projects.subcontracts.read', 'projects.subcontracts.manage', 'projects.subcontracts.approve',
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage', 'projects.subcontract_claims.certify',
        'projects.subcontract_payments.read', 'projects.subcontract_payments.manage',
        'offers.internal_pricing.read', 'offers.internal_pricing.manage',
        'notifications.read'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_field, code FROM permissions WHERE code IN (
        'projects.expenses.create',
        'projects.read',
        'projects.tasks.read', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'attendance.read',
        'notifications.read'
    );
END;
$$ LANGUAGE plpgsql;
