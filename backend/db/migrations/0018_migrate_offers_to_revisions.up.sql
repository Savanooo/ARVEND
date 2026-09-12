-- offers artık yalnızca kimlik + lifecycle taşır (id, organization_id,
-- offer_no, offer_date, status [current_revision'ın aynası], is_passive,
-- share_token, created_by, timestamps); gerçek içerik (müşteri, kalemler,
-- toplamlar, notlar) current_revision_id üzerinden offer_revisions'ta
-- yaşar. current_revision_id NULLABLE'dır (NOT NULL yapılamaz -- offers ve
-- offer_revisions birbirine FK verdiği için bir satır diğerinden önce var
-- olmalı; uygulama katmanı her zaman aynı transaction içinde hemen set
-- eder).
ALTER TABLE offers ADD COLUMN current_revision_id uuid REFERENCES offer_revisions(id);

-- Mevcut her teklifin o anki içeriğini revizyon 0 olarak arşivle --
-- bu migration'dan önce oluşturulmuş teklifler kaybolmasın.
INSERT INTO offer_revisions (
    id, organization_id, offer_id, revision_no, customer_id, customer_name,
    customer_phone, customer_email, customer_address, valid_until,
    subtotal, vat_rate, vat_amount, grand_total, notes, status, created_by, created_at
)
SELECT
    gen_random_uuid(), o.organization_id, o.id, 0, o.customer_id, o.customer_name,
    o.customer_phone, o.customer_email, o.customer_address, o.valid_until,
    o.subtotal, o.vat_rate, o.vat_amount, o.grand_total, o.notes, o.status, o.created_by, o.created_at
FROM offers o;

INSERT INTO offer_revision_items (
    id, revision_id, product_id, product_name, quantity, unit_price, line_total, sort_order
)
SELECT
    gen_random_uuid(), r.id, oi.product_id, oi.product_name, oi.quantity, oi.unit_price, oi.line_total, oi.sort_order
FROM offer_items oi
JOIN offer_revisions r ON r.offer_id = oi.offer_id AND r.revision_no = 0;

UPDATE offers o
SET current_revision_id = r.id
FROM offer_revisions r
WHERE r.offer_id = o.id AND r.revision_no = 0;

-- İçerik artık offer_revisions'ta yaşadığından eski kolonlar/tablo
-- kaldırılır.
DROP TABLE offer_items;

ALTER TABLE offers
    DROP COLUMN customer_id,
    DROP COLUMN customer_name,
    DROP COLUMN customer_phone,
    DROP COLUMN customer_email,
    DROP COLUMN customer_address,
    DROP COLUMN valid_until,
    DROP COLUMN subtotal,
    DROP COLUMN vat_rate,
    DROP COLUMN vat_amount,
    DROP COLUMN grand_total,
    DROP COLUMN notes;

CREATE INDEX idx_offers_current_revision_id ON offers (current_revision_id);
