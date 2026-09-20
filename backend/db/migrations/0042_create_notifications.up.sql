-- Bildirimler (Notifications) -- Faz 1: yalnızca uygulama-içi (in-app)
-- kalıcılık + okuma. Gerçek push (FCM/APNs) BİLİNÇLİ OLARAK bu migration'a
-- DAHİL DEĞİL -- ne bir device_tokens tablosu ne de bir push-sağlayıcı
-- entegrasyonu var; bu repoda hiçbir arka plan/zamanlanmış iş (cron/worker)
-- altyapısı da yok (bkz. Faz 1 araştırması: cmd/api/main.go'nun TAMAMI
-- senkron bir HTTP sunucusudur, hiçbir goroutine/ticker/kuyruk başlatmaz).
-- Bu yüzden zaman-tabanlı ("yaklaşan/gecikmiş görev") bildirimler de bu
-- ilk sürüme DAHİL DEĞİL -- yalnızca ZATEN var olan, senkron iş akışlarına
-- (görev atama, teklif kabul/red, taşeron/hakediş/satın alma onay kararı
-- gibi) bağlanan olay-tetiklemeli bildirimler var.
--
-- entity_id KASITLI OLARAK bir FK TAŞIMAZ -- entity_type'a göre task/
-- offer/subcontract/subcontract_change_order/subcontract_progress_claim/
-- purchase_request/rfq/purchase_order gibi FARKLI tablolara işaret eder
-- (polimorfik referans, tek bir FK hedefi yok) -- calc_categories.
-- image_file_id'nin AYNI, bu repoda zaten var olan "kasıtlı FK'siz alan"
-- emsaliyle tutarlı.
--
-- Hassas finansal/ticari veri (tutar, taşeron/tedarikçi adı vb.) title/
-- body'ye YAZILMAZ -- yalnızca varlık numarası/başlığı gibi nötr bir
-- referans içerir; detay için kullanıcı kimlik doğrulamalı uygulamayı
-- AÇMALIDIR (bkz. backend/internal/service/notification_service.go
-- şablon yorumları).
CREATE TABLE notifications (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    user_id          uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type             varchar(60) NOT NULL,
    title            varchar(200) NOT NULL,
    body             varchar(500) NOT NULL DEFAULT '',
    entity_type      varchar(40) NOT NULL DEFAULT '',
    entity_id        uuid,
    project_id       uuid REFERENCES projects(id) ON DELETE CASCADE,
    action_target    varchar(300) NOT NULL DEFAULT '',
    read_at          timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now()
);

-- "Bana ait, en yeniden eskiye" liste sorgusunun ana erişim yolu.
CREATE INDEX idx_notifications_user_created ON notifications (user_id, organization_id, created_at DESC);
-- Okunmamış sayacı -- yalnızca read_at IS NULL satırları kapsayan kısmi
-- indeks, tam tabloyu taramadan hızlı COUNT(*) sağlar.
CREATE INDEX idx_notifications_user_unread ON notifications (user_id) WHERE read_at IS NULL;
CREATE INDEX idx_notifications_project ON notifications (project_id) WHERE project_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- İzin kayıt defteri genişletmesi -- bildirimler her zaman KENDİ kaydıdır
-- (WHERE user_id = <çağıran>, bkz. servis katmanı), bu yüzden proje
-- üyeliği/rol bazlı bir kısıtlama YOKTUR -- notifications.read TÜM sistem
-- rollerine (owner/admin/legacy_user/project_manager/finance/field)
-- verilir; kimse kendi bildirimlerini görmekten mahrum bırakılmaz. Yazma
-- (oluşturma) için ayrı bir izin YOKTUR -- bildirimler yalnızca backend'in
-- kendi iş akışları tarafından, kullanıcı isteği DIŞINDA üretilir (bkz.
-- notification_service.go), bu yüzden bir "manage" izni anlamsızdır.
-- ---------------------------------------------------------------------------
INSERT INTO permissions (code, description, category) VALUES
    ('notifications.read', 'Kendi bildirimlerini görüntüleme', 'Bildirimler');

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

-- ---------------------------------------------------------------------------
-- MEVCUT organizasyonların ZATEN seed edilmiş rollerine yeni izni
-- BACKFILL et (migration 0035/.../0040 İLE AYNI gerekçe) -- notifications.
-- read TÜM ALTI sistem rolüne verilir (yukarıdaki matrisle tutarlı --
-- kendi bildirimlerini görmek evrenseldir, finans/onay izinlerinin aksine
-- rol bazlı kısıtlama gerektirmez).
-- ---------------------------------------------------------------------------
INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code IN ('owner', 'admin', 'legacy_user', 'project_manager', 'finance', 'field')
  AND p.code = 'notifications.read'
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;
