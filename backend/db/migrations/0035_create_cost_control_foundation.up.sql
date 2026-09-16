-- ARVEND V2 — Sprint 2: WBS + Cost Codes + Project Budget + Cost Control
-- Foundation.
--
-- ÖNEMLİ VARSAYIM REDDİ (denetim bulgusu): offers/calc zincirinde
-- (products.unit_price -> calc_recipe_items -> calc_snapshot ->
-- offer_revision_items.unit_price -> offer_revisions.grand_total ->
-- projects.contract_amount) HİÇBİR noktada güvenilir bir "maliyet" alanı
-- YOKTUR -- zincirin tamamı satış fiyatı taşır. Bu yüzden BU MİGRATION
-- hiçbir offer/proje verisinden bütçe TÜRETMEZ; yeni bir proje için bütçe
-- her zaman boş bir draft olarak, kullanıcı tarafından elle oluşturulur.
--
-- Bu migration'ın tabloları TAMAMEN EKtir -- mevcut proje finans zincirini
-- (project_expenses/project_collections/project_invoices/
-- project_subcontractors/project_change_orders, GetProjectFinancialSummary,
-- current_contract_value formülü) HİÇ DEĞİŞTİRMEZ. Cost Control, bu mevcut
-- tabloları TÜKETEN taraftır -- örn. "actual cost" HER ZAMAN
-- project_expenses'ten gelir (kendi paralel bir ledger'ı YOKTUR, bkz.
-- aşağıdaki "actual cost" notu).

-- ---------------------------------------------------------------------------
-- 1. organization_cost_codes: firma seviyesinde, tekrar kullanılabilir
-- maliyet sınıflandırma kataloğu (WBS'ten TAMAMEN AYRI eksen -- WBS
-- "nerede" sorusuna, cost code "ne türden maliyet" sorusuna cevap verir).
-- calc_groups/calc_categories (Metraj motoru UI taksonomisi) İLE
-- KARIŞTIRILMAMALI -- onlarda kod alanı/maliyet-türü semantiği yoktur,
-- burası TAMAMEN AYRI ve amaca özel bir katalogdur.
-- ---------------------------------------------------------------------------
CREATE TABLE organization_cost_codes (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    code            varchar(30) NOT NULL,
    name            varchar(150) NOT NULL,
    description     varchar(300) NOT NULL DEFAULT '',
    category        varchar(60) NOT NULL DEFAULT '',
    is_active       boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (organization_id, code)
);

CREATE INDEX idx_organization_cost_codes_org ON organization_cost_codes (organization_id);

CREATE TRIGGER organization_cost_codes_set_updated_at BEFORE UPDATE ON organization_cost_codes
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Cost code'lar ASLA hard-delete edilmez (spec: geçmiş bütçe/commitment/
-- expense kayıtları referans veriyor olabilir) -- yalnızca is_active=false
-- (archive) desteklenir, bu yüzden DELETE ucu/politikası bilinçli olarak
-- YOKTUR.

-- ---------------------------------------------------------------------------
-- 2. project_wbs_nodes: proje bazlı, hiyerarşik iş kırılım yapısı (WBS).
-- Yalnızca BÜYÜME yönünde bir ağaçtır -- bu sprintte "re-parent" (bir
-- düğümü başka bir düğümün altına taşıma) İŞLEMİ YOKTUR (spec: "Complex
-- drag/drop zorunlu değil", yalnızca create/rename/reorder/archive) --
-- bu nedenle DÖNGÜ (cycle) OLUŞAMAZ (bir düğümün parent'ı hiç
-- değişmediği için kendi soyundan biri asla olamaz); yine de tutarlılık
-- trigger'ı (self-parent + aynı organizasyon/proje) savunma derinliği
-- olarak eklenir.
-- ---------------------------------------------------------------------------
CREATE TABLE project_wbs_nodes (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id),
    parent_id       uuid REFERENCES project_wbs_nodes(id),
    code            varchar(30) NOT NULL,
    name            varchar(150) NOT NULL,
    sort_order      integer NOT NULL DEFAULT 0,
    is_active       boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project_id, code)
);

CREATE INDEX idx_project_wbs_nodes_org ON project_wbs_nodes (organization_id);
CREATE INDEX idx_project_wbs_nodes_project ON project_wbs_nodes (project_id);
CREATE INDEX idx_project_wbs_nodes_parent ON project_wbs_nodes (parent_id);

