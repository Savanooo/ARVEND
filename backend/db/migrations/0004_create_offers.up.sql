CREATE TABLE offers (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    offer_no      varchar(30) NOT NULL UNIQUE,
    customer_name    varchar(200) NOT NULL,
    customer_phone   varchar(40) NOT NULL DEFAULT '',
    customer_email   varchar(120) NOT NULL DEFAULT '',
    customer_address varchar(500) NOT NULL DEFAULT '',
    offer_date    date NOT NULL DEFAULT CURRENT_DATE,
    valid_until   date,
    subtotal      numeric(12, 2) NOT NULL DEFAULT 0,
    vat_rate      numeric(5, 2) NOT NULL DEFAULT 20,
    vat_amount    numeric(12, 2) NOT NULL DEFAULT 0,
    grand_total   numeric(12, 2) NOT NULL DEFAULT 0,
    notes         text NOT NULL DEFAULT '',
    status        varchar(20) NOT NULL DEFAULT 'taslak'
                  CHECK (status IN ('taslak', 'gönderildi', 'kabul edildi', 'reddedildi')),
    is_passive    boolean NOT NULL DEFAULT false,
    created_by    uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_offers_status ON offers (status);
CREATE INDEX idx_offers_is_passive ON offers (is_passive);

CREATE TRIGGER offers_set_updated_at
    BEFORE UPDATE ON offers
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- Mongo'daki embedded items[] yerine ayrı tablo; sort_order sıralamayı korur.
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

-- BYZ'deki counters koleksiyonuyla aynı fikir: yıl bazlı atomik sayaç.
CREATE TABLE offer_counters (
    year int PRIMARY KEY,
    seq  int NOT NULL DEFAULT 0
);
