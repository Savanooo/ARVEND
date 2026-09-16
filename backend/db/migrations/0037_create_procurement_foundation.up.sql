-- ARVEND V2 -- Sprint 4: Procurement Foundation. Suppliers + Purchase
-- Request + RFQ + Supplier Quotations + Bid Comparison + Purchase Order +
-- Cost Control integration.
--
-- Denetim bulgusu (Sprint 4 ön-araştırması): customers ve project_
-- subcontractors birbirinden BAĞIMSIZ, düz (flat) tablolardır -- ortak bir
-- Person/Company/Contact soyutlaması YOKTUR (repo geneli grep ile
-- doğrulandı). Bu migration bu deseni İHLAL ETMEZ: suppliers, customers'ın
-- AYNI düzeyde (organizasyon-seviyeli, tekil, flat) yeni ve BAĞIMSIZ bir
-- tablosudur -- ortak bir soyutlama İCAT EDİLMEZ.
--
-- Denetim bulgusu (KRİTİK, docs/cost-control.md'yi DÜZELTİR): o dokümanın
-- §5/§9'u Committed Cost'un project_commitments İLE project_subcontractors
-- (iptal edilmemiş) toplamının BİRLEŞİMİ olduğunu iddia eder -- ama gerçek
-- SQL'de (ListCostControlLines/GetProjectCostControlSummary) subcontractor
-- toplamı YOKTUR, yalnızca project_commitments WHERE status='active'
-- kullanılır. Bu migration/Sprint bu GERÇEK davranışın üzerine inşa eder;
-- doküman ayrıca düzeltilecektir (bkz. docs/procurement.md).
--
-- Denetim bulgusu: project_commitments.source_type ZATEN 'purchase_order'
-- değerini CHECK constraint'inde taşıyordu (Sprint 2'den, ileriye dönük
-- bırakılmış) ama HİÇBİR kod yolu bunu hiç YAZMADI (her zaman 'manual'
-- sabitlendi, source_id her zaman NULL). Bu migration o alanı YENİDEN
-- oluşturmaz -- yalnızca yeni bir yazma yolu (approved PO -> commitment)
-- ekler, mevcut CommitmentInput/CreateCommitment (manuel taahhüt) akışına
-- HİÇBİR DOKUNMADAN.
--
-- Denetim bulgusu: para/KDV hesaplamasında codebase'de İKİ farklı
-- konvansiyon var -- project_change_order_items.line_total SQL'de
-- (round(quantity*unit_price,2)) hesaplanırken, project_budget_lines.
-- original_amount Go'da (float64 çarpım) hesaplanıyor; docs/cost-
-- control.md'nin "Go'da float çarpım YOK" iddiası yalnızca BİRİNCİSİ için
-- doğru. Bu migration/sprint DAHA KATI olan SQL-taraflı deseni seçer --
-- purchase_request_items.estimated_total, rfq karşılaştırmasına giren
-- quotation_items.line_total ve purchase_order_items.line_total HEPSİ
-- SQL'de hesaplanır (bkz. ilgili INSERT/UPDATE sorguları).
--
-- KAPSAM DIŞI (bilinçli, docs/procurement.md'de gerekçelendirilir):
-- Goods Receipt/kısmi teslimat (Sprint 4B'ye bırakıldı -- bu migration
-- şemayı ona hazırlamaz, ayrı bir migration olacaktır), tedarikçi
-- portal/e-imza, tam VKN/TCKN doğrulaması (repo genelinde hiçbir yerde
-- böyle bir doğrulama YOK -- customers.tax_number İLE AYNI emsal:
-- biçimlendirilmemiş, doğrulanmamış, UNIQUE olmayan bir varchar), FX/kur
-- dönüşümü (mevcut "no FX engine" ilkesiyle AYNI, cross-currency
-- REDDEDİLİR), tedarikçi reyting/sigorta/ön-yeterlilik.

-- ---------------------------------------------------------------------------
-- 1. suppliers: organizasyon-seviyeli, projeler arası PAYLAŞILAN tedarikçi
-- kataloğu -- organization_cost_codes İLE AYNI kardinalite (org-scoped,
-- proje-BAĞIMSIZ). "code" kullanıcı tarafından girilir (cost_codes.code
-- İLE AYNI emsal -- otomatik numaralama YOK, kısa insan-okunur bir
-- kimlik). is_active boolean (customers.is_active/organization_cost_
-- codes.is_active İLE AYNI emsal -- "draft/active" gibi bir durum
-- makinesi DEĞİL, basit bir arşiv anahtarı; HARD DELETE YOK).
-- ---------------------------------------------------------------------------
CREATE TABLE suppliers (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    code             varchar(30) NOT NULL,
    legal_name       varchar(200) NOT NULL,
    trade_name       varchar(200) NOT NULL DEFAULT '',
    -- tax_number: customers.tax_number İLE BİREBİR AYNI emsal -- biçim
    -- doğrulaması/UNIQUE kısıtı YOK (repo genelinde hiçbir yerde VKN/TCKN
    -- doğrulaması bulunmadı, burada da İCAT EDİLMEDİ).
    tax_number       varchar(30) NOT NULL DEFAULT '',
    tax_office       varchar(100) NOT NULL DEFAULT '',
    contact_name     varchar(150) NOT NULL DEFAULT '',
    email            varchar(200) NOT NULL DEFAULT '',
    phone            varchar(30) NOT NULL DEFAULT '',
    address          text NOT NULL DEFAULT '',
    city             varchar(100) NOT NULL DEFAULT '',
    country          varchar(100) NOT NULL DEFAULT 'Türkiye',
    -- organization_commercial_settings.iban_enc İLE BİREBİR AYNI mekanizma
    -- (internal/platform/crypto.SecretBox, AES-256-GCM, base64) -- yeni bir
    -- şifreleme deseni İCAT EDİLMEDİ. Plaintext ASLA HTTP yanıtına yazılmaz
    -- (API yalnızca "iban_set" boolean döner).
    iban_enc         text NOT NULL DEFAULT '',
    is_active        boolean NOT NULL DEFAULT true,
    notes            text NOT NULL DEFAULT '',
    created_by       uuid REFERENCES users(id),
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (organization_id, code)
);

CREATE INDEX idx_suppliers_org ON suppliers (organization_id);
CREATE INDEX idx_suppliers_org_active ON suppliers (organization_id, is_active);

CREATE TRIGGER suppliers_set_updated_at BEFORE UPDATE ON suppliers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 2. Sayaçlar -- offer_counters/project_counters İLE BİREBİR AYNI desen
-- (organizasyon+yıl kapsamlı, tek atomik "INSERT ... ON CONFLICT DO UPDATE
-- ... RETURNING seq" UPSERT'i -- SELECT MAX+1 YARIŞI YOK, gerçek bir
-- Postgres SEQUENCE nesnesi de GEREKMİYOR, bkz. denetim). PR/RFQ/PO
-- organizasyon çapında ardışık numaralandırılan mali belgelerdir --
-- change_order_counters'ın (proje-başına, EK-NNN) AKSİNE offers/projects
-- İLE AYNI kapsam seçildi: bir Finans kullanıcısı "PO-2026-0001,
-- PO-2026-0002..." şeklinde TÜM organizasyon genelinde ardışık numara
-- bekler, tek bir projenin revizyon numarası DEĞİL.
-- ---------------------------------------------------------------------------
CREATE TABLE purchase_request_counters (
    organization_id uuid NOT NULL REFERENCES organizations(id),
    year            int NOT NULL,
    seq             int NOT NULL DEFAULT 0,
    PRIMARY KEY (organization_id, year)
);

CREATE TABLE rfq_counters (
    organization_id uuid NOT NULL REFERENCES organizations(id),
    year            int NOT NULL,
    seq             int NOT NULL DEFAULT 0,
    PRIMARY KEY (organization_id, year)
);

CREATE TABLE purchase_order_counters (
    organization_id uuid NOT NULL REFERENCES organizations(id),
    year            int NOT NULL,
    seq             int NOT NULL DEFAULT 0,
    PRIMARY KEY (organization_id, year)
);

-- ---------------------------------------------------------------------------
-- 3. purchase_requests: proje-seviyeli satın alma talebi. Durum makinesi
-- (kullanıcı spec'inin "edit lock VEYA kontrollü geri çekme" seçeneğinden
-- İKİNCİSİ tercih edildi -- daha esnek, yanlışlıkla submit edilen bir
-- talebin onaya gitmeden düzeltilebilmesini sağlar):
--
--   draft -> submitted            (Submit)
--   submitted -> draft            (Withdraw -- kontrollü geri çekme)
--   submitted -> approved         (Approve -- RFQ/PO kaynağı olabilir)
--   submitted -> rejected         (Reject, gerekçe zorunlu, TERMİNAL --
--                                  kullanıcı resubmit yerine YENİ bir PR
--                                  açar, ayrı bir "resubmit" durumu İCAT
--                                  EDİLMEDİ, spec'in kendi izin verdiği
--                                  iki seçenekten biri)
--   {draft,submitted,approved} -> cancelled  (Cancel, gerekçe zorunlu, TERMİNAL)
--
-- approved KENDİSİ terminal DEĞİLDİR (RFQ oluşturmak için referans
-- alınmaya devam eder) ama PR'ın KENDİ alanları approved sonrası
-- düzenlenemez (bkz. servis katmanı) -- Contract'ın "aktivasyon sonrası
-- kilit" ilkesiyle AYNI mantık, farklı bir durum makinesi üzerinde.
-- ---------------------------------------------------------------------------
CREATE TABLE purchase_requests (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    project_id       uuid NOT NULL REFERENCES projects(id),
    pr_no            varchar(30) NOT NULL,

    title            varchar(200) NOT NULL,
    description      text NOT NULL DEFAULT '',
    needed_by        date,

    status           varchar(20) NOT NULL DEFAULT 'draft'
                      CHECK (status IN ('draft', 'submitted', 'approved', 'rejected', 'cancelled')),

    -- Kalemlerden SQL'de hesaplanır (project_change_orders.subtotal İLE
    -- AYNI ilke) -- istemciden gelen bir toplama ASLA güvenilmez.
    estimated_total  numeric(18, 2) NOT NULL DEFAULT 0 CHECK (estimated_total >= 0),

    requested_by     uuid REFERENCES users(id),
    submitted_at     timestamptz,
    approved_at      timestamptz,
    approved_by      uuid REFERENCES users(id),
    rejected_at      timestamptz,
    rejected_by      uuid REFERENCES users(id),
    rejection_reason varchar(500) NOT NULL DEFAULT '',
    cancelled_at     timestamptz,
    cancelled_by     uuid REFERENCES users(id),
    cancel_reason    varchar(500) NOT NULL DEFAULT '',

    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),

    UNIQUE (organization_id, pr_no)
);