CREATE TRIGGER project_wbs_nodes_set_updated_at BEFORE UPDATE ON project_wbs_nodes
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE FUNCTION project_wbs_nodes_check_consistency() RETURNS trigger AS $$
DECLARE
    parent_org  uuid;
    parent_proj uuid;
BEGIN
    IF NEW.parent_id IS NULL THEN
        RETURN NEW;
    END IF;
    IF NEW.parent_id = NEW.id THEN
        RAISE EXCEPTION 'bir WBS düğümü kendi ebeveyni olamaz';
    END IF;
    SELECT organization_id, project_id INTO parent_org, parent_proj
    FROM project_wbs_nodes WHERE id = NEW.parent_id;
    IF parent_proj IS NULL OR parent_proj <> NEW.project_id THEN
        RAISE EXCEPTION 'WBS düğümünün ebeveyni AYNI projeye ait olmalı';
    END IF;
    IF parent_org IS NULL OR parent_org <> NEW.organization_id THEN
        RAISE EXCEPTION 'WBS düğümünün ebeveyni AYNI organizasyona ait olmalı';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_project_wbs_nodes_check_consistency
    BEFORE INSERT OR UPDATE ON project_wbs_nodes
    FOR EACH ROW EXECUTE FUNCTION project_wbs_nodes_check_consistency();

-- ---------------------------------------------------------------------------
-- 3. project_budgets: proje başına TEK bütçe (spec: "gereksiz karmaşık
-- workflow oluşturma... bir projede bir aktif budget olması tercih
-- edilir" -- bu sprintte çoklu bütçe versiyonu YOKTUR, UNIQUE(project_id)
-- ile zorunlu kılınır). draft -> baselined tek yönlü geçiştir (geri
-- dönüş yok); baseline SONRASI değişiklikler yalnızca
-- project_budget_adjustments üzerinden yapılır (bkz. aşağı).
-- ---------------------------------------------------------------------------
CREATE TABLE project_budgets (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id),
    currency        varchar(3) NOT NULL,
    status          varchar(20) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'baselined')),
    -- version, iyimser eşzamanlılık için BİLGİLENDİRİCİ bir sayaçtır --
    -- asıl eşzamanlılık güvencesi (baseline'ın yalnızca BİR KEZ olması,
    -- vb.) FOR UPDATE + status=... WHERE koşuluyla sağlanır (bkz.
    -- project_change_orders'daki AYNI ilke, docs/cost-control.md).
    version         integer NOT NULL DEFAULT 1,
    created_by      uuid REFERENCES users(id),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    baselined_at    timestamptz,
    baselined_by    uuid REFERENCES users(id),
    UNIQUE (project_id)
);

CREATE INDEX idx_project_budgets_org ON project_budgets (organization_id);

CREATE TRIGGER project_budgets_set_updated_at BEFORE UPDATE ON project_budgets
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 4. project_budget_lines: WBS düğümü × cost code bazında planlanan
-- kalemler. FLOAT KULLANILMAZ -- tüm para/miktar alanları NUMERIC,
-- quantity*unit_cost çarpımı SERVİS KATMANINDA SQL numeric ile hesaplanır
-- (bkz. docs/cost-control.md) -- istemcinin gönderdiği original_amount'a
-- KÖRÜ KÖRÜNE güvenilmez (yalnızca quantity/unit_cost'tan biri boşsa,
-- yani kalem toplu/lump-sum girildiyse, istemcinin verdiği tutar
-- kullanılır).
-- ---------------------------------------------------------------------------
CREATE TABLE project_budget_lines (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id),
    budget_id       uuid NOT NULL REFERENCES project_budgets(id) ON DELETE CASCADE,
    wbs_node_id     uuid REFERENCES project_wbs_nodes(id),
    cost_code_id    uuid NOT NULL REFERENCES organization_cost_codes(id),
    description     varchar(300) NOT NULL DEFAULT '',
    quantity        numeric(14, 4),
    unit            varchar(30) NOT NULL DEFAULT '',
    unit_cost       numeric(18, 2),
    original_amount numeric(18, 2) NOT NULL CHECK (original_amount >= 0),
    notes           varchar(500) NOT NULL DEFAULT '',
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_project_budget_lines_org ON project_budget_lines (organization_id);
CREATE INDEX idx_project_budget_lines_project ON project_budget_lines (project_id);
CREATE INDEX idx_project_budget_lines_budget ON project_budget_lines (budget_id);
CREATE INDEX idx_project_budget_lines_wbs ON project_budget_lines (wbs_node_id);
CREATE INDEX idx_project_budget_lines_cost_code ON project_budget_lines (cost_code_id);

