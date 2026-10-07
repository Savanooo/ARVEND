-- Teklif listesi artık gerçek sayfalama + sunucu tarafı filtrelerle
-- çalışıyor (bkz. queries/offers.sql ListOffers/CountOffersByStatus):
-- firma + aktif/pasif sekmesi içinde en yeni önce sıralanan sorgu için
-- bileşik index. Mevcut veriyi değiştirmez; IF NOT EXISTS ile tekrar
-- çalıştırılabilir.
CREATE INDEX IF NOT EXISTS idx_offers_org_passive_created
    ON offers (organization_id, is_passive, created_at DESC, id DESC);
