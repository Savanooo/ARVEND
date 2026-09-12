-- customer_name/phone/email/address kolonları SİLİNMEZ -- bunlar artık
-- teklif oluşturulduğu andaki müşteri bilgisinin anlık görüntüsüdür
-- (snapshot). customer_id yalnızca "hangi müşteri kartına bağlı"
-- bilgisini taşır; müşteri kartı sonradan değişse/silinse bile teklif
-- sabit kalır (ON DELETE SET NULL).
ALTER TABLE offers ADD COLUMN customer_id uuid REFERENCES customers(id) ON DELETE SET NULL;
CREATE INDEX idx_offers_customer_id ON offers (customer_id);
