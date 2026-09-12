CREATE TABLE products (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name             varchar(200) NOT NULL,
    normalized_name  varchar(200) NOT NULL,
    unit             varchar(30) NOT NULL DEFAULT 'adet',
    unit_price       numeric(12, 2) NOT NULL DEFAULT 0,
    description      text NOT NULL DEFAULT '',
    -- BYZ'de category alani otomatik sureclerce yaziliyor ama elle
    -- duzenlemede sessizce siliniyordu (yari-bitmis bir ozellikti).
    -- Burada normal, kullanicinin ozgurce yonetebildigi bir alan.
    category         varchar(100) NOT NULL DEFAULT '',
    -- Tedarikci kaynagi (ör. "ulas") -- ileride otomatik senkron
    -- eklenirse hangi urunun nereden geldigini izlemek icin.
    source           varchar(50),
    source_price     numeric(12, 2),
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_products_normalized_name ON products (normalized_name);

CREATE TRIGGER products_set_updated_at
    BEFORE UPDATE ON products
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- BYZ'deki embedded price_history[] (son 50 kayitla sinirli) yerine ayri
-- bir tablo: sinirsiz gecmis, gercek sorgu/rapor imkani.
CREATE TABLE product_price_history (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id  uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    old_price   numeric(12, 2) NOT NULL,
    new_price   numeric(12, 2) NOT NULL,
    note        varchar(120) NOT NULL DEFAULT '',
    changed_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_price_history_product_id ON product_price_history (product_id);
