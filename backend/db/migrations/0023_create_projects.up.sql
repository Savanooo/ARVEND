-- projects, kabul edilmiş bir teklif revizyonunun "işe dönüşmüş" halidir.
-- Teklif "müşteriye ne teklif ettik?" sorusunun, proje "bu işi nasıl
-- yürütüyoruz?" sorusunun kaydıdır; bu yüzden müşteri bilgileri ve
-- sözleşme bedeli buraya ANLIK GÖRÜNTÜ (snapshot) olarak kopyalanır --
-- kaynak teklif/revizyon sonradan değişse bile proje sessizce değişmez
-- (revizyonlar zaten dondurulmuş durumda, bu ikinci bir güvence).
CREATE TABLE projects (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id    uuid NOT NULL REFERENCES organizations(id),
    project_no         varchar(30) NOT NULL,
    name               varchar(200) NOT NULL,
    project_type       varchar(100) NOT NULL DEFAULT '',
    source_offer_id    uuid NOT NULL REFERENCES offers(id),
    source_revision_id uuid NOT NULL REFERENCES offer_revisions(id),
    customer_id        uuid REFERENCES customers(id) ON DELETE SET NULL,
    -- Müşteri snapshot'ı (kabul edilen revizyondan kopyalanır).
    customer_name      varchar(200) NOT NULL,
    customer_phone     varchar(40) NOT NULL DEFAULT '',
    customer_email     varchar(120) NOT NULL DEFAULT '',
    customer_address   varchar(500) NOT NULL DEFAULT '',
    -- Sözleşme bedeli de snapshot'tır: kullanıcı serbestçe değiştiremez,
    -- ileride "Ek İşler / Change Orders" ile yönetilecek.
    contract_amount    numeric(12, 2) NOT NULL,
    currency           varchar(3) NOT NULL DEFAULT 'TRY',
    status             varchar(20) NOT NULL DEFAULT 'planned'
                       CHECK (status IN ('planned', 'active', 'paused', 'completed', 'cancelled')),
    start_date         date,
    end_date           date,
    description        text NOT NULL DEFAULT '',
    internal_notes     text NOT NULL DEFAULT '',
    created_by         uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    -- Aynı kabul edilmiş revizyon YALNIZCA bir projeye dönüşebilir. Çift
    -- tıklama/eşzamanlı istek durumunda ikinci INSERT bu kısıta takılır;
    -- servis katmanı bunu "mevcut projeyi döndür" olarak ele alır
    -- (idempotent davranış).
    UNIQUE (organization_id, source_revision_id)
);

CREATE INDEX idx_projects_organization_id ON projects (organization_id);
CREATE INDEX idx_projects_source_offer_id ON projects (source_offer_id);
CREATE INDEX idx_projects_status ON projects (organization_id, status);
CREATE INDEX idx_projects_customer_id ON projects (customer_id);
CREATE UNIQUE INDEX idx_projects_org_project_no ON projects (organization_id, project_no);

CREATE TRIGGER projects_set_updated_at BEFORE UPDATE ON projects
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Proje numarası sayacı: teklif sayacıyla (offer_counters) birebir aynı
-- desen -- her firma kendi PRJ-YIL-0001'inden başlar ve artış
-- ON CONFLICT DO UPDATE ile tek ifadede atomik yapılır.
CREATE TABLE project_counters (
    organization_id uuid NOT NULL REFERENCES organizations(id),
    year            int  NOT NULL,
    seq             int  NOT NULL DEFAULT 0,
    PRIMARY KEY (organization_id, year)
);
