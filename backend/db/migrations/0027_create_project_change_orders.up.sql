-- Faz 8: Ek İşler / Değişiklik Emirleri (Change Orders).
--
-- TEMEL İLKE: projects.contract_amount ASLA değiştirilmez -- kabul
-- edilen teklif revizyonundan gelen dondurulmuş ANA SÖZLEŞME bedelidir.
-- "Güncel proje bedeli" (current_contract_value) hiçbir yerde bir kolon
-- olarak TUTULMAZ; her zaman
--   base_contract_amount + onaylı ek işler - onaylı eksiltmeler
-- olarak, onaylı change order kayıtlarından SQL'de aggregate edilerek
-- hesaplanır (proje finans özetindeki diğer tüm toplamlarla aynı ilke).
--
-- İŞARET KURALI: change_order tutarları HER ZAMAN pozitiftir; "ek iş" mi
-- "eksiltme" mi olduğu change_type kolonuyla ayrılır, işaret aggregate
-- sırasında (+/-) uygulanır. Negatif tutar kaydı YOKTUR.
--
-- PARA: tüm tutarlar numeric(18,2) (Faz 6/7 denetiminde standardize
-- edilen hassasiyetle uyumlu); toplama/çıkarma SQL tarafında numeric
-- üzerinde yapılır.

CREATE TABLE project_change_orders (
    id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id           uuid NOT NULL REFERENCES organizations(id),
    project_id                uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    sequence_no               int NOT NULL,

    change_type               varchar(10) NOT NULL CHECK (change_type IN ('addition', 'deduction')),
    title                     varchar(200) NOT NULL,
    description               text NOT NULL DEFAULT '',

    status                    varchar(20) NOT NULL DEFAULT 'draft'
                              CHECK (status IN ('draft', 'sent', 'approved', 'rejected', 'cancelled', 'superseded')),

    -- Kalemlerden SQL'de hesaplanır (bkz. service katmanındaki recompute
    -- adımı) -- istemciden gelen toplamlara ASLA güvenilmez. >= 0 kısıtı
    -- burada bilinçli olarak gevşek: satır önce 0 ile oluşturulur, kalemler
    -- eklendikten SONRA tek bir UPDATE ile gerçek toplama kavuşur (kalemler
    -- FK ile bu satıra bağlı olduğu için önce satır var olmalı). "En az bir
    -- kalem ve toplam > 0" kuralı servis katmanında transaction içinde
    -- doğrulanır; aksi halde tüm işlem geri alınır.
    subtotal                  numeric(18, 2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    vat_rate                  numeric(5, 2) NOT NULL DEFAULT 20 CHECK (vat_rate >= 0),
    vat_amount                numeric(18, 2) NOT NULL DEFAULT 0 CHECK (vat_amount >= 0),
    grand_total               numeric(18, 2) NOT NULL DEFAULT 0 CHECK (grand_total >= 0),
    currency                  varchar(3) NOT NULL,

    internal_notes            text NOT NULL DEFAULT '',
    customer_notes            text NOT NULL DEFAULT '',

    created_by                uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at                timestamptz NOT NULL DEFAULT now(),
    updated_at                timestamptz NOT NULL DEFAULT now(),

    sent_at                   timestamptz,
    responded_at              timestamptz,
    approved_at               timestamptz,
    rejected_at               timestamptz,
    cancelled_at              timestamptz,

    -- "Revize Et": eski (gönderilmiş/reddedilmiş) kayıt SESSİZCE
    -- değiştirilmez -- yeni bir taslak satır oluşturulur, bu kolonla eski
    -- satıra bağlanır, eski satır 'superseded' olur. Ticari belge tarihçesi
    -- hiçbir zaman mutate edilmez (offer_revisions ile aynı ilke).
    supersedes_change_order_id uuid REFERENCES project_change_orders(id),

    UNIQUE (project_id, sequence_no)
);

CREATE INDEX idx_change_orders_project ON project_change_orders (project_id);
CREATE INDEX idx_change_orders_org ON project_change_orders (organization_id);
CREATE INDEX idx_change_orders_status ON project_change_orders (project_id, status);

