-- Faz 6: proje finans modülleri.
--
-- TEMEL İLKE: projects.contract_amount kabul edilen teklif revizyonunun
-- dondurulmuş anlık görüntüsüdür ve finans hareketleri yüzünden ASLA
-- değişmez. Toplam tahsilat/masraf/taşeron ödemesi gibi değerler de
-- projects üzerinde elle senkronize edilen kolonlar olarak TUTULMAZ --
-- her zaman aşağıdaki hareket tablolarından aggregate edilir. Böylece
-- "özet ile hareketler birbirini tutmuyor" sınıfı hatalar yapısal olarak
-- imkansızdır.
--
-- PARA: tüm tutarlar numeric(12,2); toplama/çıkarma işlemleri de SQL
-- tarafında numeric üzerinde yapılır (Go'da float64 yalnızca taşıma
-- tipidir), böylece kuruş hassasiyeti korunur.
--
-- DÜZELTME: muhasebesel hareketler silinmez. amount > 0 kısıtı negatif
-- "düzeltme kaydı" girilmesini engeller; yanlış kayıt void edilir ve
-- aggregate'lerden düşer, ama iz olarak kalır.

CREATE TABLE project_payment_plan_items (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    sort_order      int NOT NULL DEFAULT 0,
    name            varchar(200) NOT NULL,
    -- percentage doluysa planned_amount onun contract_amount'a
    -- uygulanmasıyla ÜRETİLİR (servis katmanında); ikisi birden serbestçe
    -- girilip birbiriyle çelişemez.
    percentage      numeric(5, 2) CHECK (percentage IS NULL OR percentage > 0),
    planned_amount  numeric(12, 2) NOT NULL CHECK (planned_amount > 0),
    due_date        date,
    -- status YALNIZCA manuel niyeti taşır: 'pending' (normal) ya da
    -- 'cancelled'. partial/paid/overdue DURUMLARI SAKLANMAZ -- tahsilat
    -- toplamı ve due_date'ten okuma anında türetilir (bkz. yukarıdaki
    -- "elle senkronize kolon tutma" ilkesi). CHECK ileriye dönük olarak
    -- beşini de kabul eder.
    status          varchar(20) NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'partial', 'paid', 'overdue', 'cancelled')),
    notes           text NOT NULL DEFAULT '',
    created_by      uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_payment_plan_items_project ON project_payment_plan_items (project_id, sort_order);
CREATE INDEX idx_payment_plan_items_org ON project_payment_plan_items (organization_id);

CREATE TRIGGER payment_plan_items_set_updated_at BEFORE UPDATE ON project_payment_plan_items
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Tahsilat GERÇEK para hareketidir; ödeme planı yalnızca plandır. Bir
-- plan kalemine bağlanabilir (payment_plan_item_id) ama bağlanmak zorunda
-- değildir (plansız/serbest tahsilat).
CREATE TABLE project_collections (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id      uuid NOT NULL REFERENCES organizations(id),
    project_id           uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    payment_plan_item_id uuid REFERENCES project_payment_plan_items(id) ON DELETE SET NULL,
    amount               numeric(12, 2) NOT NULL CHECK (amount > 0),
    currency             varchar(3) NOT NULL,
    received_date        date NOT NULL,
    payment_method       varchar(40) NOT NULL DEFAULT '',
    description          varchar(500) NOT NULL DEFAULT '',
    reference_no         varchar(100) NOT NULL DEFAULT '',
    -- Çift tıklama/ağ tekrarında aynı tahsilatın iki kez yazılmaması için
    -- istemcinin ürettiği anahtar (bkz. aşağıdaki kısmi UNIQUE indeks).
    idempotency_key      varchar(64),
    created_by           uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    voided_at            timestamptz,
    voided_by            uuid REFERENCES users(id) ON DELETE SET NULL,
    void_reason          varchar(500) NOT NULL DEFAULT ''
);