CREATE INDEX idx_purchase_requests_org ON purchase_requests (organization_id);
CREATE INDEX idx_purchase_requests_project ON purchase_requests (project_id);
CREATE INDEX idx_purchase_requests_status ON purchase_requests (project_id, status);

CREATE TRIGGER purchase_requests_set_updated_at BEFORE UPDATE ON purchase_requests
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE purchase_request_items (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id      uuid NOT NULL REFERENCES organizations(id),
    project_id           uuid NOT NULL REFERENCES projects(id),
    purchase_request_id  uuid NOT NULL REFERENCES purchase_requests(id) ON DELETE CASCADE,

    -- ÜÇÜ de OPSİYONEL -- bir talep kalemi henüz hiçbir maliyet
    -- kodu/bütçe kalemine eşlenmemiş olabilir (spec: "hard budget
    -- blocking bu sprintte zorunlu değil").
    wbs_node_id          uuid REFERENCES project_wbs_nodes(id),
    cost_code_id         uuid REFERENCES organization_cost_codes(id),
    budget_line_id       uuid REFERENCES project_budget_lines(id),

    description          varchar(300) NOT NULL,
    quantity              numeric(12, 2) NOT NULL CHECK (quantity > 0),
    unit                 varchar(30) NOT NULL DEFAULT '',
    estimated_unit_cost  numeric(18, 2),
    -- quantity*estimated_unit_cost'tan SQL'de hesaplanır (ikisi de
    -- doluysa); yalnızca biri/hiçbiri doluysa istemcinin gönderdiği değer
    -- kullanılır (project_budget_lines.original_amount İLE AYNI "kısmi
    -- doluluk" kuralı, bkz. docs/cost-control.md §6 -- ama BURADA Go'da
    -- DEĞİL, SQL'de hesaplanır, bkz. yukarıdaki dosya-başı yorumu).
    estimated_total      numeric(18, 2) NOT NULL DEFAULT 0 CHECK (estimated_total >= 0),
    notes                varchar(500) NOT NULL DEFAULT '',
    sort_order           int NOT NULL DEFAULT 0
);

CREATE INDEX idx_pr_items_request ON purchase_request_items (purchase_request_id);

-- Savunma derinliği: project_budget_lines_check_consistency İLE AYNI
-- desen -- wbs_node_id/budget_line_id (varsa) AYNI projeye, cost_code_id
-- (varsa) AYNI organizasyona ait olmalı. ÜÇÜ de opsiyonel olduğu için
-- HEPSİ IF NEW.x IS NOT NULL ile korunur (project_budget_lines'ın AKSİNE,
-- orada cost_code_id zorunluydu).
CREATE FUNCTION purchase_request_items_check_consistency() RETURNS trigger AS $$
DECLARE
    wbs_project   uuid;
    line_project  uuid;
    code_org      uuid;
BEGIN
    IF NEW.wbs_node_id IS NOT NULL THEN
        SELECT project_id INTO wbs_project FROM project_wbs_nodes WHERE id = NEW.wbs_node_id;
        IF wbs_project IS NULL OR wbs_project <> NEW.project_id THEN
            RAISE EXCEPTION 'talep kaleminin WBS düğümü AYNI projeye ait olmalı';
        END IF;
    END IF;
    IF NEW.budget_line_id IS NOT NULL THEN
        SELECT project_id INTO line_project FROM project_budget_lines WHERE id = NEW.budget_line_id;
        IF line_project IS NULL OR line_project <> NEW.project_id THEN
            RAISE EXCEPTION 'talep kaleminin bütçe kalemi AYNI projeye ait olmalı';
        END IF;
    END IF;
    IF NEW.cost_code_id IS NOT NULL THEN
        SELECT organization_id INTO code_org FROM organization_cost_codes WHERE id = NEW.cost_code_id;
        IF code_org IS NULL OR code_org <> NEW.organization_id THEN
            RAISE EXCEPTION 'talep kaleminin cost code''u AYNI organizasyona ait olmalı';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_purchase_request_items_check_consistency
    BEFORE INSERT OR UPDATE ON purchase_request_items
    FOR EACH ROW EXECUTE FUNCTION purchase_request_items_check_consistency();

-- ---------------------------------------------------------------------------
-- 4. rfqs: onaylı bir Purchase Request'ten (opsiyonel referans --
-- purchase_request_id NULL olabilir, "PR olmadan doğrudan RFQ" da
-- desteklenir, spec bunu yasaklamıyor) oluşturulan teklif talebi.
-- awarded_* kolonları supplier_quotations tablosu VAR OLDUKTAN SONRA (§7)
-- ALTER TABLE ile eklenir (ileri-referans sorununu önlemek için).
--
--   draft -> issued     (Issue -- kalemler bu noktada SNAPSHOT olarak
--                        kilitlenir, bkz. rfq_items; PR sonradan değişse
--                        bile issued RFQ silent mutate OLMAZ)
--   issued -> closed    (Close -- kazanan SEÇİLMEDEN kapatma, ör. hiç
--                        yanıt gelmedi) VEYA Award (bkz. §8, kazanan
--                        SEÇİLEREK kapatma -- ikisi de "closed" durumuna
--                        gider, farkı awarded_quotation_id'nin dolu olup
--                        olmamasıdır)
--   {draft,issued} -> cancelled  (Cancel, TERMİNAL)
-- ---------------------------------------------------------------------------
CREATE TABLE rfqs (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id      uuid NOT NULL REFERENCES organizations(id),
    project_id           uuid NOT NULL REFERENCES projects(id),
    rfq_no               varchar(30) NOT NULL,
    purchase_request_id  uuid REFERENCES purchase_requests(id),

    title                varchar(200) NOT NULL,
    issue_date           date NOT NULL,
    due_date             date,

    status               varchar(20) NOT NULL DEFAULT 'draft'
                          CHECK (status IN ('draft', 'issued', 'closed', 'cancelled')),

    notes                text NOT NULL DEFAULT '',

    created_by           uuid REFERENCES users(id),
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),

    UNIQUE (organization_id, rfq_no)
);

