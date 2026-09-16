-- role_permissions satırları permissions silinince CASCADE ile kaybolur,
-- ama migration 0035/0036'nın AYNI gerekçesiyle permissions'ı silmeden
-- ÖNCE açıkça temizliyoruz.
DELETE FROM role_permissions WHERE permission_code IN (
    'organization.suppliers.read', 'organization.suppliers.manage',
    'projects.procurement.read', 'projects.procurement.manage', 'projects.procurement.approve'
);

DELETE FROM permissions WHERE code IN (
    'organization.suppliers.read', 'organization.suppliers.manage',
    'projects.procurement.read', 'projects.procurement.manage', 'projects.procurement.approve'
);

-- seed_system_roles_for_org'u migration 0036'daki HALİNE geri döndür
-- (suppliers.*/procurement.* eklemeleri olmadan) -- fonksiyon gövdesi
-- 0036'nın up dosyasından birebir kopyalanmıştır.
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
        'projects.contracts.read', 'projects.contracts.manage'
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
        'projects.contracts.read', 'projects.contracts.manage'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_finance, code FROM permissions WHERE code IN (
        'projects.read', 'projects.finance.read', 'projects.finance.manage',
        'projects.budget.read', 'projects.budget.manage',
        'projects.cost_control.read', 'projects.cost_control.manage',
        'organization.cost_codes.read', 'organization.cost_codes.manage',
        'projects.contracts.read', 'projects.contracts.manage', 'projects.contracts.lifecycle'
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

-- rfqs.awarded_quotation_id, supplier_quotations'a bir FK taşır --
-- supplier_quotations.rfq_id de rfqs'e bir FK taşıdığı için (dairesel
-- bağımlılık, bkz. up dosyası §6 notu) supplier_quotations'ı DROP
-- edebilmek için önce bu kolonu (ve onunla birlikte gelen FK'yi) kaldırmak
-- gerekir.
ALTER TABLE rfqs DROP COLUMN IF EXISTS awarded_quotation_id;
ALTER TABLE rfqs DROP COLUMN IF EXISTS awarded_at;
ALTER TABLE rfqs DROP COLUMN IF EXISTS awarded_by;
ALTER TABLE rfqs DROP COLUMN IF EXISTS award_notes;

-- Tutarlılık trigger fonksiyonları, DROP TABLE ile OTOMATİK silinmez
-- (fonksiyon tabloya değil, tetikleyiciye bağlıdır -- migration 0035'in
-- AYNI deseni: her trigger + fonksiyon açıkça düşürülür).
DROP TRIGGER IF EXISTS trg_purchase_order_items_check_consistency ON purchase_order_items;
DROP FUNCTION IF EXISTS purchase_order_items_check_consistency();
DROP TRIGGER IF EXISTS trg_purchase_orders_check_consistency ON purchase_orders;
DROP FUNCTION IF EXISTS purchase_orders_check_consistency();
DROP TRIGGER IF EXISTS trg_quotation_items_check_consistency ON quotation_items;
DROP FUNCTION IF EXISTS quotation_items_check_consistency();
DROP TRIGGER IF EXISTS trg_supplier_quotations_check_consistency ON supplier_quotations;
DROP FUNCTION IF EXISTS supplier_quotations_check_consistency();
DROP TRIGGER IF EXISTS trg_rfq_items_check_consistency ON rfq_items;
DROP FUNCTION IF EXISTS rfq_items_check_consistency();
DROP TRIGGER IF EXISTS trg_rfq_suppliers_check_consistency ON rfq_suppliers;
DROP FUNCTION IF EXISTS rfq_suppliers_check_consistency();
DROP TRIGGER IF EXISTS trg_purchase_request_items_check_consistency ON purchase_request_items;
DROP FUNCTION IF EXISTS purchase_request_items_check_consistency();

-- Bağımlılık sırasına göre (en bağımlı önce) düşür.
DROP TABLE IF EXISTS purchase_order_items;
DROP TABLE IF EXISTS purchase_orders;
DROP TABLE IF EXISTS quotation_items;
DROP TABLE IF EXISTS supplier_quotations;
DROP TABLE IF EXISTS rfq_items;
DROP TABLE IF EXISTS rfq_suppliers;
DROP TABLE IF EXISTS rfqs;
DROP TABLE IF EXISTS purchase_request_items;
DROP TABLE IF EXISTS purchase_requests;
DROP TABLE IF EXISTS purchase_order_counters;
DROP TABLE IF EXISTS rfq_counters;
DROP TABLE IF EXISTS purchase_request_counters;
DROP TABLE IF EXISTS suppliers;
