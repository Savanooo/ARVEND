-- GÜVENLİ GERİ ALMA SINIRI: yalnızca tek organizasyonluk (veya her yılı
-- yalnızca bir organizasyonun kullandığı) bir veritabanında çalışır --
-- birden fazla organizasyon aynı yıl için bağımsız sayaç satırı
-- oluşturduysa (beklenen durum), (organization_id, year) -> (year) PK
-- daralması "duplicate key" ile başarısız olur. Bkz. 0014'ün down.sql'i
-- aynı sınır için.
ALTER TABLE offer_counters DROP CONSTRAINT offer_counters_pkey;
ALTER TABLE offer_counters ADD PRIMARY KEY (year);
ALTER TABLE offer_counters DROP COLUMN organization_id;