CREATE INDEX idx_rfqs_org ON rfqs (organization_id);
CREATE INDEX idx_rfqs_project ON rfqs (project_id);
CREATE INDEX idx_rfqs_status ON rfqs (project_id, status);
CREATE INDEX idx_rfqs_purchase_request ON rfqs (purchase_request_id) WHERE purchase_request_id IS NOT NULL;

CREATE TRIGGER rfqs_set_updated_at BEFORE UPDATE ON rfqs
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Bir RFQ'nun davet ettiği tedarikçiler. response_status='responded'
-- servis katmanında bir teklif (supplier_quotations) oluşturulduğunda
-- otomatik set edilir (bkz. project_procurement_service.go) -- 'declined'
-- bu sprintte manuel bir uç TAŞIMAZ (şema ileriye dönük bırakıldı, spec
-- kapsamında bir "reddet" eylemi tanımlanmadı).
CREATE TABLE rfq_suppliers (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    rfq_id           uuid NOT NULL REFERENCES rfqs(id) ON DELETE CASCADE,
    supplier_id      uuid NOT NULL REFERENCES suppliers(id),
    invited_at       timestamptz NOT NULL DEFAULT now(),
    response_status  varchar(20) NOT NULL DEFAULT 'pending'
                     CHECK (response_status IN ('pending', 'responded', 'declined')),
    UNIQUE (rfq_id, supplier_id)
);

