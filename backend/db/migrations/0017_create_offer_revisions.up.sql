-- offer_revisions, bir teklifin her "hâlinin" değişmez bir anlık
-- görüntüsüdür. Revizyon 0, teklif ilk oluşturulduğunda otomatik açılır;
-- sonraki her revizyon yalnızca kullanıcı bilinçli olarak "Revize Et"
-- dediğinde (ve yalnızca teklif zaten müşteriye gönderilmişse/reddedilmişse)
-- oluşur -- taslak durumdaki normal düzenlemeler AYNI revizyonu yerinde
-- günceller, yeni revizyon SAYMAZ.
CREATE TABLE offer_revisions (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    offer_id         uuid NOT NULL REFERENCES offers(id) ON DELETE CASCADE,
    revision_no      int NOT NULL,
    customer_id      uuid REFERENCES customers(id) ON DELETE SET NULL,
    customer_name    varchar(200) NOT NULL,
    customer_phone   varchar(40) NOT NULL DEFAULT '',
    customer_email   varchar(120) NOT NULL DEFAULT '',
    customer_address varchar(500) NOT NULL DEFAULT '',
    valid_until      date,
    subtotal         numeric(12, 2) NOT NULL DEFAULT 0,
    -- discount_*/currency kolonları Faz 4'ün alanları -- şema burada
    -- hazırlanıyor ki Faz 4 yeni bir migration'a gerek duymadan yalnızca
    -- iş mantığını eklesin; bu fazda hep varsayılan değerleriyle yazılır.
    discount_type    varchar(10) NOT NULL DEFAULT 'none'
                     CHECK (discount_type IN ('none', 'percent', 'fixed')),
    discount_value   numeric(12, 2) NOT NULL DEFAULT 0,
    discount_amount  numeric(12, 2) NOT NULL DEFAULT 0,
    vat_rate         numeric(5, 2) NOT NULL DEFAULT 20,
    vat_amount       numeric(12, 2) NOT NULL DEFAULT 0,
    grand_total      numeric(12, 2) NOT NULL DEFAULT 0,
    currency         varchar(3) NOT NULL DEFAULT 'TRY',
    notes            text NOT NULL DEFAULT '',
    status           varchar(20) NOT NULL DEFAULT 'taslak'
                     CHECK (status IN ('taslak', 'gönderildi', 'kabul edildi', 'reddedildi')),
    created_by       uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (offer_id, revision_no)
);

CREATE INDEX idx_offer_revisions_offer_id ON offer_revisions (offer_id);
CREATE INDEX idx_offer_revisions_organization_id ON offer_revisions (organization_id);

CREATE TABLE offer_revision_items (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    revision_id     uuid NOT NULL REFERENCES offer_revisions(id) ON DELETE CASCADE,
    product_id      uuid REFERENCES products(id) ON DELETE SET NULL,
    product_name    varchar(200) NOT NULL,
    quantity        numeric(12, 2) NOT NULL,
    unit_price      numeric(12, 2) NOT NULL,
    discount_type   varchar(10) NOT NULL DEFAULT 'none'
                    CHECK (discount_type IN ('none', 'percent', 'fixed')),
    discount_value  numeric(12, 2) NOT NULL DEFAULT 0,
    line_total      numeric(12, 2) NOT NULL,
    sort_order      int NOT NULL DEFAULT 0
);

CREATE INDEX idx_offer_revision_items_revision_id ON offer_revision_items (revision_id);
