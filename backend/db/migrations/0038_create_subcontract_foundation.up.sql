-- ARVEND V2 — Sprint 5: Taşeron Yönetimi (Subcontractor Management).
-- Subcontract + SOV + Subcontract Change Orders + Progress Claims (Hakediş)
-- + Cost Control commitment entegrasyonu.
--
-- ---------------------------------------------------------------------------
-- KRİTİK — ÖNCEKİ (Faz 8'den kalma, migration 0024) "project_subcontractors"
-- / "project_subcontractor_payments" tablolarıyla KARIŞTIRILMAMALI. Bu
-- ikisi, Sprint 5 denetim aşamasında keşfedilen, bugün HÂLÂ CANLI ve
-- ÇALIŞAN, TAMAMEN BAĞIMSIZ bir sistemdir:
--
--   - project_subcontractors: proje-başına düz bir taşeron kaydı (ad,
--     şirket, iletişim, TEK bir contract_amount, basit
--     planned/active/completed/cancelled durumu). Web'de "Finans" sekmesi
--     içinde "Taşeronlar" bölümü olarak GERÇEKTEN kullanılıyor.
--   - project_subcontractor_payments: o taşerona GERÇEKTEN ödenen tutarlar
--     (voidable, idempotent) — GetProjectFinancialSummary'nin
--     realized_cost/committed_cost hesabına GİRİYOR (bkz. docs/cost-control.md
--     §5, Sprint 5 düzeltmesi).
--
-- Bu migration BUNLARA DOKUNMAZ, BUNLARI DEĞİŞTİRMEZ, BUNLARLA
-- BİRLEŞTİRMEZ. Sprint 5, TAMAMEN YENİ, çok daha zengin bir "iş
-- sözleşmesi" modeli (SOV/yaşam döngüsü/değişiklik emri/hakediş/Cost
-- Control commitment entegrasyonu) inşa eder — bu iki sistem KASITLI
-- OLARAK bu sprintte birleştirilmemiştir (gerçek ödeme kayıtlarına
-- dokunmak, açık kullanıcı talimatı olmadan YAPILMAZ). Detaylı gerekçe:
-- docs/subcontracts.md "Legacy Taşeron Sistemi" bölümü.
--
-- Yeni varlıklar bu yüzden BİLİNÇLİ OLARAK "project_subcontracts" (TEKİL
-- "subcontract", ÇOĞUL DEĞİL "subcontractors") adını taşır — mevcut
-- "project_subcontractors" tablosuyla isim çakışmasını önlemek için.
-- ---------------------------------------------------------------------------
--
-- Zincir: Supplier (Sprint 4, mevcut vendor master — YENİDEN KULLANILIR,
-- yeni bir taşeron/vendor tablosu İCAT EDİLMEDİ) -> Subcontract -> SOV
-- (subcontract_items) -> Activation (Cost Control commitment oluşturur,
-- source_type='subcontract') -> Subcontract Change Order (onaylanınca
-- commitment'ları YENİDEN SENKRONİZE eder) -> Progress Claim/Hakediş
-- (retention/advance/deductions, backend-authoritative) -> Termination
-- (kazanılmış/sertifikalı tutar KORUNUR, kalan taahhüt SERBEST BIRAKILIR).
--
-- Customer Contract/Change Order (Sprint 3, GELİR tarafı) İLE
-- KARIŞTIRILMAMALI — bu zincir MALİYET tarafıdır, ikisi arasında hiçbir
-- otomatik bağlantı YOKTUR (bkz. docs/subcontracts.md §Sınır Kuralları).

-- ---------------------------------------------------------------------------
-- 1. suppliers'a isteğe bağlı "specialty" (branş/uzmanlık alanı) eklenir --
-- YENİ bir vendor/subcontractor master tablosu İCAT EDİLMEDİ (spec §3:
-- "aynı vendor/supplier organization kaydı farklı capabilities taşıyabilsin").
-- Herhangi bir AKTİF supplier, hiçbir "capability"/"type" bayrağı
-- gerekmeksizin bir subcontract'ta supplier_id olarak kullanılabilir --
-- bugüne kadar PO/RFQ/PR ile Subcontract arasında supplier kullanılabilirliği
-- açısından hiçbir davranış farkı yok, o yüzden normalize bir tip alanı
-- GEREKMİYOR (basit, additive, mevcut şemaya en uygun çözüm). Sigorta/
-- yeterlilik/uygunluk belgesi metadata'sı BİLİNÇLİ OLARAK bu sprintte
-- eklenmedi (spec §4: "devasa vendor prequalification sistemi kurma").
-- ---------------------------------------------------------------------------
ALTER TABLE suppliers ADD COLUMN specialty varchar(150) NOT NULL DEFAULT '';

-- ---------------------------------------------------------------------------
-- 2. Sayaçlar -- purchase_request_counters/rfq_counters/purchase_order_counters
-- İLE BİREBİR AYNI desen (organizasyon+yıl kapsamlı, atomik upsert,
-- SELECT MAX+1 YOK). SC-YYYY-NNNN/SCO-YYYY-NNNN/SPC-YYYY-NNNN, PR/RFQ/PO
-- İLE AYNI gerekçeyle organizasyon-geneli (change_order_counters'ın
-- proje-başına EK-NNN deseninin AKSİNE) -- taşeron sözleşmesi/değişikliği/
-- hakedişi de "organizasyonel olarak anlamlı finansal belge" kategorisidir.
-- ---------------------------------------------------------------------------
CREATE TABLE subcontract_counters (
    organization_id uuid NOT NULL REFERENCES organizations(id),
    year            int NOT NULL,
    seq             int NOT NULL DEFAULT 0,
    PRIMARY KEY (organization_id, year)
);

CREATE TABLE subcontract_change_order_counters (
    organization_id uuid NOT NULL REFERENCES organizations(id),
    year            int NOT NULL,
    seq             int NOT NULL DEFAULT 0,
    PRIMARY KEY (organization_id, year)
);

CREATE TABLE subcontract_progress_claim_counters (
    organization_id uuid NOT NULL REFERENCES organizations(id),
    year            int NOT NULL,
    seq             int NOT NULL DEFAULT 0,
    PRIMARY KEY (organization_id, year)
);

-- ---------------------------------------------------------------------------
-- 3. project_subcontracts -- taşeronla yapılan İŞ SÖZLEŞMESİ (Contract'ın
-- Sprint 3'teki durum makinesi/baseline-kilitleme İLKESİYLE AYNI, ama
-- Contract'ın AKSİNE proje başına TEK değil ÇOK OLABİLİR (UNIQUE(project_id)
-- YOK) -- bir projenin birden çok taşeronu/branşı olabilir.
--
-- Durum makinesi: draft -> active (ticari taban KİLİTLENİR, commitment
-- OLUŞTURULUR) -> completed (normal, commitment'a DOKUNMAZ, PO'nun
-- "closed"ıyla AYNI ilke) ; draft -> cancelled (commitment hiç yok, no-op) ;
-- active -> terminated (gerekçe zorunlu, commitment'lar sertifikalı tutara
-- göre YENİDEN SENKRONİZE edilir, bkz. docs/subcontracts.md).
-- ---------------------------------------------------------------------------
CREATE TABLE project_subcontracts (
    id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id          uuid NOT NULL REFERENCES organizations(id),
    project_id               uuid NOT NULL REFERENCES projects(id),
    subcontract_no           varchar(30) NOT NULL,
    supplier_id              uuid NOT NULL REFERENCES suppliers(id),
    title                    varchar(200) NOT NULL,
    scope_summary            text NOT NULL DEFAULT '',
    -- items'tan backend tarafından YENİDEN HESAPLANIR (tek source-of-truth
    -- = subcontract_items, bkz. RecomputeSubcontractTotal) -- doğrudan
    -- yazılabilir bir alan DEĞİLDİR.
    original_amount          numeric(18, 2) NOT NULL DEFAULT 0 CHECK (original_amount >= 0),
    currency                 varchar(3) NOT NULL,
    status                   varchar(20) NOT NULL DEFAULT 'draft'
                              CHECK (status IN ('draft', 'active', 'completed', 'cancelled', 'terminated')),
    effective_date           date,
    start_date               date,
    planned_completion_date  date,
    retention_percent        numeric(5, 2) CHECK (retention_percent IS NULL OR (retention_percent >= 0 AND retention_percent <= 100)),
    advance_amount           numeric(18, 2) CHECK (advance_amount IS NULL OR advance_amount >= 0),
    payment_terms            text NOT NULL DEFAULT '',
    notes                    text NOT NULL DEFAULT '',
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
    UNIQUE (organization_id, subcontract_no)
);