CREATE TRIGGER project_budget_lines_set_updated_at BEFORE UPDATE ON project_budget_lines
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Savunma derinliği: wbs_node_id (varsa) AYNI projeye, cost_code_id AYNI
-- organizasyona ait olmalı -- servis katmanındaki kontrolün DB seviyesi
-- güvencesi (project_users'daki AYNI ilke).
CREATE FUNCTION project_budget_lines_check_consistency() RETURNS trigger AS $$
DECLARE
    wbs_project uuid;
    code_org    uuid;
BEGIN
    IF NEW.wbs_node_id IS NOT NULL THEN
        SELECT project_id INTO wbs_project FROM project_wbs_nodes WHERE id = NEW.wbs_node_id;
        IF wbs_project IS NULL OR wbs_project <> NEW.project_id THEN
            RAISE EXCEPTION 'bütçe kaleminin WBS düğümü AYNI projeye ait olmalı';
        END IF;
    END IF;
    SELECT organization_id INTO code_org FROM organization_cost_codes WHERE id = NEW.cost_code_id;
    IF code_org IS NULL OR code_org <> NEW.organization_id THEN
        RAISE EXCEPTION 'bütçe kaleminin cost code''u AYNI organizasyona ait olmalı';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_project_budget_lines_check_consistency
    BEFORE INSERT OR UPDATE ON project_budget_lines
    FOR EACH ROW EXECUTE FUNCTION project_budget_lines_check_consistency();

-- ---------------------------------------------------------------------------
-- 5. project_budget_adjustments: baseline SONRASI bütçe revizyonları.
-- YALNIZCA status='approved' olanlar revised budget'ı etkiler (spec).
-- change_order'lardan BİLİNÇLİ OLARAK AYRI tutulur -- ek işler yalnızca
-- SÖZLEŞME (contract/current_contract_value) matematiğine dokunur,
-- dahili bütçeye DEĞİL (denetim bulgusu: mevcut onay akışı hiçbir
-- maliyet/bütçe tablosuna yazmaz).
-- ---------------------------------------------------------------------------
CREATE TABLE project_budget_adjustments (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id),
    budget_id       uuid NOT NULL REFERENCES project_budgets(id) ON DELETE CASCADE,
    budget_line_id  uuid NOT NULL REFERENCES project_budget_lines(id),
    -- amount NEGATİF olabilir (bütçe azaltımı) -- CHECK ile sıfır
    -- olamayacağı zorunlu kılınır (anlamsız/boş adjustment engeli).
    amount          numeric(18, 2) NOT NULL CHECK (amount <> 0),
    reason          varchar(500) NOT NULL DEFAULT '',
    status          varchar(20) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'approved', 'rejected')),
    created_by      uuid REFERENCES users(id),
    approved_by     uuid REFERENCES users(id),
    approved_at     timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_project_budget_adjustments_org ON project_budget_adjustments (organization_id);
CREATE INDEX idx_project_budget_adjustments_project ON project_budget_adjustments (project_id);
CREATE INDEX idx_project_budget_adjustments_budget ON project_budget_adjustments (budget_id);
CREATE INDEX idx_project_budget_adjustments_line ON project_budget_adjustments (budget_line_id);
CREATE INDEX idx_project_budget_adjustments_status ON project_budget_adjustments (status);

