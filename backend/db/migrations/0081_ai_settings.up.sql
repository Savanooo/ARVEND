-- Yapay Zekâ Ayarları (2026-10-30). Sahip: "bu AI'yi kim kullanacak vb.
-- kural da eklensin, yönetici yapabilsin." Yönetici uygulamadan firmada
-- yapay zekâyı kapatır/açar, firmanın ve kişinin aylık sınırını belirler.
-- "Kim kullanacak" için YENİ bir tablo yok: kişiye özel ai.images.use
-- ayarı mevcut user_permission_overrides düzeneğiyle yazılır (Roller &
-- Yetkiler ekranıyla aynı kaynak; iki yerde ayrı kural oluşmasın).
--
-- Satır yoksa varsayılan: açık, sunucu varsayılan sınırı, kişi sınırı yok
-- (0081 öncesi davranış aynen). Sunucunun AI_IMAGE_MONTHLY_LIMIT değeri
-- SERT tavandır: firma kendi sınırını yalnızca düşürebilir -- her görsel
-- sunucu sahibinin OpenAI hesabından ücretlenir. Tavan sonradan düşürülürse
-- kayıtlı daha büyük değer okunurken tavana kırpılır (servis).
CREATE TABLE organization_ai_settings (
    organization_id        uuid PRIMARY KEY REFERENCES organizations(id) ON DELETE CASCADE,
    enabled                boolean NOT NULL DEFAULT true,
    -- NULL = sunucu varsayılanı (AI_IMAGE_MONTHLY_LIMIT).
    monthly_limit          integer CHECK (monthly_limit >= 0),
    -- NULL = kişi başı aylık sınır yok (saatlik sınır yine geçerli).
    per_user_monthly_limit integer CHECK (per_user_monthly_limit >= 0),
    updated_by             uuid REFERENCES users(id) ON DELETE SET NULL,
    updated_at             timestamptz NOT NULL DEFAULT now()
);

-- Kişi başı aylık sayım (firma sayımıyla aynı kural: başarısızlar sayılmaz).
CREATE INDEX idx_ai_image_jobs_org_user_created ON ai_image_jobs (organization_id, user_id, created_at);