CREATE INDEX idx_project_subcontracts_org ON project_subcontracts (organization_id);
CREATE INDEX idx_project_subcontracts_project ON project_subcontracts (project_id);
CREATE INDEX idx_project_subcontracts_supplier ON project_subcontracts (supplier_id);
CREATE INDEX idx_project_subcontracts_status ON project_subcontracts (status);

CREATE TRIGGER project_subcontracts_set_updated_at BEFORE UPDATE ON project_subcontracts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Savunma derinliği: tedarikçi AYNI organizasyona ait olmalı (çapraz-org
-- tedarikçi kullanımı, spec §24 "cross tenant vendor: denied" -- Sprint 4'ün
-- purchase_orders_check_consistency İLE BİREBİR AYNI desen).
CREATE FUNCTION project_subcontracts_check_consistency() RETURNS trigger AS $$
DECLARE
    supplier_org uuid;
BEGIN
    SELECT organization_id INTO supplier_org FROM suppliers WHERE id = NEW.supplier_id;
    IF supplier_org IS NULL OR supplier_org <> NEW.organization_id THEN
        RAISE EXCEPTION 'Taşeron sözleşmesinin tedarikçisi AYNI organizasyona ait olmalı';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_project_subcontracts_check_consistency
    BEFORE INSERT OR UPDATE ON project_subcontracts
    FOR EACH ROW EXECUTE FUNCTION project_subcontracts_check_consistency();

