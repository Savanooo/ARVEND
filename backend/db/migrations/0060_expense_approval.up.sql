-- Masraf onayı (2026-10, ürün sahibinin kararı): projeye girilen HER masraf
-- -- kim girerse girsin, Sahip dahil -- "onay bekliyor" olarak başlar ve
-- yalnızca onaylandıktan sonra para toplamlarına (finans özeti, maliyet
-- kontrolü, proje listesi kârı, ek iş maliyeti, ana sayfa) girer. Sahada
-- herkes masraf girebiliyordu ve girilen tutar anında kâra yansıyordu;
-- yanlış/şişirilmiş bir kayıt fark edilene kadar rakamları bozuyordu.
--
-- approval_status: pending | approved | rejected. Mevcut satırlar
-- 'approved' olur -- zaten sayılıyorlardı, bugünkü rakamlar değişmemeli.
-- Kolon önce DEFAULT 'approved' ile eklenir (PG11+ sabit varsayılanda
-- tabloyu yeniden yazmaz, mevcut satırlar bu değeri alır), SONRA varsayılan
-- 'pending' yapılır: bundan sonraki her INSERT onay bekler.
--
-- decided_by/decided_at/decision_note: son onay/ret kararı. Düzenleme
-- masrafı yeniden 'pending'e alır ve bu alanları temizler (karar geçmişi
-- project_events'te kalır). Eski (onay akışından önceki) satırlarda boş.
ALTER TABLE project_expenses
    ADD COLUMN approval_status varchar(20) NOT NULL DEFAULT 'approved',
    ADD COLUMN decided_by      uuid REFERENCES users(id) ON DELETE SET NULL,
    ADD COLUMN decided_at      timestamptz,
    ADD COLUMN decision_note   varchar(500) NOT NULL DEFAULT '';

ALTER TABLE project_expenses ALTER COLUMN approval_status SET DEFAULT 'pending';

ALTER TABLE project_expenses
    ADD CONSTRAINT project_expenses_approval_status_check
    CHECK (approval_status IN ('pending', 'approved', 'rejected'));

-- "Onay bekleyen masraflar" (proje notu, ana sayfa) yalnızca bu dar kümeyi
-- arar; tüm masraf tablosunu taramasın.
CREATE INDEX idx_expenses_pending ON project_expenses (organization_id, project_id)
    WHERE approval_status = 'pending' AND voided_at IS NULL;

-- ---------------------------------------------------------------------------
-- İzin: projects.expenses.approve. finance.manage'den AYRI -- masraf giren
-- (sahadaki proje yöneticisi, Eski Sistem kullanıcısı) kendi girdiğini
-- onaylayamamalı. Onaylayan kendi masrafını onaylayabilir (ürün kararı).
--
-- Rol matrisi: Sahip + Yönetici (seed fonksiyonu onlara "SELECT code FROM
-- permissions" ile TÜM izinleri verir) ve Finans. Diğer rollere Roller
-- ekranından ya da kişiye özel izinle eklenebilir.
-- ---------------------------------------------------------------------------
INSERT INTO permissions (code, description, category) VALUES
    ('projects.expenses.approve', 'Proje masraflarını onaylama/reddetme', 'Finans');

-- Yeni firmalar: Finans rolünün listesine eklenir (fonksiyonun geri kalanı
-- migration 0042'dekiyle BİREBİR aynı).
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

-- Mevcut firmaların ZATEN seed edilmiş rollerine BACKFILL (0039/0048 ile
-- aynı gerekçe: seed fonksiyonu yalnızca YENİ firmalarda çalışır).
INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code IN ('owner', 'admin', 'finance')
  AND p.code = 'projects.expenses.approve'
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;
