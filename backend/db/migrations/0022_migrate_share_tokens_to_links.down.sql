-- GÜVENLİ GERİ ALMA SINIRI: offer_share_links artık teklif başına BİRDEN
-- FAZLA (revizyon başına) bağlantı tutabildiğinden, bu geri alma yalnızca
-- her teklifin tek bir bağlantısı olduğu durumda tam karşılıktır. Birden
-- fazla varsa, o anki (current) revizyona bağlı en yeni bağlantı seçilir;
-- o da yoksa herhangi biri; o da yoksa yeni bir token üretilir. Diğer
-- bağlantılar bu geri almadan sonra offer_share_links'te kalmaya devam
-- eder (veri kaybı yok, yalnızca offers.share_token tek bir değere
-- indirgenir).
ALTER TABLE offers ADD COLUMN share_token uuid;

UPDATE offers o
SET share_token = COALESCE(
    (SELECT token FROM offer_share_links
     WHERE offer_id = o.id AND revision_id = o.current_revision_id
     ORDER BY created_at DESC LIMIT 1),
    (SELECT token FROM offer_share_links
     WHERE offer_id = o.id
     ORDER BY created_at DESC LIMIT 1),
    gen_random_uuid()
);

ALTER TABLE offers ALTER COLUMN share_token SET NOT NULL;
ALTER TABLE offers ALTER COLUMN share_token SET DEFAULT gen_random_uuid();
ALTER TABLE offers ADD CONSTRAINT offers_share_token_key UNIQUE (share_token);
