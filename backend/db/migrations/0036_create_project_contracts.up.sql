-- ARVEND V2 -- Sprint 3: Proje Sözleşmesi (Contract). Sprint 2 (migration
-- 0035) projenin MALİYET (cost-side) tarafını kurdu; bu migration GELİR
-- (revenue-side) tarafını -- Kontrat + onu değiştiren Ek İşler (project_
-- change_orders, Faz 8'den beri VAR, bu migration ona HİÇBİR kolon
-- eklemez) -- resmi bir varlığa kavuşturur.
--
-- Denetim bulgusu (Sprint 3 ön-araştırması): kod tabanında bugüne kadar
-- YAPISAL bir "Kontrat" kavramı YOKTU -- yalnızca projects.contract_amount
-- (offer'dan tek seferlik donmuş bir sayı) ve etiketlenebilir ama hiçbir
-- şeye bağlı olmayan bir dosya-yükleme kategorisi vardı. Bu migration
-- SADECE ekleyicidir (additive) -- contract_amount/currency/source_offer_
-- id/source_revision_id/müşteri anlık görüntüsü ZATEN projects tablosunda
-- immutable (bkz. UpdateProject sorgusunun kendi yorumu,
-- internal/repository/sqlc/projects.sql.go), bu yüzden BURADA
-- TEKRARLANMAZ -- yalnızca project_id JOIN'i ile canlı okunur. Contract,
-- yalnızca BUGÜNE KADAR hiçbir yerde karşılığı OLMAYAN alanları
-- (scope/payment_terms/retention_terms/advance_terms/effective_date/
-- planned_completion_date) taşır ve bunları aktivasyon sonrası kilitler.
--
-- PDF üretimi/e-imza/müşteri-onay-akışı YOKTUR -- tüm durum geçişleri
-- dahili (authenticated) kullanıcılar tarafından yapılır, Ek İşlerin
-- aksine hiçbir public/token akışı yoktur.

-- ---------------------------------------------------------------------------
-- 1. project_contracts: proje başına TEK sözleşme (UNIQUE(project_id) --
-- project_budgets İLE AYNI kardinalite ilkesi). Durum makinesi:
--
--   draft -> active -> completed   (normal tamamlanma)
--   draft -> cancelled              (yalnızca draft'tan, gerekçe zorunlu)
--   active -> terminated            (yalnızca active'ten, gerekçe zorunlu)
--
-- completed/cancelled/terminated ÜÇÜ DE terminal -- Sprint 3'te hiçbir
-- geri dönüş/yeniden açma YOK. DRAFT bir sözleşme ASLA terminate
-- edilemez (hiç yürürlüğe girmemiş bir şey feshedilemez) -- yalnızca
-- cancel edilebilir.
-- ---------------------------------------------------------------------------
CREATE TABLE project_contracts (
    id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id          uuid NOT NULL REFERENCES organizations(id),
    project_id               uuid NOT NULL REFERENCES projects(id),
    -- project_budgets.currency İLE AYNI emsal: proje oluşturulurken
    -- snapshot alınır -- projects.currency ZATEN immutable olduğu için bu
    -- bir "tek gerçek kaynağı ikiye bölme" İHLALİ DEĞİLDİR, yalnızca sorgu
    -- kolaylığı için (3 harfli bir kod, parasal bir formül DEĞİL).
    currency                 varchar(3) NOT NULL,

    status                   varchar(20) NOT NULL DEFAULT 'draft'
                              CHECK (status IN ('draft', 'active', 'completed', 'cancelled', 'terminated')),

    -- Ticari temel (baseline) -- YALNIZCA draft'ta düzenlenebilir; ACTIVE
    -- sonrası servis katmanı bunları REDDEDER (bkz. project_contract_
    -- service.go). Değişiklik gerekiyorsa resmi bir Ek İş/amendment
    -- mekanizmasından geçmelidir (bu sprintte bu METİN alanları için resmi
    -- bir amendment UCU İNŞA EDİLMEDİ -- yalnızca düzenleme REDDİ var,
    -- bilinçli/dokümante edilen bir sınır, bkz. docs/contracts.md).
    scope                    text NOT NULL DEFAULT '',
    payment_terms            text NOT NULL DEFAULT '',
    retention_terms          text NOT NULL DEFAULT '',
    advance_terms            text NOT NULL DEFAULT '',
    effective_date           date,
    planned_completion_date  date,

    -- Ticari DEĞİL -- draft VE active'te her zaman düzenlenebilir;
    -- yalnızca terminal durumlarda (completed/cancelled/terminated)
    -- kilitlenir (geçmiş kaydın tahrifini önlemek için).
    internal_notes           text NOT NULL DEFAULT '',

    created_by               uuid REFERENCES users(id),
    created_at               timestamptz NOT NULL DEFAULT now(),
    updated_at               timestamptz NOT NULL DEFAULT now(),

    activated_at             timestamptz,
    activated_by             uuid REFERENCES users(id),
    completed_at             timestamptz,
    completed_by             uuid REFERENCES users(id),
    cancelled_at             timestamptz,
    cancelled_by             uuid REFERENCES users(id),
    cancel_reason            varchar(500) NOT NULL DEFAULT '',
    terminated_at            timestamptz,
    terminated_by            uuid REFERENCES users(id),
    termination_reason       varchar(500) NOT NULL DEFAULT '',

    UNIQUE (project_id)
);

CREATE INDEX idx_project_contracts_org ON project_contracts (organization_id);

CREATE TRIGGER project_contracts_set_updated_at BEFORE UPDATE ON project_contracts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Tutarlılık trigger'ı GEREKMİYOR -- project_wbs_nodes/project_budget_
-- lines'ın aksine, project_contracts'ın TEK FK'si (project_id) zorunlu ve
-- tekil; project_id ile eşleşmeyen bir organization_id'ye REFERENCES
-- organizations(id) zaten izin vermez, ve opsiyonel çapraz-proje
-- referansı taşıyan başka bir kolon yok.

-- ---------------------------------------------------------------------------
-- 2. project_change_orders'a HİÇBİR kolon EKLENMEZ (contract_id FK YOK) --
-- proje<->sözleşme 1:1 olduğu için project_change_orders.project_id
-- ZATEN o projenin (en fazla bir) sözleşmesini örtük olarak belirliyor;
-- contract_id eklemek, hiçbir sorgu gücü katmayan, yalnızca senkron dışı
-- kalabilecek TAMAMEN türetilebilir bir veri olurdu (aynı gerekçeyle
-- current_contract_value'nun da hiç saklanmaması gibi).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 3. İzin kayıt defteri genişletmesi -- ÜÇ parçalı model (migration
-- 0034/0035 İLE AYNI <domain>.<subresource>.<action> deseni, ama Sprint
-- 2'nin read/manage ikilisinden FARKLI olarak read/manage/lifecycle
-- ÜÇLÜSÜ -- kullanıcının AÇIK tasarım kararı):
--
--   projects.contracts.read       Sözleşmeyi/ticari şartları/durumunu/
--                                 kaynak teklif referansını/güncel
--                                 sözleşme değerini görüntüleme.
--   projects.contracts.manage     Taslak sözleşme oluşturma, DRAFT
--                                 alanlarını düzenleme, aktivasyon
--                                 SONRASI yalnızca güvenli/kilitsiz
--                                 metadata (internal_notes) düzenleme.
--                                 Durum GEÇİŞİ YAPAMAZ.
--   projects.contracts.lifecycle  Activate/Cancel/Complete/Terminate --
--                                 HER ZAMAN backend-enforced + denetimli.
-- ---------------------------------------------------------------------------
INSERT INTO permissions (code, description, category) VALUES
    ('projects.contracts.read',      'Proje sözleşmesini görüntüleme',                    'Finans'),
    ('projects.contracts.manage',    'Sözleşme taslağı oluşturma/düzenleme',              'Finans'),
    ('projects.contracts.lifecycle', 'Sözleşme durumunu değiştirme (aktive/iptal/tamamla/fesih)', 'Finans');

-- ---------------------------------------------------------------------------
-- 4. seed_system_roles_for_org GÜNCELLENİR (CREATE OR REPLACE) -- owner/
-- admin bloğu DEĞİŞMEDİ (zaten "SELECT code FROM permissions" ile TÜM
-- izinleri otomatik alır). Yalnızca legacy_user/project_manager/finance
-- WHERE IN listelerine yeni kodlar eklendi. field HİÇBİR yeni izin
-- ALMAZ.
--
-- Rol matrisi kararları (kullanıcı tarafından AÇIKÇA verildi, final
-- raporda tekrarlanacak):
--   finance: read + manage + lifecycle (TAM -- mevcut projects.finance.
--     read/manage tam yetkisiyle tutarlı, sözleşmenin doğal sahibi).
--   legacy_user: read + manage VERİLİR (migration 0034'te ZATEN
--     projects.finance.read/manage tam yetkisine sahip -- Ek İşler bugün
--     tam olarak bu iki kod altında yaşıyor, bu yüzden geriye-uyumluluk
--     gerekçesiyle read/manage simetrik verilir) AMA lifecycle KESİNLİKLE
--     VERİLMEZ -- kullanıcının açık talimatı: "Contracts did not exist
--     before, so do not blindly grant lifecycle rights... Never grant
--     projects.contracts.lifecycle simply because the user is legacy."
--     Sözleşme durum geçişi (Activate/Cancel/Complete/Terminate) bugüne
--     kadar hiç var olmayan YENİ bir eylem sınıfıdır, otomatik miras
--     alınmaz.
--   project_manager: read + manage VERİLİR (Sprint 2'nin bütçe/maliyet-
--     kontrolü paterninden BİLİNÇLİ OLARAK FARKLI -- orada PM salt-
--     okunurdu; burada kullanıcının açık kararıyla PM taslak
--     düzenleyebilir) AMA lifecycle VERİLMEZ (Activate/Cancel/Complete/
--     Terminate YAPAMAZ -- bu yetki Finance/Owner/Admin'de kalır).
--   field: HİÇBİRİ (mevcut "sahada finansal görünürlük YOK" ilkesiyle
--     tutarlı).
-- ---------------------------------------------------------------------------
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

    -- owner + admin: TÜM izinler (yeni eklenen izinler dahil, otomatik).
    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_owner, code FROM permissions;
    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_admin, code FROM permissions;

    -- legacy_user: mevcut finance.read/manage tam paritesiyle TUTARLI
    -- (read+manage), lifecycle KESİNLİKLE HARİÇ (yukarıdaki gerekçe notu).
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

    -- project_manager: read+manage VERİLİR (Sprint 2'nin salt-okunur
    -- paterninden BİLİNÇLİ SAPMA, kullanıcı kararı), lifecycle HARİÇ.
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

    -- finance: TAM (read+manage+lifecycle) -- sözleşmenin doğal sahibi.
    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_finance, code FROM permissions WHERE code IN (
        'projects.read', 'projects.finance.read', 'projects.finance.manage',
        'projects.budget.read', 'projects.budget.manage',
        'projects.cost_control.read', 'projects.cost_control.manage',
        'organization.cost_codes.read', 'organization.cost_codes.manage',
        'projects.contracts.read', 'projects.contracts.manage', 'projects.contracts.lifecycle'
    );

    -- field: yalnızca atandığı projelerde saha operasyonu -- sözleşme
    -- İZNİ YOK (spec: "no financial visibility").
    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_field, code FROM permissions WHERE code IN (
        'projects.read',
        'projects.tasks.read', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'attendance.read'
    );
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- 5. MEVCUT organizasyonların ZATEN seed edilmiş rollerine yeni izinleri
-- BACKFILL et -- CREATE OR REPLACE FUNCTION yalnızca YENİ organizasyonları
-- etkiler (bkz. migration 0035'in AYNI gerekçesi, PL/pgSQL fonksiyon
-- gövdesi metin olarak yeniden kullanılamadığı için iki kopya kasıtlıdır).
-- ---------------------------------------------------------------------------
INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code IN ('owner', 'admin')
  AND p.code IN ('projects.contracts.read', 'projects.contracts.manage', 'projects.contracts.lifecycle')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code = 'legacy_user'
  AND p.code IN ('projects.contracts.read', 'projects.contracts.manage')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code = 'project_manager'
  AND p.code IN ('projects.contracts.read', 'projects.contracts.manage')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code = 'finance'
  AND p.code IN ('projects.contracts.read', 'projects.contracts.manage', 'projects.contracts.lifecycle')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

-- field: yeni izin YOK, kasıtlı olarak hiçbir INSERT yapılmaz.