CREATE INDEX idx_rfq_suppliers_rfq ON rfq_suppliers (rfq_id);
CREATE INDEX idx_rfq_suppliers_supplier ON rfq_suppliers (supplier_id);

-- Savunma derinliği: davet edilen tedarikçi AYNI organizasyona ait olmalı
-- (cross-tenant supplier davet edilmesi İMKANSIZ olmalı, bkz. spec §24).
CREATE FUNCTION rfq_suppliers_check_consistency() RETURNS trigger AS $$
DECLARE
    supplier_org uuid;
BEGIN
    SELECT organization_id INTO supplier_org FROM suppliers WHERE id = NEW.supplier_id;
    IF supplier_org IS NULL OR supplier_org <> NEW.organization_id THEN
        RAISE EXCEPTION 'davet edilen tedarikçi AYNI organizasyona ait olmalı';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_rfq_suppliers_check_consistency
    BEFORE INSERT OR UPDATE ON rfq_suppliers
    FOR EACH ROW EXECUTE FUNCTION rfq_suppliers_check_consistency();

-- rfq_items: RFQ oluşturulduğu anda kaynak PR kaleminden (varsa) KOPYALANIR
-- (snapshot) -- source_pr_item_id yalnızca İZLENEBİLİRLİK içindir, CANLI
-- bir JOIN DEĞİLDİR (PR sonradan değişirse/silinirse bu satır ETKİLENMEZ,
-- ON DELETE SET NULL bilerek RESTRICT değil).
CREATE TABLE rfq_items (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id    uuid NOT NULL REFERENCES organizations(id),
    project_id         uuid NOT NULL REFERENCES projects(id),
    rfq_id             uuid NOT NULL REFERENCES rfqs(id) ON DELETE CASCADE,
    source_pr_item_id  uuid REFERENCES purchase_request_items(id) ON DELETE SET NULL,

    wbs_node_id        uuid REFERENCES project_wbs_nodes(id),
    cost_code_id       uuid REFERENCES organization_cost_codes(id),
    budget_line_id     uuid REFERENCES project_budget_lines(id),

    description        varchar(300) NOT NULL,
    quantity           numeric(12, 2) NOT NULL CHECK (quantity > 0),
    unit               varchar(30) NOT NULL DEFAULT '',
    sort_order         int NOT NULL DEFAULT 0
);

CREATE INDEX idx_rfq_items_rfq ON rfq_items (rfq_id);

CREATE FUNCTION rfq_items_check_consistency() RETURNS trigger AS $$
DECLARE
    wbs_project   uuid;
    line_project  uuid;
    code_org      uuid;
BEGIN
    IF NEW.wbs_node_id IS NOT NULL THEN
        SELECT project_id INTO wbs_project FROM project_wbs_nodes WHERE id = NEW.wbs_node_id;
        IF wbs_project IS NULL OR wbs_project <> NEW.project_id THEN
            RAISE EXCEPTION 'RFQ kaleminin WBS düğümü AYNI projeye ait olmalı';
        END IF;
    END IF;
    IF NEW.budget_line_id IS NOT NULL THEN
        SELECT project_id INTO line_project FROM project_budget_lines WHERE id = NEW.budget_line_id;
        IF line_project IS NULL OR line_project <> NEW.project_id THEN
            RAISE EXCEPTION 'RFQ kaleminin bütçe kalemi AYNI projeye ait olmalı';
        END IF;
    END IF;
    IF NEW.cost_code_id IS NOT NULL THEN
        SELECT organization_id INTO code_org FROM organization_cost_codes WHERE id = NEW.cost_code_id;
        IF code_org IS NULL OR code_org <> NEW.organization_id THEN
            RAISE EXCEPTION 'RFQ kaleminin cost code''u AYNI organizasyona ait olmalı';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_rfq_items_check_consistency
    BEFORE INSERT OR UPDATE ON rfq_items
    FOR EACH ROW EXECUTE FUNCTION rfq_items_check_consistency();

