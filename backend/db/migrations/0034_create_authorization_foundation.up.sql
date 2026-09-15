-- ARVEND V2 — Sprint 1: RBAC + Project Membership + Authorization Foundation.
--
-- BU MİGRATION, users.role (admin|kullanici|super_admin) sütununu
-- DEĞİŞTİRMEZ -- o eksen platform/tenant-admin ayrımını sürdürmeye devam
-- eder (RequireAuth/RequireOnboarded/RequireRole HİÇ dokunulmadı). Burada
-- kurulan, TAMAMEN AYRI, EK bir eksendir: ince-taneli, role→permission
-- eşlemesine dayalı yetkilendirme + proje bazlı erişim kontrolü.
--
-- ÖNEMLİ İSİMLENDİRME NOTU: migration 0025'te ZATEN "project_members" adlı
-- bir tablo var -- ama o employee_id'ye (İK/puantaj kaydı) bağlı, login
-- hesabıyla (users) hiçbir ilişkisi yok ("Personel/Ekip" özelliği). Bu
-- migration'daki erişim-kontrolü tablosu bilinçli olarak "project_users"
-- adını taşır (user_id'ye bağlı) -- "project_members" ile KARIŞTIRILMAMALI,
-- ikisi tamamen farklı kavramlardır ve ikisi de korunur.

-- ---------------------------------------------------------------------------
-- 1. permissions: global, organizasyondan bağımsız kanonik izin kataloğu.
-- ---------------------------------------------------------------------------
CREATE TABLE permissions (
    code        varchar(60) PRIMARY KEY,
    description varchar(200) NOT NULL,
    -- category, web UI'da izinleri anlamlı gruplar halinde göstermek için
    -- (Projeler/Teklifler/Finans/... -- bkz. spec §15, "100 checkbox'lık
    -- korkunç düz liste yapma").
    category    varchar(40) NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 2. organization_roles: organizasyon başına rol kataloğu. is_system=true
-- satırlar HER organizasyon için otomatik seed edilir (aşağıda); is_system
-- =false satırlar ileride firma tarafından oluşturulacak custom rollere
-- ayrılmıştır -- bu şema onu ENGELLEMEZ, ama bu sprintte custom role
-- OLUŞTURMA UI'ı YOK (bkz. final rapor, feasibility notu).
-- ---------------------------------------------------------------------------
CREATE TABLE organization_roles (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    -- code: 'owner' | 'admin' | 'legacy_user' | 'project_manager' | 'finance'
    -- | 'field' | (gelecekte custom kod). legacy_user, YALNIZCA bu migration'ın
    -- geriye dönük uyumluluk backfill'i için vardır (bkz. aşağı) -- web
    -- rol seçicisinde ASLA gösterilmez (super_admin'in tenant dropdown'unda
    -- hiç görünmemesiyle aynı ilke).
    code            varchar(40) NOT NULL,
    name            varchar(100) NOT NULL,
    description     varchar(300) NOT NULL DEFAULT '',
    is_system       boolean NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (organization_id, code)
);

CREATE INDEX idx_organization_roles_org ON organization_roles (organization_id);

CREATE TRIGGER organization_roles_set_updated_at BEFORE UPDATE ON organization_roles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. role_permissions: join tablosu.
-- ---------------------------------------------------------------------------
CREATE TABLE role_permissions (
    organization_role_id uuid NOT NULL REFERENCES organization_roles(id) ON DELETE CASCADE,
    permission_code       varchar(60) NOT NULL REFERENCES permissions(code),
    PRIMARY KEY (organization_role_id, permission_code)
);

-- ---------------------------------------------------------------------------
-- 4. users.organization_role_id: YENİ, EK sütun -- users.role'ün YERİNE
-- değil YANINA. super_admin (organization_id NULL) için de NULL kalır
-- (aşağıdaki CHECK, users_super_admin_has_no_org ile aynı ilkeyi
-- organization_role_id'ye de uygular).
-- ---------------------------------------------------------------------------
ALTER TABLE users ADD COLUMN organization_role_id uuid REFERENCES organization_roles(id);

ALTER TABLE users ADD CONSTRAINT users_super_admin_has_no_org_role
    CHECK (
        (role = 'super_admin' AND organization_role_id IS NULL) OR
        (role <> 'super_admin')
    );

CREATE INDEX idx_users_organization_role ON users (organization_role_id);

-- ---------------------------------------------------------------------------
-- 5. project_users: proje bazlı ERİŞİM (kim bu projenin verisini
-- görebilir/değiştirebilir). project_members (0025, İK/puantaj) İLE
-- KARIŞTIRILMAMALI -- bkz. yukarıdaki başlık notu.
-- ---------------------------------------------------------------------------
CREATE TABLE project_users (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- project_role: organization_role'den TAMAMEN AYRI bir eksen (spec §6:
    -- "organization role ile project role aynı şey değildir"). Basit,
    -- sabit bir küme -- ikinci bir tam izin motoru DEĞİL.
    project_role    varchar(30) NOT NULL DEFAULT 'member'
                    CHECK (project_role IN ('project_manager', 'member', 'viewer')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid REFERENCES users(id) ON DELETE SET NULL,
    UNIQUE (project_id, user_id)
);

CREATE INDEX idx_project_users_org ON project_users (organization_id);
CREATE INDEX idx_project_users_user ON project_users (user_id);
CREATE INDEX idx_project_users_project ON project_users (project_id);
-- GET /projects (membership-aware liste) için en kritik composite index --
-- "bu kullanıcı hangi projelere üye" sorgusu EXISTS/JOIN ile bu iki
-- sütunu birlikte kullanır.
CREATE INDEX idx_project_users_user_project ON project_users (user_id, project_id);

-- Savunma derinliği: cross-tenant membership'i servis katmanına GÜVENMEDEN
-- de DB seviyesinde reddet (spec §22 madde 13: "cross-tenant membership
-- creation → rejected"). project_id'nin organizations'ı ve user_id'nin
-- organizations'ı, project_users.organization_id ile EŞLEŞMELİDİR.
CREATE FUNCTION project_users_check_org_consistency() RETURNS trigger AS $$
DECLARE
    proj_org uuid;
    usr_org  uuid;
BEGIN
    SELECT organization_id INTO proj_org FROM projects WHERE id = NEW.project_id;
    SELECT organization_id INTO usr_org FROM users WHERE id = NEW.user_id;
    IF proj_org IS NULL OR proj_org <> NEW.organization_id THEN
        RAISE EXCEPTION 'project_users.organization_id, projenin organizasyonuyla eşleşmiyor';
    END IF;
    IF usr_org IS NULL OR usr_org <> NEW.organization_id THEN
        RAISE EXCEPTION 'project_users.organization_id, kullanıcının organizasyonuyla eşleşmiyor (cross-tenant membership reddedildi)';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_project_users_check_org_consistency
    BEFORE INSERT OR UPDATE ON project_users
    FOR EACH ROW EXECUTE FUNCTION project_users_check_org_consistency();

-- ---------------------------------------------------------------------------
-- 6. Permission registry seed -- mevcut router.go'nun GERÇEK endpoint
-- envanterinden çıkarılmıştır (bkz. tasarım raporu), spec §2'deki örnek
-- liste kör kopyalanmadı.
-- ---------------------------------------------------------------------------
INSERT INTO permissions (code, description, category) VALUES
    ('projects.read',              'Projeleri görüntüleme',                       'Projeler'),
    ('projects.create',            'Yeni proje oluşturma',                        'Projeler'),
    ('projects.update',            'Proje bilgilerini düzenleme',                 'Projeler'),
    ('projects.finance.read',      'Proje finansal verilerini görüntüleme',       'Finans'),
    ('projects.finance.manage',    'Proje finansal işlemlerini yönetme',          'Finans'),
    ('projects.tasks.read',        'Görevleri görüntüleme',                       'Görevler'),
    ('projects.tasks.create',      'Görev oluşturma',                             'Görevler'),
    ('projects.tasks.update',      'Görev düzenleme/tamamlama',                   'Görevler'),
    ('projects.operations.read',   'Planlama/dosya/fotoğraf/not/ekip görüntüleme','Operasyon'),
    ('projects.operations.manage', 'Planlama/dosya/fotoğraf/not/ekip yönetme',    'Operasyon'),
    ('projects.access.read',       'Proje erişim listesini görüntüleme',          'Proje Erişimi'),
    ('projects.access.manage',     'Proje erişimini yönetme (ekle/çıkar)',        'Proje Erişimi'),
    ('offers.read',                'Teklifleri görüntüleme',                      'Teklifler'),
    ('offers.create',              'Teklif oluşturma',                            'Teklifler'),
    ('offers.update',              'Teklif düzenleme/revize etme/paylaşma',       'Teklifler'),
    ('offers.approve',             'Teklif durumunu değiştirme',                  'Teklifler'),
    ('offers.delete',              'Teklif silme',                                'Teklifler'),
    ('calculations.read',          'Metraj kataloğunu görüntüleme/kullanma',      'Metraj'),
    ('calculations.manage',        'Metraj kataloğunu düzenleme',                 'Metraj'),
    ('products.read',              'Ürün kataloğunu görüntüleme',                 'Ürünler'),
    ('products.manage',            'Ürün kataloğunu düzenleme',                   'Ürünler'),
    ('customers.read',             'Müşterileri görüntüleme',                     'Müşteriler'),
    ('customers.manage',           'Müşterileri düzenleme',                       'Müşteriler'),
    ('employees.read',             'Personeli görüntüleme',                       'Personel'),
    ('employees.manage',           'Personeli düzenleme',                         'Personel'),
    ('attendance.read',            'Puantajı görüntüleme',                        'Puantaj'),
    ('attendance.manage',          'Puantaj kaydı girme/düzenleme',               'Puantaj'),
    ('organization.users.read',    'Kullanıcıları görüntüleme',                   'Firma Yönetimi'),
    ('organization.users.manage',  'Kullanıcıları düzenleme',                     'Firma Yönetimi'),
    ('organization.roles.read',    'Rolleri görüntüleme',                         'Firma Yönetimi'),
    ('organization.roles.manage',  'Rolleri ve izinlerini düzenleme',             'Firma Yönetimi'),
    ('organization.settings.read', 'Firma ayarlarını görüntüleme',                'Firma Yönetimi'),
    ('organization.settings.manage','Firma ayarlarını düzenleme',                 'Firma Yönetimi');

-- ---------------------------------------------------------------------------
-- 7. Her mevcut organizasyon için 6 sistem rolü seed edilir (5 hedef rol +
-- legacy_user geriye-uyumluluk rolü). Fonksiyon olarak yazıldı ki
-- PlatformService.CreateOrganizationWithOwner de YENİ organizasyonlar için
-- AYNI seed'i çağırabilsin (Go tarafında da mirror edilecek, ama DB
-- fonksiyonu burada mevcut organizasyonlar için kullanılıyor).
-- ---------------------------------------------------------------------------
CREATE FUNCTION seed_system_roles_for_org(org_id uuid) RETURNS void AS $$
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

    -- owner + admin: TÜM izinler.
    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_owner, code FROM permissions;
    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_admin, code FROM permissions;

    -- legacy_user: migration ÖNCESİ "kullanici" rolünün GERÇEK erişimiyle
    -- birebir eşleşir (router.go denetimiyle doğrulandı) -- organization.
    -- users/roles/settings, employees.manage, products.manage,
    -- calculations.manage, projects.access.manage HARİÇ her şey (bunlar
    -- migration öncesi zaten requireAdmin arkasındaydı, "kullanici" hiçbir
    -- zaman erişemiyordu).
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
        'attendance.read', 'attendance.manage'
    );

    -- project_manager: yalnızca atandığı projelerde operasyon.
    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_pm, code FROM permissions WHERE code IN (
        'projects.read', 'projects.update',
        'projects.tasks.read', 'projects.tasks.create', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'projects.access.read',
        'calculations.read', 'products.read', 'customers.read'
    );

    -- finance: yalnızca atandığı projelerin finansı.
    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_finance, code FROM permissions WHERE code IN (
        'projects.read', 'projects.finance.read', 'projects.finance.manage'
    );

    -- field: yalnızca atandığı projelerde saha operasyonu.
    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_field, code FROM permissions WHERE code IN (
        'projects.read',
        'projects.tasks.read', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'attendance.read'
    );
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    org record;
BEGIN
    FOR org IN SELECT id FROM organizations LOOP
        PERFORM seed_system_roles_for_org(org.id);
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 8. Mevcut kullanıcıları backfill et: admin -> owner, kullanici -> legacy_user.
-- super_admin -> organization_role_id NULL kalır (zaten NULL, dokunulmuyor).
-- ---------------------------------------------------------------------------
UPDATE users u
SET organization_role_id = orole.id
FROM organization_roles orole
WHERE orole.organization_id = u.organization_id
  AND orole.code = 'owner'
  AND u.role = 'admin';

UPDATE users u
SET organization_role_id = orole.id
FROM organization_roles orole
WHERE orole.organization_id = u.organization_id
  AND orole.code = 'legacy_user'
  AND u.role = 'kullanici';

-- ---------------------------------------------------------------------------
-- 9. project_users backfill: legacy_user'a dönüşen HER kullanıcı, kendi
-- organizasyonundaki HER mevcut projeye üye olarak eklenir -- migration
-- öncesi "kullanici" zaten organizasyondaki TÜM projeleri koşulsuz
-- görebiliyordu (requireAdmin şartı yoktu), bu görünürlüğü KORUR (spec
-- §5: "existing project visibility bozulmamalı"). owner/admin zaten
-- authorization service'te role koduna göre membership'ten muaf tutulacağı
-- için onlar için satır eklemeye GEREK YOK.
-- ---------------------------------------------------------------------------
INSERT INTO project_users (organization_id, project_id, user_id, project_role)
SELECT u.organization_id, p.id, u.id, 'member'
FROM users u
JOIN organization_roles orole ON orole.id = u.organization_role_id AND orole.code = 'legacy_user'
JOIN projects p ON p.organization_id = u.organization_id
ON CONFLICT (project_id, user_id) DO NOTHING;
