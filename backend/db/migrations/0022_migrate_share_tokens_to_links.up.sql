-- offers.share_token (0008) teklif başına TEK bir bağlantı varsayıyordu;
-- artık bağlantılar offer_share_links'te, her biri belirli bir revizyona
-- bağlı olarak yaşıyor (0019). Mevcut her teklifin share_token'ını, o
-- teklifin O ANKİ (current) revizyonuna bağlı, süresiz/aktif bir
-- offer_share_links kaydına AYNEN taşıyoruz -- böylece daha önce
-- gönderilmiş e-postalardaki linkler (aynı token değeriyle) çalışmaya
-- devam eder.
-- NOT EXISTS koşulu, bu migration'ın YENİDEN uygulanabilir olmasını
-- sağlar: 0022 tek başına geri alındığında (down) offer_share_links
-- satırları bilinçli olarak yerinde bırakılır, dolayısıyla koşulsuz bir
-- INSERT tekrar çalıştırıldığında token UNIQUE kısıtını ihlal eder ve
-- schema_migrations'ı "dirty" bırakırdı.
INSERT INTO offer_share_links (organization_id, offer_id, revision_id, token, created_at)
SELECT o.organization_id, o.id, o.current_revision_id, o.share_token, o.created_at
FROM offers o
WHERE o.current_revision_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM offer_share_links l WHERE l.token = o.share_token);

ALTER TABLE offers DROP COLUMN share_token;
