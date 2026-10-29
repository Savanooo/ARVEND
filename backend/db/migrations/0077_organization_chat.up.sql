-- Firma Grubu (2026-10). Ürün sahibi: "Toplu mesaj kanalı olsun, grup mesajı
-- gibi düşün". Karar: firma başına TEK grup (proje başına değil), metin +
-- fotoğraf, telefona bildirim. Web şimdilik yok (docs/web-yapilacaklar.md).
--
-- Kurallar:
--   * Grubun üyesi firmanın AKTİF çalışan hesaplarıdır: organization.chat.use
--     izni (her role verilir) + users.supplier_id IS NULL. Taşeron hesabı
--     (migration 0075) grubu hiç görmez: rolüne izin verilmez, oturum kapısı
--     da /organization/chat uçlarını ona açmaz.
--   * Mesaj silme yumuşaktır (deleted_at/deleted_by): satır ve fotoğraf
--     dosyası kalır, ama metin ve fotoğraf bir daha hiçbir yanıtta dönmez --
--     herkes "Mesaj silindi" görür. Kendi mesajını herkes, herkesinkini
--     Sahip/Yönetici siler.
--   * Mesaj sırası firma içi bir numaradır (seq), uuid'den ayrı: istemci
--     "şundan sonrakiler" diye yoklar (after=seq). Numara firmanın grup
--     satırındaki sayaçtan (organization_chats.last_seq) satır kilidiyle
--     alınır; kilit transaction sonuna kadar tutulduğu için numara sırası
--     commit sırasıdır -- yoklama arada commit edilen bir mesajı atlamaz
--     (now()/created_at ya da genel bir sequence bunu garanti etmez). Numara
--     firmaya özeldir: başka firmanın mesaj trafiği numaralardan okunmaz.

INSERT INTO permissions (code, description, category) VALUES
    ('organization.chat.use', 'Firma Grubu: firma içi grup mesajlarını okuma, yazma ve fotoğraf paylaşma', 'İletişim')
ON CONFLICT (code) DO NOTHING;

-- Mevcut firmalar: Taşeron dışındaki HER rol (özel roller dahil) -- grup
-- firmadaki herkes içindir. Sahip/Yönetici zaten seed'de tüm izinleri alır.
INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, 'organization.chat.use'
FROM organization_roles orole
WHERE orole.code <> 'subcontractor'
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

-- Firmanın grubu: ilk mesajla açılır. last_seq mesaj numarası sayacıdır
-- (bkz. başlık notu).
CREATE TABLE organization_chats (
    organization_id uuid PRIMARY KEY REFERENCES organizations(id) ON DELETE CASCADE,
    last_seq        bigint NOT NULL DEFAULT 0 CHECK (last_seq >= 0),
    last_message_at timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE organization_chat_messages (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    seq             bigint NOT NULL CHECK (seq > 0),
    -- Hesap fiziksel silinirse (yalnızca test/temizlik araçları) mesaj kalır,
    -- yazar "Silinmiş kullanıcı" görünür.
    author_id       uuid REFERENCES users(id) ON DELETE SET NULL,
    body            text NOT NULL DEFAULT '' CHECK (char_length(body) <= 4000),
    -- İstemcinin ürettiği kimlik: "Tekrar dene" aynı mesajı ikinci kez
    -- yazmasın (yanıt yolda kaybolduysa sunucu ilk kaydı döner).
    client_id       uuid,
    -- Fotoğraf eki (mesaj başına bir fotoğraf; birden çok fotoğraf ayrı
    -- mesajlardır). Anahtar sunucuda üretilir, tür içerikten tespit edilir.
    photo_key       varchar(500),
    photo_mime      varchar(100),
    photo_size      bigint CHECK (photo_size IS NULL OR photo_size > 0),
    photo_sha256    varchar(64),
    created_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,
    deleted_by      uuid REFERENCES users(id) ON DELETE SET NULL,
    UNIQUE (organization_id, seq),
    CHECK ((photo_key IS NULL) = (photo_mime IS NULL)),
    CHECK (photo_key IS NOT NULL OR char_length(body) > 0)
);

-- Gönderim hızı sınırı: yazarın son dakikadaki mesajları.
CREATE INDEX idx_chat_messages_author_recent ON organization_chat_messages (author_id, created_at DESC);
CREATE UNIQUE INDEX idx_chat_messages_client_id ON organization_chat_messages (organization_id, author_id, client_id)
    WHERE client_id IS NOT NULL;
-- Yoklamada "bu arada silinenler" (açık ekranlarda da "Mesaj silindi" olsun).
CREATE INDEX idx_chat_messages_deleted ON organization_chat_messages (organization_id, deleted_at)
    WHERE deleted_at IS NOT NULL;

-- Kişinin grup durumu: nereye kadar okudu, sessizde mi. Satır ilk okumada
-- ya da sessize almada açılır; satırı olmayan kişi sessizde değildir.
CREATE TABLE organization_chat_members (
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    last_read_seq   bigint NOT NULL DEFAULT 0 CHECK (last_read_seq >= 0),
    last_read_at    timestamptz,
    muted           boolean NOT NULL DEFAULT false,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, user_id)
);

-- Okunmamış Firma Grubu bildirimini bulmak (gruplama, bkz.
-- UpsertChatNotifications): kişi başına en çok bir okunmamış satır olur.
CREATE INDEX idx_notifications_chat_unread ON notifications (organization_id, user_id)
    WHERE type = 'organization_chat' AND read_at IS NULL;

-- Yeni firmalar: seed fonksiyonu (0075 gövdesi + organization.chat.use;
-- Taşeron rolüne verilmez).
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
        'notifications.read',
        'organization.chat.use'
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
        'notifications.read',
        'organization.chat.use'
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
        'notifications.read',
        'organization.chat.use'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_field, code FROM permissions WHERE code IN (
        'projects.expenses.create',
        'projects.read',
        'projects.tasks.read', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'attendance.read',
        'inventory.read',
        'notifications.read',
        'organization.chat.use'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_subcontractor, code FROM permissions WHERE code IN (
        'subcontractor.portal',
        'notifications.read'
    );
END;
$$ LANGUAGE plpgsql;