CREATE TRIGGER project_budget_adjustments_set_updated_at BEFORE UPDATE ON project_budget_adjustments
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 6. project_commitments: genel (kaynak-bağımsız) taahhüt defteri. Bu
-- sprintte yalnızca source_type='manual' ÜRETİLİR (spec: "fake purchase
-- order / fake subcontract oluşturma") -- ama şema gelecekteki
-- Procurement/Subcontract modüllerinin (source_type='purchase_order'/
-- 'subcontract', source_id = o modülün satırı) buraya satır YAZABİLMESİ
-- için genel bırakılmıştır.
--
-- ÖNEMLİ: Committed Cost metriği bu tablonun TEK BAŞINA toplamı DEĞİLDİR
-- -- mevcut project_subcontractors.contract_amount (status<>'cancelled')
-- da GERÇEK bir taahhüttür ve zaten mevcut GetProjectFinancialSummary'nin
-- "subcommit" CTE'sinde kullanılıyor. Cost Control'ün committed_cost
-- hesabı İKİSİNİ DE toplar (bkz. docs/cost-control.md) -- taşeron
-- verisini BU tabloya KOPYALAMAK bilinçli olarak YAPILMAZ (duplicate
-- ledger riski, spec §26).
-- ---------------------------------------------------------------------------
CREATE TABLE project_commitments (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id),
    budget_line_id  uuid REFERENCES project_budget_lines(id),
    cost_code_id    uuid NOT NULL REFERENCES organization_cost_codes(id),
    source_type     varchar(20) NOT NULL DEFAULT 'manual' CHECK (source_type IN ('manual', 'purchase_order', 'subcontract')),
    source_id       uuid,
    description     varchar(300) NOT NULL DEFAULT '',
    committed_amount numeric(18, 2) NOT NULL CHECK (committed_amount > 0),
    currency        varchar(3) NOT NULL,
    status          varchar(20) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'voided')),
    committed_at    date NOT NULL,
    idempotency_key varchar(100),
    created_by      uuid REFERENCES users(id),
    voided_at       timestamptz,
    voided_by       uuid REFERENCES users(id),
    void_reason     varchar(300) NOT NULL DEFAULT '',
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_project_commitments_org ON project_commitments (organization_id);
CREATE INDEX idx_project_commitments_project ON project_commitments (project_id);
CREATE INDEX idx_project_commitments_line ON project_commitments (budget_line_id);
CREATE INDEX idx_project_commitments_cost_code ON project_commitments (cost_code_id);
CREATE INDEX idx_project_commitments_status ON project_commitments (status);
-- Eşzamanlı çift-tıklama/ağ tekrarına karşı: AYNI projede AYNI
-- idempotency_key ile ikinci bir manuel taahhüt YARATILAMAZ (mevcut
-- collections/expenses/subcontractor-payments idempotency deseniyle
-- AYNI ilke -- kısmi UNIQUE indeks, yalnızca anahtar verilmişse).
CREATE UNIQUE INDEX idx_project_commitments_idempotency
    ON project_commitments (project_id, idempotency_key) WHERE idempotency_key IS NOT NULL;

CREATE TRIGGER project_commitments_set_updated_at BEFORE UPDATE ON project_commitments
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE FUNCTION project_commitments_check_consistency() RETURNS trigger AS $$
DECLARE
    line_project uuid;
    code_org     uuid;
BEGIN
    IF NEW.budget_line_id IS NOT NULL THEN
        SELECT project_id INTO line_project FROM project_budget_lines WHERE id = NEW.budget_line_id;
        IF line_project IS NULL OR line_project <> NEW.project_id THEN
            RAISE EXCEPTION 'taahhüdün bütçe kalemi AYNI projeye ait olmalı';
        END IF;
    END IF;
    SELECT organization_id INTO code_org FROM organization_cost_codes WHERE id = NEW.cost_code_id;
    IF code_org IS NULL OR code_org <> NEW.organization_id THEN
        RAISE EXCEPTION 'taahhüdün cost code''u AYNI organizasyona ait olmalı';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_project_commitments_check_consistency
    BEFORE INSERT OR UPDATE ON project_commitments
    FOR EACH ROW EXECUTE FUNCTION project_commitments_check_consistency();

-- ---------------------------------------------------------------------------
-- 7. project_cost_forecasts: bütçe kalemi başına MANUEL ETC (Estimate To
-- Complete) override'ı. Satır YOKSA varsayılan ETC servis katmanında
-- GREATEST(revised_budget - actual_cost, 0) olarak hesaplanır (spec'in
-- önerdiği "safer MVP" yaklaşımı -- MAX(revised-actual, committed-actual,
-- 0) gibi daha karmaşık bir formül KÖRLEMESİNE uygulanmamıştır, bkz.
-- docs/cost-control.md).
-- ---------------------------------------------------------------------------
CREATE TABLE project_cost_forecasts (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id),
    budget_line_id  uuid NOT NULL REFERENCES project_budget_lines(id),
    etc_amount      numeric(18, 2) NOT NULL DEFAULT 0 CHECK (etc_amount >= 0),
    note            varchar(500) NOT NULL DEFAULT '',
    updated_by      uuid REFERENCES users(id),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (budget_line_id)
);

