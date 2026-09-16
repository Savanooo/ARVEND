-- role_permissions satırları permissions silinince CASCADE ile kaybolur,
-- ama migration 0035/0036/0037 İLE AYNI gerekçeyle permissions'ı silmeden
-- ÖNCE açıkça temizliyoruz.
DELETE FROM role_permissions WHERE permission_code IN (
    'projects.subcontracts.read', 'projects.subcontracts.manage', 'projects.subcontracts.approve',
    'projects.subcontract_claims.read', 'projects.subcontract_claims.manage', 'projects.subcontract_claims.certify'
);

DELETE FROM permissions WHERE code IN (
    'projects.subcontracts.read', 'projects.subcontracts.manage', 'projects.subcontracts.approve',
    'projects.subcontract_claims.read', 'projects.subcontract_claims.manage', 'projects.subcontract_claims.certify'
);

-- seed_system_roles_for_org'u migration 0037'deki HALİNE geri döndür
-- (subcontracts.*/subcontract_claims.* eklemeleri olmadan) -- fonksiyon
-- gövdesi 0037'nin up dosyasından birebir kopyalanmıştır.
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
        'projects.procurement.read', 'projects.procurement.manage'
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
        'projects.procurement.read', 'projects.procurement.manage'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_finance, code FROM permissions WHERE code IN (
        'projects.read', 'projects.finance.read', 'projects.finance.manage',
        'projects.budget.read', 'projects.budget.manage',
        'projects.cost_control.read', 'projects.cost_control.manage',
        'organization.cost_codes.read', 'organization.cost_codes.manage',
        'projects.contracts.read', 'projects.contracts.manage', 'projects.contracts.lifecycle',
        'organization.suppliers.read', 'organization.suppliers.manage',
        'projects.procurement.read', 'projects.procurement.manage', 'projects.procurement.approve'
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

-- Trigger + fonksiyon temizliği (DROP TABLE tek başına trigger
-- fonksiyonlarını silmez -- Sprint 4'te öğrenilen ders, bkz.
-- migration 0037.down.sql).
DROP TRIGGER IF EXISTS trg_subcontract_claim_items_check_consistency ON subcontract_progress_claim_items;
DROP FUNCTION IF EXISTS subcontract_progress_claim_items_check_consistency();

DROP TRIGGER IF EXISTS trg_subcontract_progress_claims_check_consistency ON subcontract_progress_claims;
DROP FUNCTION IF EXISTS subcontract_progress_claims_check_consistency();
DROP TRIGGER IF EXISTS subcontract_progress_claims_set_updated_at ON subcontract_progress_claims;

DROP TRIGGER IF EXISTS trg_subcontract_co_items_check_consistency ON subcontract_change_order_items;
DROP FUNCTION IF EXISTS subcontract_change_order_items_check_consistency();

DROP TRIGGER IF EXISTS trg_subcontract_change_orders_check_consistency ON subcontract_change_orders;
DROP FUNCTION IF EXISTS subcontract_change_orders_check_consistency();
DROP TRIGGER IF EXISTS subcontract_change_orders_set_updated_at ON subcontract_change_orders;

DROP TRIGGER IF EXISTS trg_subcontract_items_check_consistency ON subcontract_items;
DROP FUNCTION IF EXISTS subcontract_items_check_consistency();
DROP TRIGGER IF EXISTS subcontract_items_set_updated_at ON subcontract_items;

DROP TRIGGER IF EXISTS trg_project_subcontracts_check_consistency ON project_subcontracts;
DROP FUNCTION IF EXISTS project_subcontracts_check_consistency();
DROP TRIGGER IF EXISTS project_subcontracts_set_updated_at ON project_subcontracts;

-- Tablo drop sırası -- FK bağımlılıklarının TERSİ (çocuktan ebeveyne).
DROP TABLE IF EXISTS subcontract_progress_claim_items;
DROP TABLE IF EXISTS subcontract_progress_claims;
DROP TABLE IF EXISTS subcontract_change_order_items;
DROP TABLE IF EXISTS subcontract_change_orders;
DROP TABLE IF EXISTS subcontract_items;
DROP TABLE IF EXISTS project_subcontracts;

DROP TABLE IF EXISTS subcontract_progress_claim_counters;
DROP TABLE IF EXISTS subcontract_change_order_counters;
DROP TABLE IF EXISTS subcontract_counters;

ALTER TABLE suppliers DROP COLUMN IF EXISTS specialty;