-- ---------------------------------------------------------------------------
-- 5. supplier_quotations: bir tedarikçinin BİR RFQ'ya verdiği teklif,
-- manuel girilir (tedarikçi portalı/login YOK, bu sprint). "status" alanı
-- KASITLI OLARAK YOK -- "kazanan" bilgisi TEK doğruluk kaynağı olarak
-- yalnızca rfqs.awarded_quotation_id'de tutulur (bkz. §8); burada AYRICA
-- bir status kolonu tutmak, iki kaynağın senkron dışı kalma riskini
-- (current_contract_value'nun hiç saklanmaması İLE AYNI ilke) taşırdı.
-- ---------------------------------------------------------------------------
CREATE TABLE supplier_quotations (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id   uuid NOT NULL REFERENCES organizations(id),
    project_id        uuid NOT NULL REFERENCES projects(id),
    rfq_id            uuid NOT NULL REFERENCES rfqs(id),
    supplier_id       uuid NOT NULL REFERENCES suppliers(id),

    quotation_number  varchar(50) NOT NULL DEFAULT '',
    quotation_date    date NOT NULL,
    valid_until       date,
    -- Proje para birimiyle AYNI olmak ZORUNDADIR (mevcut validateMoney/
    -- ErrCurrencyMismatch ilkesi -- FX dönüşümü YOK, farklı para birimi
    -- REDDEDİLİR, bkz. servis katmanı).
    currency          varchar(3) NOT NULL,

    -- Kalemlerden SQL'de hesaplanır (project_change_orders.subtotal İLE
    -- AYNI ilke) -- istemciden gelen toplamlara güvenilmez.
    subtotal          numeric(18, 2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    discount          numeric(18, 2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
    tax_rate          numeric(5, 2) NOT NULL DEFAULT 20 CHECK (tax_rate >= 0),
    tax               numeric(18, 2) NOT NULL DEFAULT 0 CHECK (tax >= 0),
    total             numeric(18, 2) NOT NULL DEFAULT 0 CHECK (total >= 0),

    delivery_days     int,
    payment_terms     varchar(300) NOT NULL DEFAULT '',
    notes             text NOT NULL DEFAULT '',

    created_by        uuid REFERENCES users(id),
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),

    -- Bir tedarikçi bir RFQ'ya yalnızca TEK bir teklif girebilir (basit
    -- model -- rekabetçi çoklu-revizyon teklif bu sprintin kapsamı DIŞI).
    UNIQUE (rfq_id, supplier_id)
);

CREATE INDEX idx_quotations_org ON supplier_quotations (organization_id);
CREATE INDEX idx_quotations_project ON supplier_quotations (project_id);
CREATE INDEX idx_quotations_rfq ON supplier_quotations (rfq_id);
CREATE INDEX idx_quotations_supplier ON supplier_quotations (supplier_id);

CREATE TRIGGER supplier_quotations_set_updated_at BEFORE UPDATE ON supplier_quotations
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Savunma derinliği: tedarikçi VE RFQ AYNI organizasyona, RFQ AYNI
-- projeye ait olmalı (project_id, RFQ'dan snapshot alınır -- bkz. servis
-- katmanı, ama trigger burada da bağımsız bir savunma katmanıdır).
CREATE FUNCTION supplier_quotations_check_consistency() RETURNS trigger AS $$
DECLARE
    rfq_org     uuid;
    rfq_project uuid;
    supplier_org uuid;
BEGIN
    SELECT organization_id, project_id INTO rfq_org, rfq_project FROM rfqs WHERE id = NEW.rfq_id;
    IF rfq_org IS NULL OR rfq_org <> NEW.organization_id OR rfq_project <> NEW.project_id THEN
        RAISE EXCEPTION 'teklifin RFQ''su AYNI organizasyon/projeye ait olmalı';
    END IF;
    SELECT organization_id INTO supplier_org FROM suppliers WHERE id = NEW.supplier_id;
    IF supplier_org IS NULL OR supplier_org <> NEW.organization_id THEN
        RAISE EXCEPTION 'teklifin tedarikçisi AYNI organizasyona ait olmalı';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_supplier_quotations_check_consistency
    BEFORE INSERT OR UPDATE ON supplier_quotations
    FOR EACH ROW EXECUTE FUNCTION supplier_quotations_check_consistency();

CREATE TABLE quotation_items (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id),
    quotation_id    uuid NOT NULL REFERENCES supplier_quotations(id) ON DELETE CASCADE,
    rfq_item_id     uuid NOT NULL REFERENCES rfq_items(id),

    quantity        numeric(12, 2) NOT NULL CHECK (quantity > 0),
    unit_price      numeric(18, 2) NOT NULL CHECK (unit_price > 0),
    -- quantity*unit_price'tan SQL'DE hesaplanır (project_change_order_
    -- items.line_total İLE AYNI desen, Go float aritmetiği DEĞİL).
    line_total      numeric(18, 2) NOT NULL CHECK (line_total > 0),
    notes           varchar(500) NOT NULL DEFAULT '',

    -- Bir teklif, AYNI RFQ kalemine iki satırla teklif VEREMEZ.
    UNIQUE (quotation_id, rfq_item_id)
);

CREATE INDEX idx_quotation_items_quotation ON quotation_items (quotation_id);