-- ---------------------------------------------------------------------------
-- 4. subcontract_items -- Schedule of Values (SOV). cost_code_id ZORUNLUDUR
-- (purchase_order_items İLE AYNI gerekçe: bu tablo commitment'ın DOĞRUDAN
-- kaynağıdır). quantity/unit/unit_price'ın ÜÇÜ de opsiyoneldir (spec §9:
-- bazı SOV kalemleri toplu/lump-sum olabilir, quantity*birim_fiyat
-- anlamlı olmayabilir) -- original_amount HER ZAMAN zorunludur (ikisi de
-- doluysa SQL'de round(quantity*unit_price,2) olarak hesaplanır, aksi
-- halde istemcinin gönderdiği değer kullanılır -- project_budget_lines
-- İLE AYNI "kısmi doluluk" kuralı, bkz. docs/cost-control.md §6).
-- ---------------------------------------------------------------------------
CREATE TABLE subcontract_items (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    project_id       uuid NOT NULL REFERENCES projects(id),
    subcontract_id   uuid NOT NULL REFERENCES project_subcontracts(id) ON DELETE CASCADE,
    wbs_node_id      uuid REFERENCES project_wbs_nodes(id),
    cost_code_id     uuid NOT NULL REFERENCES organization_cost_codes(id),
    budget_line_id   uuid REFERENCES project_budget_lines(id),
    description      varchar(300) NOT NULL,
    quantity         numeric(14, 4),
    unit             varchar(30) NOT NULL DEFAULT '',
    unit_price       numeric(18, 2),
    original_amount  numeric(18, 2) NOT NULL CHECK (original_amount > 0),
    sort_order       int NOT NULL DEFAULT 0,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_subcontract_items_subcontract ON subcontract_items (subcontract_id);
CREATE INDEX idx_subcontract_items_cost_code ON subcontract_items (cost_code_id);
CREATE INDEX idx_subcontract_items_budget_line ON subcontract_items (budget_line_id);

CREATE TRIGGER subcontract_items_set_updated_at BEFORE UPDATE ON subcontract_items
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- purchase_order_items_check_consistency İLE BİREBİR AYNI desen.
CREATE FUNCTION subcontract_items_check_consistency() RETURNS trigger AS $$
DECLARE
    wbs_project  uuid;
    line_project uuid;
    code_org     uuid;
    sc_project   uuid;
BEGIN
    SELECT project_id INTO sc_project FROM project_subcontracts WHERE id = NEW.subcontract_id;
    IF sc_project IS NULL OR sc_project <> NEW.project_id THEN
        RAISE EXCEPTION 'SOV kalemi, taşeron sözleşmesinin KENDİ projesine ait olmalı';
    END IF;
    IF NEW.wbs_node_id IS NOT NULL THEN
        SELECT project_id INTO wbs_project FROM project_wbs_nodes WHERE id = NEW.wbs_node_id;
        IF wbs_project IS NULL OR wbs_project <> NEW.project_id THEN
            RAISE EXCEPTION 'SOV kaleminin WBS düğümü AYNI projeye ait olmalı';
        END IF;
    END IF;
    IF NEW.budget_line_id IS NOT NULL THEN
        SELECT project_id INTO line_project FROM project_budget_lines WHERE id = NEW.budget_line_id;
        IF line_project IS NULL OR line_project <> NEW.project_id THEN
            RAISE EXCEPTION 'SOV kaleminin bütçe kalemi AYNI projeye ait olmalı';
        END IF;
    END IF;
    SELECT organization_id INTO code_org FROM organization_cost_codes WHERE id = NEW.cost_code_id;
    IF code_org IS NULL OR code_org <> NEW.organization_id THEN
        RAISE EXCEPTION 'SOV kaleminin cost code''u AYNI organizasyona ait olmalı';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_subcontract_items_check_consistency
    BEFORE INSERT OR UPDATE ON subcontract_items
    FOR EACH ROW EXECUTE FUNCTION subcontract_items_check_consistency();

-- ---------------------------------------------------------------------------
-- 5. subcontract_change_orders -- Customer Change Order (Sprint 3) tablosu
-- ASLA yeniden kullanılmaz (spec §12: "Müşteri Change Order tablosunu
-- reuse etme") -- MALİYET tarafı için AYRI, bağımsız bir domaindir.
-- "reason" değişikliğin KENDİ gerekçesi (oluşturmada girilir); rejection_
-- reason/cancel_reason terminal olumsuz sonuçlar için AYRI alanlardır
-- (purchase_requests İLE AYNI denetlenebilirlik deseni).
-- ---------------------------------------------------------------------------
CREATE TABLE subcontract_change_orders (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id   uuid NOT NULL REFERENCES organizations(id),
    project_id        uuid NOT NULL REFERENCES projects(id),
    subcontract_id    uuid NOT NULL REFERENCES project_subcontracts(id),
    number            varchar(30) NOT NULL,
    title             varchar(200) NOT NULL,
    description       text NOT NULL DEFAULT '',
    change_type       varchar(10) NOT NULL CHECK (change_type IN ('addition', 'deduction')),
    -- items'tan backend tarafından YENİDEN HESAPLANIR (subcontract_items İLE
    -- AYNI tek-source-of-truth ilkesi).
    amount            numeric(18, 2) NOT NULL DEFAULT 0 CHECK (amount >= 0),
    status            varchar(20) NOT NULL DEFAULT 'draft'
                       CHECK (status IN ('draft', 'submitted', 'approved', 'rejected', 'cancelled')),
    reason            text NOT NULL DEFAULT '',
    requested_at      timestamptz,
    approved_at       timestamptz,
    approved_by       uuid REFERENCES users(id),
    rejected_at       timestamptz,
    rejected_by       uuid REFERENCES users(id),
    rejection_reason  varchar(500) NOT NULL DEFAULT '',
    cancelled_at      timestamptz,
    cancelled_by      uuid REFERENCES users(id),
    created_by        uuid REFERENCES users(id),
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (organization_id, number)
);

CREATE INDEX idx_subcontract_cos_subcontract ON subcontract_change_orders (subcontract_id);
CREATE INDEX idx_subcontract_cos_status ON subcontract_change_orders (status);

CREATE TRIGGER subcontract_change_orders_set_updated_at BEFORE UPDATE ON subcontract_change_orders
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE FUNCTION subcontract_change_orders_check_consistency() RETURNS trigger AS $$
DECLARE
    sc_project uuid;
BEGIN
    SELECT project_id INTO sc_project FROM project_subcontracts WHERE id = NEW.subcontract_id;
    IF sc_project IS NULL OR sc_project <> NEW.project_id THEN
        RAISE EXCEPTION 'Taşeron değişikliği, taşeron sözleşmesinin KENDİ projesine ait olmalı';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_subcontract_change_orders_check_consistency
    BEFORE INSERT OR UPDATE ON subcontract_change_orders
    FOR EACH ROW EXECUTE FUNCTION subcontract_change_orders_check_consistency();

-- ---------------------------------------------------------------------------
-- 6. subcontract_change_order_items -- satır bazlı etki (spec §13:
-- "Mümkünse header amount yerine line-level impact destekle... WBS/cost
-- code/budget line gereklidir"). cost_code_id ZORUNLUDUR (onaylanınca
-- commitment senkronizasyonuna DOĞRUDAN girer, subcontract_items İLE AYNI
-- gerekçe).
-- ---------------------------------------------------------------------------
CREATE TABLE subcontract_change_order_items (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    project_id       uuid NOT NULL REFERENCES projects(id),
    change_order_id  uuid NOT NULL REFERENCES subcontract_change_orders(id) ON DELETE CASCADE,
    wbs_node_id      uuid REFERENCES project_wbs_nodes(id),
    cost_code_id     uuid NOT NULL REFERENCES organization_cost_codes(id),
    budget_line_id   uuid REFERENCES project_budget_lines(id),
    description      varchar(300) NOT NULL,
    amount           numeric(18, 2) NOT NULL CHECK (amount > 0),
    sort_order       int NOT NULL DEFAULT 0
);

CREATE INDEX idx_subcontract_co_items_co ON subcontract_change_order_items (change_order_id);

CREATE FUNCTION subcontract_change_order_items_check_consistency() RETURNS trigger AS $$
DECLARE
    wbs_project  uuid;
    line_project uuid;
    code_org     uuid;
    co_project   uuid;
BEGIN
    SELECT project_id INTO co_project FROM subcontract_change_orders WHERE id = NEW.change_order_id;
    IF co_project IS NULL OR co_project <> NEW.project_id THEN
        RAISE EXCEPTION 'Değişiklik kalemi, değişikliğin KENDİ projesine ait olmalı';
    END IF;
    IF NEW.wbs_node_id IS NOT NULL THEN
        SELECT project_id INTO wbs_project FROM project_wbs_nodes WHERE id = NEW.wbs_node_id;
        IF wbs_project IS NULL OR wbs_project <> NEW.project_id THEN
            RAISE EXCEPTION 'Değişiklik kaleminin WBS düğümü AYNI projeye ait olmalı';
        END IF;
    END IF;
    IF NEW.budget_line_id IS NOT NULL THEN
        SELECT project_id INTO line_project FROM project_budget_lines WHERE id = NEW.budget_line_id;
        IF line_project IS NULL OR line_project <> NEW.project_id THEN
            RAISE EXCEPTION 'Değişiklik kaleminin bütçe kalemi AYNI projeye ait olmalı';
        END IF;
    END IF;
    SELECT organization_id INTO code_org FROM organization_cost_codes WHERE id = NEW.cost_code_id;
    IF code_org IS NULL OR code_org <> NEW.organization_id THEN
        RAISE EXCEPTION 'Değişiklik kaleminin cost code''u AYNI organizasyona ait olmalı';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_subcontract_co_items_check_consistency
    BEFORE INSERT OR UPDATE ON subcontract_change_order_items
    FOR EACH ROW EXECUTE FUNCTION subcontract_change_order_items_check_consistency();

-- ---------------------------------------------------------------------------
-- 7. subcontract_progress_claims -- Taşeron Hakedişi. Customer/müşteri
-- hakedişi DEĞİLDİR (spec §25, Sprint 6'ya bırakıldı) ve Supplier Invoice
-- DEĞİLDİR (spec §26 -- e-Fatura/AP bu sprintte YOK). retention_percent_
-- snapshot, sözleşmenin O ANKİ retention_percent'inin KOPYASIDIR -- sonradan
-- sözleşme retention oranı değişirse GEÇMİŞ hakedişler SESSİZCE MUTATE
-- OLMAZ (spec §19).
--
-- previous_certified_amount/current_certified_amount, bu taşeronun TÜM
-- sertifikalı hakedişleri arasında KÜMÜLATİF bir sayaçtır (bu hakedişten
-- ÖNCEKİ toplam / bu hakediş DAHİL toplam) -- item seviyesindeki
-- previous/current/cumulative_progress_amount deseninin HEADER karşılığı.
--
-- net_payable = gross_work_amount - retention_amount - advance_recovery_
-- amount - other_deductions (spec §22, backend-authoritative, HER ZAMAN
-- SQL'de hesaplanır).
-- ---------------------------------------------------------------------------
CREATE TABLE subcontract_progress_claims (
    id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id             uuid NOT NULL REFERENCES organizations(id),
    project_id                  uuid NOT NULL REFERENCES projects(id),
    subcontract_id              uuid NOT NULL REFERENCES project_subcontracts(id),
    claim_number                varchar(30) NOT NULL,
    period_start                date,
    period_end                  date NOT NULL,
    status                      varchar(20) NOT NULL DEFAULT 'draft'
                                 CHECK (status IN ('draft', 'submitted', 'certified', 'rejected', 'cancelled')),
    -- items'tan backend tarafından YENİDEN HESAPLANIR.
    gross_work_amount           numeric(18, 2) NOT NULL DEFAULT 0 CHECK (gross_work_amount >= 0),
    retention_percent_snapshot  numeric(5, 2) NOT NULL DEFAULT 0,
    retention_amount            numeric(18, 2) NOT NULL DEFAULT 0 CHECK (retention_amount >= 0),
    advance_recovery_amount     numeric(18, 2) NOT NULL DEFAULT 0 CHECK (advance_recovery_amount >= 0),
    other_deductions            numeric(18, 2) NOT NULL DEFAULT 0 CHECK (other_deductions >= 0),
    previous_certified_amount   numeric(18, 2) NOT NULL DEFAULT 0 CHECK (previous_certified_amount >= 0),
    current_certified_amount    numeric(18, 2) NOT NULL DEFAULT 0 CHECK (current_certified_amount >= 0),
    net_payable                 numeric(18, 2) NOT NULL DEFAULT 0,
    submitted_at                timestamptz,
    certified_at                timestamptz,
    certified_by                uuid REFERENCES users(id),
    rejected_at                 timestamptz,
    rejected_by                 uuid REFERENCES users(id),
    rejection_reason            varchar(500) NOT NULL DEFAULT '',
    cancelled_at                timestamptz,
    cancelled_by                uuid REFERENCES users(id),
    notes                       text NOT NULL DEFAULT '',
    created_by                  uuid REFERENCES users(id),
    created_at                  timestamptz NOT NULL DEFAULT now(),
    updated_at                  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (organization_id, claim_number)
);

CREATE INDEX idx_subcontract_claims_subcontract ON subcontract_progress_claims (subcontract_id);
CREATE INDEX idx_subcontract_claims_status ON subcontract_progress_claims (status);

CREATE TRIGGER subcontract_progress_claims_set_updated_at BEFORE UPDATE ON subcontract_progress_claims
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE FUNCTION subcontract_progress_claims_check_consistency() RETURNS trigger AS $$
DECLARE
    sc_project uuid;
BEGIN
    SELECT project_id INTO sc_project FROM project_subcontracts WHERE id = NEW.subcontract_id;
    IF sc_project IS NULL OR sc_project <> NEW.project_id THEN
        RAISE EXCEPTION 'Hakediş, taşeron sözleşmesinin KENDİ projesine ait olmalı';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_subcontract_progress_claims_check_consistency
    BEFORE INSERT OR UPDATE ON subcontract_progress_claims
    FOR EACH ROW EXECUTE FUNCTION subcontract_progress_claims_check_consistency();

-- ---------------------------------------------------------------------------
-- 8. subcontract_progress_claim_items -- SOV bazlı hakediş kalemleri (spec
-- §17). progress_percent/remaining_amount KASITLI OLARAK STORED DEĞİLDİR --
-- tek source-of-truth (scheduled_value, cumulative_progress_amount) her
-- zaman canlı türetilir (bkz. sorgu katmanı). scheduled_value, hakediş
-- OLUŞTURULDUĞU ANDAKİ SOV kalemi tutarının SNAPSHOT'ıdır -- sonradan bir
-- değişiklik emri o kalemi etkilerse, GEÇMİŞ hakedişler SESSİZCE MUTATE
-- OLMAZ (retention_percent_snapshot İLE AYNI ilke).
--
-- CHECK (cumulative_progress_amount <= scheduled_value): %100 üstü
-- yanlışlıkla geçiş DB seviyesinde de engellenir (savunma derinliği, Go
-- seviyesindeki doğrulamayla AYNI kural).
-- ---------------------------------------------------------------------------
CREATE TABLE subcontract_progress_claim_items (
    id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id             uuid NOT NULL REFERENCES organizations(id),
    project_id                  uuid NOT NULL REFERENCES projects(id),
    progress_claim_id           uuid NOT NULL REFERENCES subcontract_progress_claims(id) ON DELETE CASCADE,
    subcontract_item_id         uuid NOT NULL REFERENCES subcontract_items(id),
    scheduled_value             numeric(18, 2) NOT NULL CHECK (scheduled_value > 0),
    previous_progress_amount    numeric(18, 2) NOT NULL DEFAULT 0 CHECK (previous_progress_amount >= 0),
    current_progress_amount     numeric(18, 2) NOT NULL DEFAULT 0 CHECK (current_progress_amount >= 0),
    cumulative_progress_amount  numeric(18, 2) NOT NULL DEFAULT 0 CHECK (cumulative_progress_amount >= 0),
    sort_order                  int NOT NULL DEFAULT 0,
    CHECK (cumulative_progress_amount <= scheduled_value)
);

CREATE INDEX idx_subcontract_claim_items_claim ON subcontract_progress_claim_items (progress_claim_id);
CREATE INDEX idx_subcontract_claim_items_sov ON subcontract_progress_claim_items (subcontract_item_id);

CREATE FUNCTION subcontract_progress_claim_items_check_consistency() RETURNS trigger AS $$
DECLARE
    claim_project      uuid;
    claim_subcontract   uuid;
    item_subcontract    uuid;
BEGIN
    SELECT project_id, subcontract_id INTO claim_project, claim_subcontract
    FROM subcontract_progress_claims WHERE id = NEW.progress_claim_id;
    IF claim_project IS NULL OR claim_project <> NEW.project_id THEN
        RAISE EXCEPTION 'Hakediş kalemi, hakedişin KENDİ projesine ait olmalı';
    END IF;
    SELECT subcontract_id INTO item_subcontract FROM subcontract_items WHERE id = NEW.subcontract_item_id;
    IF item_subcontract IS NULL OR item_subcontract <> claim_subcontract THEN
        RAISE EXCEPTION 'Hakediş kalemi, hakedişle AYNI taşeron sözleşmesinin bir SOV kalemine ait olmalı';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_subcontract_claim_items_check_consistency
    BEFORE INSERT OR UPDATE ON subcontract_progress_claim_items
    FOR EACH ROW EXECUTE FUNCTION subcontract_progress_claim_items_check_consistency();

-- ---------------------------------------------------------------------------
-- 9. project_commitments'e HİÇBİR YENİ KOLON EKLENMEZ -- source_type
-- ('subcontract') ve source_id ZATEN Sprint 2'den beri şemada VARDI (bkz.
-- migration 0035 dosya-başı yorumu, migration 0037'nin PO entegrasyonuyla
-- AYNI ilke). Sprint 5, bu değeri GERÇEKTEN YAZAN İLK kod yoludur.
--
-- Granülerlik kararı (PO'dan BİLİNÇLİ SAPMA): PO'nun aksine (source_id =
-- purchase_order_items.id, İTEM seviyesinde, KALICI/tek seferlik), bir
-- Subcontract'ın taahhüdü YAŞAM BOYU DEĞİŞEBİLİR (değişiklik emirleri,
-- fesih) -- bu yüzden source_id = project_subcontracts.id (SÖZLEŞME
-- seviyesinde) kullanılır ve her ticari olayda (aktivasyon/değişiklik
-- onayı/fesih) BÜTÜN aktif commitment'lar VOIDLANIP maliyet-kodu bazında
-- NETLENMİŞ yeni satırlarla YENİDEN OLUŞTURULUR (bkz. syncSubcontractCommitments,
-- docs/subcontracts.md §Commitment Entegrasyonu). Bu, PO'nun "immutable
-- tek seferlik onay" modelinden farklı olarak "periyodik tam senkronizasyon"
-- modelidir -- negatif/kısmi commitment mutasyonu İCAT EDİLMEDİ, yalnızca
-- var olan void+create deseni tekrar kullanılır.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 10. İzin kayıt defteri genişletmesi -- Contract/Procurement İLE AYNI
-- <domain>.<subresource>.<action> deseni. İKİ AYRI üçlü (subcontracts.*,
-- subcontract_claims.*) -- spec §28'in kendi önerisi, hakediş sertifikasyonu
-- sözleşme onayından farklı bir karar anı olabileceği için ayrı izinlerle
-- modellendi.
-- ---------------------------------------------------------------------------
INSERT INTO permissions (code, description, category) VALUES
    ('projects.subcontracts.read',        'Taşeron sözleşmelerini/SOV/değişikliklerini görüntüleme', 'Finans'),
    ('projects.subcontracts.manage',      'Taşeron sözleşmesi/SOV/değişiklik TASLAĞI oluşturma/düzenleme', 'Finans'),
    ('projects.subcontracts.approve',     'Taşeron sözleşmesi aktivasyonu/feshi/iptali, değişiklik onayı', 'Finans'),
    ('projects.subcontract_claims.read',  'Taşeron hakedişlerini görüntüleme', 'Finans'),
    ('projects.subcontract_claims.manage', 'Hakediş TASLAĞI oluşturma/düzenleme/gönderme', 'Finans'),
    ('projects.subcontract_claims.certify', 'Hakediş sertifikasyonu/reddi', 'Finans');

-- ---------------------------------------------------------------------------
-- 11. seed_system_roles_for_org GÜNCELLENİR (CREATE OR REPLACE) -- owner/
-- admin bloğu DEĞİŞMEDİ. Rol matrisi (spec §28'in önerisiyle BİREBİR
-- tutarlı, Contract/Procurement İLE AYNI ilke):
--
--   finance: subcontracts + subcontract_claims TAM (read+manage+approve/
--     certify) -- "doğal sahip", Contract'taki finance.lifecycle İLE AYNI
--     gerekçe.
--   legacy_user / project_manager: read+manage VERİLİR (taslak
--     oluşturabilir/düzenleyebilir) ama approve/certify KESİNLİKLE
--     VERİLMEZ -- Contract'taki "lifecycle asla otomatik miras alınmaz"
--     kararıyla BİREBİR AYNI ilke, bu YENİ bir eylem sınıfıdır.
--   field: HİÇBİRİ -- mevcut "sahada finansal/ticari görünürlük YOK"
--     ilkesiyle tutarlı (Contract/Budget/Cost Control/Procurement'ın
--     field'ı hiçbir izin ALMADIĞI dört sprintlik emsalle AYNI).
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

    -- legacy_user
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
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage'
    );

    -- project_manager
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
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage'
    );

    -- finance
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
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage', 'projects.subcontract_claims.certify'
    );

    -- field: yeni izin YOK (satın alma/taşeron İZNİ YOK).
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
-- 12. MEVCUT organizasyonların ZATEN seed edilmiş rollerine yeni izinleri
-- BACKFILL et (migration 0035/0036/0037 İLE AYNI gerekçe).
-- ---------------------------------------------------------------------------
INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code IN ('owner', 'admin')
  AND p.code IN (
      'projects.subcontracts.read', 'projects.subcontracts.manage', 'projects.subcontracts.approve',
      'projects.subcontract_claims.read', 'projects.subcontract_claims.manage', 'projects.subcontract_claims.certify'
  )
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code = 'legacy_user'
  AND p.code IN (
      'projects.subcontracts.read', 'projects.subcontracts.manage',
      'projects.subcontract_claims.read', 'projects.subcontract_claims.manage'
  )
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code = 'project_manager'
  AND p.code IN (
      'projects.subcontracts.read', 'projects.subcontracts.manage',
      'projects.subcontract_claims.read', 'projects.subcontract_claims.manage'
  )
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code = 'finance'
  AND p.code IN (
      'projects.subcontracts.read', 'projects.subcontracts.manage', 'projects.subcontracts.approve',
      'projects.subcontract_claims.read', 'projects.subcontract_claims.manage', 'projects.subcontract_claims.certify'
  )
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

-- field: yeni izin YOK, kasıtlı olarak hiçbir INSERT yapılmaz.