CREATE TRIGGER change_orders_set_updated_at BEFORE UPDATE ON project_change_orders
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Her proje kendi bağımsız EK-NNN sıra numarasına sahiptir (org+yıl değil,
-- proje bazlı -- project_counters'tan farklı bir kapsam). Concurrency
-- güvenliği tek bir atomik UPSERT'ten gelir (bkz. NextProjectSeq deseni);
-- ayrı bir kilide gerek yoktur.
CREATE TABLE change_order_counters (
    project_id uuid PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
    seq        int NOT NULL DEFAULT 0
);

CREATE TABLE project_change_order_items (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id       uuid NOT NULL REFERENCES organizations(id),
    project_id            uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    change_order_id       uuid NOT NULL REFERENCES project_change_orders(id) ON DELETE CASCADE,

    product_id            uuid REFERENCES products(id),
    description           varchar(300) NOT NULL,
    quantity              numeric(12, 2) NOT NULL CHECK (quantity > 0),
    unit                  varchar(30) NOT NULL DEFAULT '',
    unit_price            numeric(18, 2) NOT NULL CHECK (unit_price > 0),
    line_total            numeric(18, 2) NOT NULL CHECK (line_total > 0),
    sort_order            int NOT NULL DEFAULT 0,

    -- Yalnızca dahili PLANLAMA amaçlıdır -- gerçek maliyet/kârlılık
    -- HİÇBİR ZAMAN bu alanlardan değil, change_order_id ile ilişkili
    -- gerçek project_expenses/project_subcontractors kayıtlarından
    -- hesaplanır (bkz. aşağıdaki iki ALTER TABLE). Çift sayım riski yok
    -- çünkü bu alanlar hiçbir aggregate sorguya girmez.
    estimated_unit_cost   numeric(18, 2),
    estimated_cost        numeric(18, 2)
);

CREATE INDEX idx_change_order_items_change_order ON project_change_order_items (change_order_id);

-- Bir masraf/taşeron sözleşmesi opsiyonel olarak bir ek işe etiketlenebilir
-- -- bu SADECE proje toplamının FİLTRELENMİŞ bir görünümüdür (bkz. yukarı
-- yorum); proje toplamına zaten bir kez, change_order_id'den bağımsız
-- olarak girer. change_order_id NULL ise bu kayıt ana sözleşme kapsamındadır.
ALTER TABLE project_expenses
    ADD COLUMN change_order_id uuid REFERENCES project_change_orders(id) ON DELETE SET NULL;
CREATE INDEX idx_expenses_change_order ON project_expenses (change_order_id) WHERE change_order_id IS NOT NULL;

ALTER TABLE project_subcontractors
    ADD COLUMN change_order_id uuid REFERENCES project_change_orders(id) ON DELETE SET NULL;
CREATE INDEX idx_subcontractors_change_order ON project_subcontractors (change_order_id) WHERE change_order_id IS NOT NULL;

-- Müşteri paylaşım linki -- offer_share_links ile AYNI tasarım (tahmin
-- edilemez uuid token, expires_at/revoked_at). Change order'ın kendisi
-- zaten offer_revisions'ın karşılığı olan "dondurulmuş belge" birimi
-- olduğu için (her "Revize Et" yeni bir SATIR/sequence_no üretir), linkin
-- ayrıca bir "revision_id"ye bağlanmasına gerek yoktur -- doğrudan
-- change_order_id'ye bağlanır.
CREATE TABLE project_change_order_share_links (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    change_order_id uuid NOT NULL REFERENCES project_change_orders(id) ON DELETE CASCADE,
    token           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    created_by      uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    expires_at      timestamptz,
    revoked_at      timestamptz
);

CREATE INDEX idx_co_share_links_change_order ON project_change_order_share_links (change_order_id);
CREATE INDEX idx_co_share_links_org ON project_change_order_share_links (organization_id);

CREATE TABLE project_change_order_email_logs (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    change_order_id uuid NOT NULL REFERENCES project_change_orders(id) ON DELETE CASCADE,
    share_link_id   uuid NOT NULL REFERENCES project_change_order_share_links(id),
    recipient       varchar(255) NOT NULL,
    subject         varchar(300) NOT NULL,
    status          varchar(20) NOT NULL CHECK (status IN ('sent', 'failed')),
    error_message   text NOT NULL DEFAULT '',
    sent_by         uuid REFERENCES users(id) ON DELETE SET NULL,
    sent_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_co_email_logs_change_order ON project_change_order_email_logs (change_order_id);
CREATE INDEX idx_co_email_logs_org ON project_change_order_email_logs (organization_id);