CREATE INDEX idx_project_cost_forecasts_org ON project_cost_forecasts (organization_id);
CREATE INDEX idx_project_cost_forecasts_project ON project_cost_forecasts (project_id);

-- ---------------------------------------------------------------------------
-- 8. Mevcut tabloların EK (nullable) genişletmesi: actual cost (expenses)
-- ve mevcut taşeron taahhütleri (subcontractors) bir cost code'a
-- etiketlenebilsin. NULL bırakılabilir -- mevcut kayıtlar/akışlar
-- BOZULMAZ (spec §11, §24, §42).
-- ---------------------------------------------------------------------------
ALTER TABLE project_expenses ADD COLUMN cost_code_id uuid REFERENCES organization_cost_codes(id);
ALTER TABLE project_expenses ADD COLUMN budget_line_id uuid REFERENCES project_budget_lines(id);
CREATE INDEX idx_project_expenses_cost_code ON project_expenses (cost_code_id);
CREATE INDEX idx_project_expenses_budget_line ON project_expenses (budget_line_id);

ALTER TABLE project_subcontractors ADD COLUMN cost_code_id uuid REFERENCES organization_cost_codes(id);
CREATE INDEX idx_project_subcontractors_cost_code ON project_subcontractors (cost_code_id);

-- ---------------------------------------------------------------------------
-- 8b. organization_events: organizasyon-seviyesi (proje-BAĞIMSIZ) denetim
-- kaydı. Mevcut project_events (project_id ZORUNLU) organizasyon
-- kataloğu düzeyindeki bir işlem (ör. maliyet kodu oluşturma) için
-- KULLANILAMAZ -- ve platform_audit_events, adı/yorumu/kullanım yeri
-- gereği Super Admin'in PLATFORM işlemlerine özeldir (tenant kullanıcısı
-- olayları karıştırılmamalı, ör. Super Admin'in "firma denetim kayıtları"
-- görünümü tenant gürültüsüyle kirlenmemeli). Repo'nun KENDİ ilkesi
-- ("her domain kendi *_events tablosunu kullanır", bkz. migration 0033
-- yorumu) buradan hareketle project_events'in AYNI deseninin org-seviyesi
-- karşılığı olarak eklenir -- YENİ bir audit PARADİGMASI değildir.
-- ---------------------------------------------------------------------------
CREATE TABLE organization_events (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    event_type      varchar(50) NOT NULL,
    user_id         uuid REFERENCES users(id) ON DELETE SET NULL,
    metadata        jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_organization_events_org ON organization_events (organization_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- 9. İzin kayıt defteri genişletmesi (RBAC/Project Membership sprint'i,
-- migration 0034, İLE AYNI desen: <domain>.<subresource>.<action>).
-- ---------------------------------------------------------------------------
INSERT INTO permissions (code, description, category) VALUES
    ('projects.budget.read',         'Proje bütçesini görüntüleme',                 'Finans'),
    ('projects.budget.manage',       'Proje bütçesini oluşturma/onaylama/revize etme', 'Finans'),
    ('projects.cost_control.read',   'Maliyet kontrolü (WBS/taahhüt/tahmin) görüntüleme', 'Finans'),
    ('projects.cost_control.manage', 'Maliyet kontrolünü (WBS/taahhüt/tahmin) yönetme',   'Finans'),
    ('organization.cost_codes.read', 'Maliyet kodu kataloğunu görüntüleme',          'Firma Yönetimi'),
    ('organization.cost_codes.manage','Maliyet kodu kataloğunu yönetme',             'Firma Yönetimi');

-- ---------------------------------------------------------------------------
-- 10. seed_system_roles_for_org fonksiyonu GÜNCELLENİR (CREATE OR REPLACE)
-- ki YENİ organizasyonlar (PlatformService.CreateOrganizationWithOwner)
-- BU yeni izinleri de doğru role'lere otomatik alsın. owner/admin zaten
-- migration 0034'te "SELECT code FROM permissions" ile TÜM izinleri
-- (yeni eklenenler dahil) otomatik kazanıyor -- bu fonksiyonun owner/
-- admin bloğu DEĞİŞMEDİ, yalnızca legacy_user/project_manager/finance
-- bloklarına yeni WHERE IN listeleri eklendi. field HİÇBİR yeni izin
-- ALMAZ (spec: "FIELD: no financial visibility").
--
-- Rol matrisi kararları (final raporda da tekrarlanacak):
--   legacy_user: budget.read/manage + cost_control.read/manage (mevcut
--     finance.read/manage ile TAM PARİTE -- migration öncesi 'kullanici'
--     zaten koşulsuz tam finans erişimine sahipti) ama
--     organization.cost_codes.manage YOK (yalnızca read -- products/
--     calculations'taki "read var, manage yok" örüntüsüyle TUTARLI).
--   project_manager: budget.read + cost_control.read (spec'in kendi
--     önerisi) + organization.cost_codes.read (var olan products.read/
--     customers.read örüntüsüyle tutarlı) -- budget.manage/cost_control.
--     manage/cost_codes.manage BİLİNÇLİ OLARAK VERİLMEDİ (business kararı:
--     PM bugün HİÇBİR finans iznine sahip değil, bütçe oluşturma/onaylama
--     Finans/Owner/Admin'de kalmalı; final raporda açıkça gerekçelendirilir).
--   finance: budget.read/manage + cost_control.read/manage +
--     organization.cost_codes.read/manage (TAM -- mevcut finance.read/
--     manage tam yetkisiyle tutarlı, cost code kataloğunun doğal sahibi).
--   field: HİÇBİRİ (spec'in açık talimatı).
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

    -- legacy_user: migration öncesi "kullanici" rolünün GERÇEK erişimiyle
    -- birebir eşleşir (bkz. migration 0034 yorumu) + Cost Control tam
    -- parite (yukarıdaki gerekçe notu).
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
        'organization.cost_codes.read'
    );

    -- project_manager: yalnızca atandığı projelerde operasyon + Cost
    -- Control'ü GÖRÜNTÜLEME (yukarıdaki gerekçe notu).
    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_pm, code FROM permissions WHERE code IN (
        'projects.read', 'projects.update',
        'projects.tasks.read', 'projects.tasks.create', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'projects.access.read',
        'calculations.read', 'products.read', 'customers.read',
        'projects.budget.read', 'projects.cost_control.read',
        'organization.cost_codes.read'
    );

    -- finance: yalnızca atandığı projelerin finansı + Cost Control TAM.
    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_finance, code FROM permissions WHERE code IN (
        'projects.read', 'projects.finance.read', 'projects.finance.manage',
        'projects.budget.read', 'projects.budget.manage',
        'projects.cost_control.read', 'projects.cost_control.manage',
        'organization.cost_codes.read', 'organization.cost_codes.manage'
    );

    -- field: yalnızca atandığı projelerde saha operasyonu -- Cost
    -- Control/bütçe İZNİ YOK (spec: "no financial visibility").
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
-- 11. MEVCUT organizasyonların ZATEN seed edilmiş rollerine yeni izinleri
-- BACKFILL et -- CREATE OR REPLACE FUNCTION yalnızca YENİ organizasyonları
-- etkiler, mevcut organization_roles satırlarını GERİYE DÖNÜK
-- GÜNCELLEMEZ. owner/admin zaten "tüm izinler" mantığıyla otomatik
-- kazanır (aşağıdaki ilk iki INSERT); diğer 3 rol için AYNI WHERE IN
-- listeleri (yukarıdaki fonksiyonla TUTARLI, DRY ihlali görünse de
-- PL/pgSQL'de bir fonksiyonun gövdesini metin olarak yeniden kullanmak
-- mümkün değildir -- iki kopya kasıtlı ve testle senkron tutulur).
-- ---------------------------------------------------------------------------
INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code IN ('owner', 'admin')
  AND p.code IN ('projects.budget.read', 'projects.budget.manage',
                 'projects.cost_control.read', 'projects.cost_control.manage',
                 'organization.cost_codes.read', 'organization.cost_codes.manage')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code = 'legacy_user'
  AND p.code IN ('projects.budget.read', 'projects.budget.manage',
                 'projects.cost_control.read', 'projects.cost_control.manage',
                 'organization.cost_codes.read')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code = 'project_manager'
  AND p.code IN ('projects.budget.read', 'projects.cost_control.read', 'organization.cost_codes.read')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code = 'finance'
  AND p.code IN ('projects.budget.read', 'projects.budget.manage',
                 'projects.cost_control.read', 'projects.cost_control.manage',
                 'organization.cost_codes.read', 'organization.cost_codes.manage')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

-- field: yeni izin YOK, kasıtlı olarak hiçbir INSERT yapılmaz.
