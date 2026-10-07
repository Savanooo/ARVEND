-- Masraflara KDV bilgisi (ürün sahibi kararı, 2026-10-07). Finans özeti
-- sözleşmenin KDV'sini düşüp "KDV hariç kâr" gösteriyordu ama masraflar
-- KDV dahil girildiği gibi çıkarılıyordu: KDV hariç kâr olduğundan düşük
-- görünüyordu.
--
-- vat_rate: masrafın KDV oranı (%). NULL = "belirtilmedi" -- mevcut bütün
-- satırlar böyle kalır ve önceki gibi tutarın TAMAMI maliyet sayılır;
-- bugünkü rakamlar değişmez. amount yine ödenen tutardır (oran verilmişse
-- KDV dahil).
ALTER TABLE project_expenses
    ADD COLUMN vat_rate numeric(5,2)
        CONSTRAINT project_expenses_vat_rate_check CHECK (vat_rate >= 0 AND vat_rate <= 100);

-- vat_amount: tutarın İÇİNDEKİ KDV, kuruşa yuvarlı. Saklanan üretilmiş
-- kolon: masraf satırının gösterdiği KDV ile finans özetinin topladığı KDV
-- aynı numeric hesaptan gelir (Go'da float yuvarlaması yok). Oran NULL ise
-- NULL. Kolon eklenirken tablo bir kez yeniden yazılır (masraf tablosu
-- küçük; kısa süreli kilit).
ALTER TABLE project_expenses
    ADD COLUMN vat_amount numeric(18,2)
        GENERATED ALWAYS AS (round(amount * vat_rate / (100 + vat_rate), 2)) STORED;
