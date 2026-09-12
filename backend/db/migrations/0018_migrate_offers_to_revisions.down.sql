-- GÜVENLİ GERİ ALMA SINIRI: yalnızca her teklifin TEK bir revizyonu
-- (revizyon 0) olduğu bir veritabanında tam veri kaybı olmadan çalışır.
-- Birden fazla revizyon biriktikten sonra bu geri alma, yalnızca her
-- teklifin O ANKİ (current_revision_id) içeriğini eski düz şemaya geri
-- yazar -- geçmiş revizyonların içeriği (offer_revisions/
-- offer_revision_items tabloları 0017'nin down'ında ayrıca silinene kadar
-- orada durur, ama eski offers/offer_items şemasına bir daha
-- yansıtılmaz). Bu, Faz 1'deki benzer geri alma sınırlarıyla aynı
-- prensiptedir: şema daraltma/yeniden yapılandırma sonrası veri
-- birikince kayıpsız geri dönüş matematiksel olarak mümkün değildir.
ALTER TABLE offers
    ADD COLUMN customer_id      uuid REFERENCES customers(id) ON DELETE SET NULL,
    ADD COLUMN customer_name    varchar(200) NOT NULL DEFAULT '',
    ADD COLUMN customer_phone   varchar(40) NOT NULL DEFAULT '',
    ADD COLUMN customer_email   varchar(120) NOT NULL DEFAULT '',
    ADD COLUMN customer_address varchar(500) NOT NULL DEFAULT '',
    ADD COLUMN valid_until      date,
    ADD COLUMN subtotal         numeric(12, 2) NOT NULL DEFAULT 0,
    ADD COLUMN vat_rate         numeric(5, 2) NOT NULL DEFAULT 20,
    ADD COLUMN vat_amount       numeric(12, 2) NOT NULL DEFAULT 0,
    ADD COLUMN grand_total      numeric(12, 2) NOT NULL DEFAULT 0,
    ADD COLUMN notes            text NOT NULL DEFAULT '';

UPDATE offers o
SET customer_id = r.customer_id, customer_name = r.customer_name,
    customer_phone = r.customer_phone, customer_email = r.customer_email,
    customer_address = r.customer_address, valid_until = r.valid_until,
    subtotal = r.subtotal, vat_rate = r.vat_rate, vat_amount = r.vat_amount,
    grand_total = r.grand_total, notes = r.notes
FROM offer_revisions r
WHERE r.id = o.current_revision_id;

ALTER TABLE offers ALTER COLUMN customer_name DROP DEFAULT;

CREATE TABLE offer_items (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    offer_id     uuid NOT NULL REFERENCES offers(id) ON DELETE CASCADE,
    product_id   uuid REFERENCES products(id) ON DELETE SET NULL,
    product_name varchar(200) NOT NULL,
    quantity     numeric(12, 2) NOT NULL,
    unit_price   numeric(12, 2) NOT NULL,
    line_total   numeric(12, 2) NOT NULL,
    sort_order   int NOT NULL DEFAULT 0
);
CREATE INDEX idx_offer_items_offer_id ON offer_items (offer_id);

INSERT INTO offer_items (id, offer_id, product_id, product_name, quantity, unit_price, line_total, sort_order)
SELECT gen_random_uuid(), o.id, ri.product_id, ri.product_name, ri.quantity, ri.unit_price, ri.line_total, ri.sort_order
FROM offers o
JOIN offer_revision_items ri ON ri.revision_id = o.current_revision_id;

DROP INDEX IF EXISTS idx_offers_current_revision_id;
ALTER TABLE offers DROP COLUMN current_revision_id;
