-- Metraj Hesaplama entegrasyonu (Faz M2): "Metraj Hesapla" sonucu teklif
-- kalemine SNAPSHOT olarak aktarılır -- kategori/reçete SONRADAN
-- değişse (ya da silinse) bile bu kalemin hesap anındaki bilgisi
-- (calc_snapshot) hiç değişmez. offer_revisions'ın "geçmiş belge hiçbir
-- zaman mutate edilmez" ilkesiyle AYNI mantık; calc_category_id yalnızca
-- izlenebilirlik/gruplama içindir, hesap SONUCU tamamen calc_snapshot'ta
-- dondurulmuştur.
--
-- unit: BYZ analizinde offer kalemlerinde hiç yoktu (rapor
-- byz-teklif-proje-donusumu-faz1-arastirma.md), Metraj entegrasyonu için
-- ilk kez ekleniyor -- serbest elle girilen kalemlerde boş kalabilir.
-- section_label: kroki/bölüm adı (ör. "Salon Tavanı") -- aynı teklifte
-- birden çok hesaplamadan gelen kalemleri görsel olarak gruplamak için.
ALTER TABLE offer_revision_items
    ADD COLUMN unit             varchar(30) NOT NULL DEFAULT '',
    ADD COLUMN section_label    varchar(120),
    -- ON DELETE SET NULL: kategori silinse bile teklif kalemi (ve
    -- calc_snapshot'taki dondurulmuş veri) yetim KALMAZ, yalnızca
    -- kategoriye referans kopar.
    ADD COLUMN calc_category_id uuid REFERENCES calc_categories(id) ON DELETE SET NULL,
    ADD COLUMN calc_snapshot    jsonb;

CREATE INDEX idx_offer_revision_items_calc_category
    ON offer_revision_items (calc_category_id) WHERE calc_category_id IS NOT NULL;