CREATE INDEX idx_collections_project ON project_collections (project_id);
CREATE INDEX idx_collections_org ON project_collections (organization_id);
CREATE INDEX idx_collections_plan_item ON project_collections (payment_plan_item_id);
CREATE UNIQUE INDEX idx_collections_idempotency
    ON project_collections (project_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE TRIGGER collections_set_updated_at BEFORE UPDATE ON project_collections
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- DİKKAT: kategori listesinde bilinçli olarak 'subcontractor' YOKTUR.
-- Taşerona ödenen para tek bir kapıdan, project_subcontractor_payments
-- üzerinden girilir; aksi halde aynı ödeme hem masraf hem taşeron ödemesi
-- olarak iki kez sayılabilirdi ("tek finans kaynağı" ilkesi). Bunu şema
-- seviyesinde garanti altına alıyoruz, kullanıcı disiplinine bırakmıyoruz.
CREATE TABLE project_expenses (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    category        varchar(20) NOT NULL
                    CHECK (category IN ('material', 'personnel', 'transport',
                                        'accommodation', 'food', 'equipment', 'other')),
    description     varchar(500) NOT NULL,
    amount          numeric(12, 2) NOT NULL CHECK (amount > 0),
    currency        varchar(3) NOT NULL,
    expense_date    date NOT NULL,
    supplier_name   varchar(200) NOT NULL DEFAULT '',
    invoice_no      varchar(100) NOT NULL DEFAULT '',
    notes           text NOT NULL DEFAULT '',
    created_by      uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    voided_at       timestamptz,
    voided_by       uuid REFERENCES users(id) ON DELETE SET NULL,
    void_reason     varchar(500) NOT NULL DEFAULT ''
);

CREATE INDEX idx_expenses_project ON project_expenses (project_id);
CREATE INDEX idx_expenses_org ON project_expenses (organization_id);

CREATE TRIGGER expenses_set_updated_at BEFORE UPDATE ON project_expenses
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Bu tablo proje içi fatura TAKİBİDİR -- gerçek e-Fatura entegrasyonu
-- değildir (bu fazın kapsamı dışında).
CREATE TABLE project_invoices (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    invoice_no      varchar(100) NOT NULL,
    invoice_type    varchar(20) NOT NULL CHECK (invoice_type IN ('sales', 'purchase')),
    invoice_date    date NOT NULL,
    due_date        date,
    amount          numeric(12, 2) NOT NULL CHECK (amount > 0),
    currency        varchar(3) NOT NULL,
    status          varchar(20) NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft', 'issued', 'sent', 'paid', 'cancelled')),
    customer_name   varchar(200) NOT NULL DEFAULT '',
    notes           text NOT NULL DEFAULT '',
    created_by      uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_invoices_project ON project_invoices (project_id);
CREATE INDEX idx_invoices_org ON project_invoices (organization_id);

CREATE TRIGGER invoices_set_updated_at BEFORE UPDATE ON project_invoices
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE project_subcontractors (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    project_id       uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name             varchar(200) NOT NULL,
    company_name     varchar(200) NOT NULL DEFAULT '',
    phone            varchar(40) NOT NULL DEFAULT '',
    email            varchar(120) NOT NULL DEFAULT '',
    work_description varchar(500) NOT NULL DEFAULT '',
    contract_amount  numeric(12, 2) NOT NULL CHECK (contract_amount > 0),
    currency         varchar(3) NOT NULL,
    start_date       date,
    end_date         date,
    status           varchar(20) NOT NULL DEFAULT 'planned'
                     CHECK (status IN ('planned', 'active', 'completed', 'cancelled')),
    notes            text NOT NULL DEFAULT '',
    created_by       uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_subcontractors_project ON project_subcontractors (project_id);
CREATE INDEX idx_subcontractors_org ON project_subcontractors (organization_id);

CREATE TRIGGER subcontractors_set_updated_at BEFORE UPDATE ON project_subcontractors
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE project_subcontractor_payments (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id   uuid NOT NULL REFERENCES organizations(id),
    project_id        uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    subcontractor_id  uuid NOT NULL REFERENCES project_subcontractors(id) ON DELETE CASCADE,
    amount            numeric(12, 2) NOT NULL CHECK (amount > 0),
    currency          varchar(3) NOT NULL,
    paid_date         date NOT NULL,
    description       varchar(500) NOT NULL DEFAULT '',
    idempotency_key   varchar(64),
    created_by        uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    voided_at         timestamptz,
    voided_by         uuid REFERENCES users(id) ON DELETE SET NULL,
    void_reason       varchar(500) NOT NULL DEFAULT ''
);

CREATE INDEX idx_sub_payments_project ON project_subcontractor_payments (project_id);
CREATE INDEX idx_sub_payments_subcontractor ON project_subcontractor_payments (subcontractor_id);
CREATE INDEX idx_sub_payments_org ON project_subcontractor_payments (organization_id);
CREATE UNIQUE INDEX idx_sub_payments_idempotency
    ON project_subcontractor_payments (project_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE TRIGGER sub_payments_set_updated_at BEFORE UPDATE ON project_subcontractor_payments
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- project_events, offer_events'in proje tarafındaki karşılığıdır ve aynı
-- şekilde değişmezdir (UPDATE trigger'la engellenir; tek silinme yolu
-- projenin tamamen silinmesiyle CASCADE).
CREATE TABLE project_events (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    event_type      varchar(40) NOT NULL,
    user_id         uuid REFERENCES users(id) ON DELETE SET NULL,
    metadata        jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_project_events_project ON project_events (project_id, created_at DESC);
CREATE INDEX idx_project_events_org ON project_events (organization_id);

CREATE FUNCTION project_events_prevent_mutation() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'project_events kayıtları değiştirilemez (audit log immutable)';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_project_events_no_update
    BEFORE UPDATE ON project_events
    FOR EACH ROW EXECUTE FUNCTION project_events_prevent_mutation();
