-- offers.share_token (0008) teklif başına TEK bir bağlantı varsayıyordu;
-- artık bağlantılar offer_share_links'te, her biri belirli bir revizyona
-- bağlı olarak yaşıyor (0019). Mevcut her teklifin share_token'ını, o
-- teklifin O ANKİ (current) revizyonuna bağlı, süresiz/aktif bir
-- offer_share_links kaydına AYNEN taşıyoruz -- böylece daha önce
-- gönderilmiş e-postalardaki linkler (aynı token değeriyle) çalışmaya
-- devam eder.
INSERT INTO offer_share_links (organization_id, offer_id, revision_id, token, created_at)
SELECT organization_id, id, current_revision_id, share_token, created_at
FROM offers
WHERE current_revision_id IS NOT NULL;

ALTER TABLE offers DROP COLUMN share_token;