-- Savunma derinliği: rfq_item_id, teklifin KENDİ rfq_id'sine ait olmalı
-- (başka bir RFQ'nun kalemine "karşılaştırma sızıntısı" İMKANSIZ olmalı).
CREATE FUNCTION quotation_items_check_consistency() RETURNS trigger AS $$
DECLARE
    quotation_rfq uuid;
    item_rfq      uuid;
BEGIN
    SELECT rfq_id INTO quotation_rfq FROM supplier_quotations WHERE id = NEW.quotation_id;
    SELECT rfq_id INTO item_rfq FROM rfq_items WHERE id = NEW.rfq_item_id;
    IF quotation_rfq IS NULL OR item_rfq IS NULL OR quotation_rfq <> item_rfq THEN
        RAISE EXCEPTION 'teklif kalemi, teklifin KENDİ RFQ''suna ait bir RFQ kalemini referans etmeli';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_quotation_items_check_consistency
    BEFORE INSERT OR UPDATE ON quotation_items
    FOR EACH ROW EXECUTE FUNCTION quotation_items_check_consistency();

-- ---------------------------------------------------------------------------
-- 6. Award alanları -- rfqs tablosuna, supplier_quotations VAR OLDUKTAN
-- SONRA eklenir (ileri-referans sorununu önlemek için §4'te ayrı
-- tutuldu). Award TEK BAŞINA actual cost OLUŞTURMAZ (bkz. spec §11) --
-- yalnızca "hangi teklif kazandı" kararını KALICI ve DENETİMLİ hale
-- getirir (bkz. servis katmanındaki logProjectEvent çağrısı). RFQ'nun
-- status'u Award ile 'closed' olur (bkz. §4 durum makinesi notu).
-- ---------------------------------------------------------------------------
ALTER TABLE rfqs ADD COLUMN awarded_quotation_id uuid REFERENCES supplier_quotations(id);
ALTER TABLE rfqs ADD COLUMN awarded_at            timestamptz;
ALTER TABLE rfqs ADD COLUMN awarded_by            uuid REFERENCES users(id);
ALTER TABLE rfqs ADD COLUMN award_notes           text NOT NULL DEFAULT '';

-- ---------------------------------------------------------------------------
-- 7. purchase_orders. Durum makinesi:
--
--   draft -> approved      (Approve -- ticari tabanı KİLİTLER, bkz. PO
--                           item'larından Cost Control'e commitment
--                           OLUŞTURUR, bu sprintin EN KRİTİK entegrasyon
--                           noktası, bkz. §9)
--   {draft,approved} -> cancelled  (Cancel, gerekçe zorunlu, TERMİNAL --
--                           draft'tan cancel commitment'a DOKUNMAZ (henüz
--                           yok); approved'tan cancel BAĞLI commitment'ları
--                           VOID eder, bkz. §9)
--   approved -> closed     (Close, TERMİNAL -- yalnızca "bu PO'da artık
--                           değişiklik yapılmayacak" bir arşiv işaretidir.
--                           KRİTİK KARAR: Close, commitment'ı VOID ETMEZ --
--                           taahhüt gerçek bir Actual (masraf/fatura,
--                           bu sprintin kapsamı DIŞI) kaydıyla
--                           değiştirilene ya da PO doğrudan iptal edilene
--                           kadar "committed" kalmaya DEVAM eder; aksi
--                           halde Cost Control'ün "Committed" rakamı,
--                           gerçekte hâlâ ödenecek bir yükümlülük olan bir
--                           tutarı sessizce kaybederdi.)
--
-- draft ASLA closed olamaz (önce approved olmalı -- draft bir taahhüt
-- doğurmadığı için "kapatılacak" bir şey yoktur).
-- ---------------------------------------------------------------------------
CREATE TABLE purchase_orders (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id         uuid NOT NULL REFERENCES organizations(id),
    project_id              uuid NOT NULL REFERENCES projects(id),
    po_no                   varchar(30) NOT NULL,
    supplier_id             uuid NOT NULL REFERENCES suppliers(id),
    source_rfq_id           uuid REFERENCES rfqs(id),
    source_quotation_id     uuid REFERENCES supplier_quotations(id),

    currency                varchar(3) NOT NULL,
    status                  varchar(20) NOT NULL DEFAULT 'draft'
                             CHECK (status IN ('draft', 'approved', 'cancelled', 'closed')),

    issue_date              date NOT NULL,
    expected_delivery_date  date,
    payment_terms           varchar(300) NOT NULL DEFAULT '',
    delivery_address        text NOT NULL DEFAULT '',
    notes                   text NOT NULL DEFAULT '',

    -- Kalemlerden SQL'de hesaplanır -- istemciden gelen toplamlara
    -- güvenilmez (project_change_orders.subtotal İLE AYNI ilke).
    subtotal                numeric(18, 2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    tax_rate                numeric(5, 2) NOT NULL DEFAULT 20 CHECK (tax_rate >= 0),
    tax                     numeric(18, 2) NOT NULL DEFAULT 0 CHECK (tax >= 0),
    total                   numeric(18, 2) NOT NULL DEFAULT 0 CHECK (total >= 0),

    created_by              uuid REFERENCES users(id),
    approved_by             uuid REFERENCES users(id),
    approved_at             timestamptz,
    cancelled_by            uuid REFERENCES users(id),
    cancelled_at            timestamptz,
    cancel_reason           varchar(500) NOT NULL DEFAULT '',
    closed_by               uuid REFERENCES users(id),
    closed_at               timestamptz,

    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),

    UNIQUE (organization_id, po_no)
);

CREATE INDEX idx_purchase_orders_org ON purchase_orders (organization_id);
CREATE INDEX idx_purchase_orders_project ON purchase_orders (project_id);
CREATE INDEX idx_purchase_orders_status ON purchase_orders (project_id, status);
CREATE INDEX idx_purchase_orders_supplier ON purchase_orders (supplier_id);

CREATE TRIGGER purchase_orders_set_updated_at BEFORE UPDATE ON purchase_orders
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Savunma derinliği: tedarikçi AYNI organizasyona ait olmalı (cross-
-- tenant tedarikçiyle PO açılması İMKANSIZ olmalı, bkz. spec §24 "Supplier
-- Org A: Org B project PO -> impossible").
CREATE FUNCTION purchase_orders_check_consistency() RETURNS trigger AS $$
DECLARE
    supplier_org uuid;
BEGIN
    SELECT organization_id INTO supplier_org FROM suppliers WHERE id = NEW.supplier_id;
    IF supplier_org IS NULL OR supplier_org <> NEW.organization_id THEN
        RAISE EXCEPTION 'PO''nun tedarikçisi AYNI organizasyona ait olmalı';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_purchase_orders_check_consistency
    BEFORE INSERT OR UPDATE ON purchase_orders
    FOR EACH ROW EXECUTE FUNCTION purchase_orders_check_consistency();

-- cost_code_id ZORUNLU (project_commitments.cost_code_id İLE AYNI --
-- HER PO kalemi approval'da BİREBİR bir commitment satırına dönüşür,
-- bkz. §9, bu yüzden commitments'ın KENDİ zorunluluğunu miras alır).
-- budget_line_id opsiyonel (NULL = "bütçe dışı" taahhüt, commitments İLE
-- AYNI anlam).
CREATE TABLE purchase_order_items (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid NOT NULL REFERENCES organizations(id),
    project_id          uuid NOT NULL REFERENCES projects(id),
    purchase_order_id   uuid NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE,

    wbs_node_id         uuid REFERENCES project_wbs_nodes(id),
    cost_code_id        uuid NOT NULL REFERENCES organization_cost_codes(id),
    budget_line_id      uuid REFERENCES project_budget_lines(id),

    description         varchar(300) NOT NULL,
    quantity            numeric(12, 2) NOT NULL CHECK (quantity > 0),
    unit                varchar(30) NOT NULL DEFAULT '',
    unit_price          numeric(18, 2) NOT NULL CHECK (unit_price > 0),
    -- quantity*unit_price'tan SQL'DE hesaplanır (project_change_order_
    -- items İLE AYNI desen).
    line_total          numeric(18, 2) NOT NULL CHECK (line_total > 0),
    sort_order           int NOT NULL DEFAULT 0
);

CREATE INDEX idx_po_items_po ON purchase_order_items (purchase_order_id);

-- Savunma derinliği: project_commitments_check_consistency İLE BİREBİR
-- AYNI desen (bu tablo commitment'ın DOĞRUDAN kaynağıdır, bkz. §9) --
-- cost_code_id ZORUNLU olduğu için commitments'taki gibi koşulsuz
-- kontrol edilir; wbs_node_id/budget_line_id opsiyonel oldukları için
-- koşullu.
CREATE FUNCTION purchase_order_items_check_consistency() RETURNS trigger AS $$
DECLARE
    wbs_project   uuid;
    line_project  uuid;
    code_org      uuid;
    po_project    uuid;
BEGIN
    SELECT project_id INTO po_project FROM purchase_orders WHERE id = NEW.purchase_order_id;
    IF po_project IS NULL OR po_project <> NEW.project_id THEN
        RAISE EXCEPTION 'PO kalemi, PO''nun KENDİ projesine ait olmalı';
    END IF;
    IF NEW.wbs_node_id IS NOT NULL THEN
        SELECT project_id INTO wbs_project FROM project_wbs_nodes WHERE id = NEW.wbs_node_id;
        IF wbs_project IS NULL OR wbs_project <> NEW.project_id THEN
            RAISE EXCEPTION 'PO kaleminin WBS düğümü AYNI projeye ait olmalı';
        END IF;
    END IF;
    IF NEW.budget_line_id IS NOT NULL THEN
        SELECT project_id INTO line_project FROM project_budget_lines WHERE id = NEW.budget_line_id;
        IF line_project IS NULL OR line_project <> NEW.project_id THEN
            RAISE EXCEPTION 'PO kaleminin bütçe kalemi AYNI projeye ait olmalı';
        END IF;
    END IF;
    SELECT organization_id INTO code_org FROM organization_cost_codes WHERE id = NEW.cost_code_id;
    IF code_org IS NULL OR code_org <> NEW.organization_id THEN
        RAISE EXCEPTION 'PO kaleminin cost code''u AYNI organizasyona ait olmalı';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_purchase_order_items_check_consistency
    BEFORE INSERT OR UPDATE ON purchase_order_items
    FOR EACH ROW EXECUTE FUNCTION purchase_order_items_check_consistency();

-- ---------------------------------------------------------------------------
-- 8. project_commitments'e HİÇBİR YENİ KOLON EKLENMEZ -- source_type
-- ('purchase_order') ve source_id ZATEN Sprint 2'den beri şemada VARDI
-- (bkz. dosya-başı yorum). Bu migration yalnızca YENİ bir YAZMA yolu
-- (approved PO item -> commitment, source_id = purchase_order_items.id --
-- ITEM seviyesinde, PO seviyesinde DEĞİL, çünkü her PO kalemi FARKLI bir
-- cost_code/budget_line'a bağlı olabilir ve commitments tablosu satır
-- başına TEK bir cost_code/budget_line taşır) ekler; mevcut CreateCommitment
-- (manuel taahhüt, source_type her zaman 'manual') akışına DOKUNULMAZ.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 9. İzin kayıt defteri genişletmesi -- <domain>.<subresource>.<action>
-- deseni (migration 0034/0035/0036 İLE AYNI). Contract'ın (Sprint 3)
-- read/manage/lifecycle üçlüsünden ESİNLENİLDİ ama BURADA "approve"
-- fiili seçildi (spec §17'nin kendi önerisi) -- "lifecycle" TÜM olası
-- üçüncü fiiller için evrensel bir isim DEĞİLDİR (denetimle doğrulandı,
-- her sprint kendi fiilini kendi bölümünde gerekçelendirir).
--
--   organization.suppliers.read     Tedarikçi kataloğunu görüntüleme.
--   organization.suppliers.manage   Tedarikçi oluşturma/düzenleme/arşivleme.
--   projects.procurement.read       PR/RFQ/Teklif/PO görüntüleme.
--   projects.procurement.manage     PR/RFQ/Teklif OLUŞTURMA/düzenleme, PO
--                                   TASLAĞI oluşturma/düzenleme. PR onayı,
--                                   RFQ award'ı, PO onayı/iptali/kapatma
--                                   YAPAMAZ.
--   projects.procurement.approve    PR onay/red, RFQ award, PO onay/iptal/
--                                   kapatma -- HER ZAMAN backend-enforced +
--                                   denetimli (Contract'ın lifecycle
--                                   iznindeki İLKENİN AYNISI).
-- ---------------------------------------------------------------------------
INSERT INTO permissions (code, description, category) VALUES
    ('organization.suppliers.read',   'Tedarikçi kataloğunu görüntüleme',                          'Firma Yönetimi'),
    ('organization.suppliers.manage', 'Tedarikçi oluşturma/düzenleme/arşivleme',                   'Firma Yönetimi'),
    ('projects.procurement.read',     'Satın alma talebi/RFQ/teklif/sipariş görüntüleme',          'Finans'),
    ('projects.procurement.manage',   'Satın alma talebi/RFQ/teklif/sipariş taslağı oluşturma/düzenleme', 'Finans'),
    ('projects.procurement.approve',  'Satın alma talebi onayı, RFQ ödülü, sipariş onayı/iptali/kapatma', 'Finans');

-- ---------------------------------------------------------------------------
-- 10. seed_system_roles_for_org GÜNCELLENİR (CREATE OR REPLACE) -- owner/
-- admin bloğu DEĞİŞMEDİ. Rol matrisi kararları:
--
--   finance: suppliers.read+manage (organization_cost_codes.manage İLE
--     AYNI emsal -- finans kataloğu yönetir) + procurement TAM
--     (read+manage+approve, Contract'taki finance.lifecycle İLE AYNI
--     "doğal sahip" gerekçesi).
--   legacy_user: suppliers.read VERİLİR (mevcut customers.read/products.
--     read salt-okunur katalog erişimi emsaliyle tutarlı) AMA
--     suppliers.manage VERİLMEZ (organization_cost_codes.manage'in
--     legacy_user'a da VERİLMEDİĞİ Sprint 2 kararıyla BİREBİR AYNI
--     gerekçe -- "katalog yönetimi" farklı bir yetki sınıfıdır). procurement
--     read+manage VERİLİR (mevcut finance.read/manage tam paritesiyle
--     tutarlı) AMA approve KESİNLİKLE VERİLMEZ (Contract'taki
--     "lifecycle asla otomatik miras alınmaz" kararıyla BİREBİR AYNI ilke
--     -- approve, bugüne kadar hiç var olmayan YENİ bir eylem sınıfıdır).
--   project_manager: suppliers.read VERİLİR (organization_cost_codes.read
--     İLE AYNI emsal), suppliers.manage VERİLMEZ. procurement read+manage
--     VERİLİR (Contract'taki PM'nin manage alması AMA lifecycle
--     ALAMAMASI kararıyla BİREBİR AYNI desen -- PM ticari belgeyi
--     hazırlayabilir ama onaylayamaz/iptal edemez), approve VERİLMEZ.
--   field: HİÇBİRİ (mevcut "sahada finansal/ticari görünürlük YOK"
--     ilkesiyle tutarlı -- Contract/Budget/Cost Control'ün field'ı hiçbir
--     izin ALMADIĞI üç sprintlik emsalle AYNI. Spec'in önerdiği "field
--     için basit satın alma talebi oluşturma" seçeneği bu sprintte
--     KASITLI OLARAK uygulanmadı -- spec'in kendi izniyle
--     ["Scope büyürse sonraya bırak"] -- bu sprint zaten en büyük
--     kapsamlı sprint, field-özel bir talep-oluşturma UX'i AYRI bir
--     karar/sprint olarak bırakıldı, bkz. docs/procurement.md).
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
        'projects.procurement.read', 'projects.procurement.manage'
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
        'projects.procurement.read', 'projects.procurement.manage'
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
        'projects.procurement.read', 'projects.procurement.manage', 'projects.procurement.approve'
    );

    -- field: yeni izin YOK (satın alma İZNİ YOK).
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
-- BACKFILL et (migration 0035/0036 İLE AYNI gerekçe -- CREATE OR REPLACE
-- FUNCTION yalnızca YENİ organizasyonları etkiler).
-- ---------------------------------------------------------------------------
INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code IN ('owner', 'admin')
  AND p.code IN (
      'organization.suppliers.read', 'organization.suppliers.manage',
      'projects.procurement.read', 'projects.procurement.manage', 'projects.procurement.approve'
  )
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code = 'legacy_user'
  AND p.code IN ('organization.suppliers.read', 'projects.procurement.read', 'projects.procurement.manage')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code = 'project_manager'
  AND p.code IN ('organization.suppliers.read', 'projects.procurement.read', 'projects.procurement.manage')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code = 'finance'
  AND p.code IN (
      'organization.suppliers.read', 'organization.suppliers.manage',
      'projects.procurement.read', 'projects.procurement.manage', 'projects.procurement.approve'
  )
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

-- field: yeni izin YOK, kasıtlı olarak hiçbir INSERT yapılmaz.
