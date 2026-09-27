-- Tedarikçi fiyat listesi senkronu (BYZ'deki "Ulaş Güncelle" + gece 00:05
-- işinin firma bazlı karşılığı). BYZ'de kâr oranı koda gömülüydü (%15,
-- MARKUP = 1.15) ve tek firma vardı; burada her firma kendi oranını (ve
-- isterse kategori bazında farklı oranları) belirler, gece senkronunu
-- kendisi açar.

-- products.source_synced_at: satırın kaynak listede EN SON görüldüğü an.
-- Listeden düşen ürünler SİLİNMEZ (teklif/reçete bağlantıları kopmasın,
-- bkz. calc_recipe_items/project_change_order_items FK'leri) -- bu kolonun
-- son senkron anından eski olması "listede artık yok" demektir.
ALTER TABLE products ADD COLUMN source_synced_at timestamptz;

CREATE INDEX idx_products_org_source ON products (organization_id, source)
    WHERE source IS NOT NULL;

-- organization_price_sources: firma x kaynak başına tek satır. "Satır yok"
-- = varsayılanlar (%15, otomatik senkron KAPALI, hiç çalışmadı). Hiçbir
-- firma için auto_sync burada AÇILMAZ -- firma sahibi kendisi açar.
CREATE TABLE organization_price_sources (
    organization_id uuid          NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    source          varchar(30)   NOT NULL CHECK (source IN ('ulas')),
    markup_percent  numeric(7, 2) NOT NULL DEFAULT 15
                    CHECK (markup_percent >= 0 AND markup_percent <= 1000),
    auto_sync       boolean       NOT NULL DEFAULT false,
    -- Son BAŞARILI senkronun zamanı; başarısız denemede DEĞİŞMEZ (eksik
    -- ürün hesabı buna göre yapılır).
    last_synced_at  timestamptz,
    last_status     varchar(20)   NOT NULL DEFAULT 'never'
                    CHECK (last_status IN ('never', 'success', 'failed')),
    last_error      text          NOT NULL DEFAULT '',
    -- Son başarılı senkronun sayıları: total = listedeki (tekilleştirilmiş)
    -- ürün sayısı = created + updated + unchanged; missing = firmanın
    -- listede artık bulunmayan kaynak ürünleri.
    last_total      int           NOT NULL DEFAULT 0,
    last_created    int           NOT NULL DEFAULT 0,
    last_updated    int           NOT NULL DEFAULT 0,
    last_unchanged  int           NOT NULL DEFAULT 0,
    last_missing    int           NOT NULL DEFAULT 0,
    updated_by      uuid          REFERENCES users(id) ON DELETE SET NULL,
    created_at      timestamptz   NOT NULL DEFAULT now(),
    updated_at      timestamptz   NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, source)
);

CREATE TRIGGER organization_price_sources_set_updated_at BEFORE UPDATE ON organization_price_sources
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Kategori bazında kâr oranı: ürünün kaynak kategorisi (products.category,
-- senkron tarafından yazılır) burada varsa bu oran, yoksa varsayılan oran.
CREATE TABLE organization_price_source_category_markups (
    organization_id uuid          NOT NULL,
    source          varchar(30)   NOT NULL,
    category        varchar(100)  NOT NULL,
    markup_percent  numeric(7, 2) NOT NULL
                    CHECK (markup_percent >= 0 AND markup_percent <= 1000),
    PRIMARY KEY (organization_id, source, category),
    FOREIGN KEY (organization_id, source)
        REFERENCES organization_price_sources (organization_id, source) ON DELETE CASCADE
);
