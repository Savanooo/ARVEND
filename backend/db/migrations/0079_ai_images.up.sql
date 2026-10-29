-- Yapay zekâ görselleri (2026-10): "önce/sonra" (fotoğraftan bitmiş hali),
-- "fotoğrafı iyileştir" ve "yeni görsel oluştur". Görseli firmanın kendi
-- OpenAI anahtarıyla sunucu üretir (bkz. platform/openai, service/
-- ai_image_service.go); anahtar dosyada durur, veritabanına HİÇ girmez.
--
-- Görsel çağrısı onlarca saniye sürer (gateway ~100 sn'de keser): istek bir
-- İŞ (job) açar ve hemen döner, sunucudaki sınırlı işçi sırayla çalıştırır,
-- uygulama durumu sorar. Sonuç projeye YENİ bir fotoğraf olarak eklenir --
-- kaynak fotoğrafın üzerine asla yazılmaz -- ve ai_generated işaretlidir:
-- kimse onu gerçek şantiye kaydı sanmasın (rozet, günlük rapor dışı).

-- Maliyetli (her görsel firmanın OpenAI hesabından ücretlenir): varsayılan
-- yalnızca Sahip ve Yönetici. Sahip/Yönetici seed fonksiyonunda zaten
-- "bütün izinler"i aldığı için seed_system_roles_for_org değişmez; firma
-- başka rollere/kişilere Roller & Yetkiler ekranından verebilir. Taşeron
-- hesabı bu ucu hiç göremez (oturum kapısı + kilitli Taşeron rolü).
INSERT INTO permissions (code, description, category) VALUES
    ('ai.images.use', 'Yapay zekâ ile görsel üretme (önce/sonra, fotoğraf iyileştirme, yeni görsel) -- her görsel firmanın OpenAI hesabından ücretlenir', 'Yapay Zekâ')
ON CONFLICT (code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, 'ai.images.use'
FROM organization_roles orole
WHERE orole.is_system AND orole.code IN ('owner', 'admin')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

-- Fotoğrafın yapay zekâ işareti. ai_kind/ai_prompt/ai_source_photo_id
-- yalnızca ai_generated satırda dolu (kaynak silinirse bağ düşer, görsel
-- kalır). Kaynak bağı aynı projede kalır: servis başka projenin
-- fotoğrafını kaynak olarak kabul etmez.
ALTER TABLE project_photos
    ADD COLUMN ai_generated boolean NOT NULL DEFAULT false,
    ADD COLUMN ai_kind varchar(20)
        CHECK (ai_kind IN ('before_after', 'enhance', 'generate')),
    ADD COLUMN ai_prompt varchar(1000) NOT NULL DEFAULT '',
    ADD COLUMN ai_source_photo_id uuid REFERENCES project_photos(id) ON DELETE SET NULL,
    ADD CONSTRAINT project_photos_ai_kind_matches CHECK (ai_generated = (ai_kind IS NOT NULL));

-- Görsel işleri. Aylık sınır firmanın bu ayki BAŞARISIZ OLMAYAN işlerinden
-- sayılır (başarısız iş OpenAI'de ücretlenmez); kişi başı saatlik sınır
-- bütün işlerden (art arda hata üreten istekler de sınırlansın).
-- Kaynak/sonuç fotoğrafı silinirse (yalnızca proje temizliğinde gerçekten
-- silinir, normalde yumuşak silme) bağ düşer, iş kaydı ve sayımı kalır.
CREATE TABLE ai_image_jobs (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    user_id         uuid REFERENCES users(id) ON DELETE SET NULL,
    kind            varchar(20) NOT NULL CHECK (kind IN ('before_after', 'enhance', 'generate')),
    prompt          varchar(1000) NOT NULL DEFAULT '',
    source_photo_id uuid REFERENCES project_photos(id) ON DELETE SET NULL,
    status          varchar(10) NOT NULL DEFAULT 'queued'
                    CHECK (status IN ('queued', 'running', 'done', 'failed')),
    -- Kullanıcıya gösterilen Türkçe hata; teknik ayrıntı yalnızca sunucu logunda.
    error           varchar(500) NOT NULL DEFAULT '',
    result_photo_id uuid REFERENCES project_photos(id) ON DELETE SET NULL,
    model           varchar(100) NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    started_at      timestamptz,
    finished_at     timestamptz
);

CREATE INDEX idx_ai_image_jobs_org_created ON ai_image_jobs (organization_id, created_at);
CREATE INDEX idx_ai_image_jobs_user_created ON ai_image_jobs (user_id, created_at);
CREATE INDEX idx_ai_image_jobs_project ON ai_image_jobs (project_id, created_at DESC);
-- İşçinin sıradaki işi seçmesi ve açılıştaki "yarım kalanları kapat".
CREATE INDEX idx_ai_image_jobs_pending ON ai_image_jobs (created_at)
    WHERE status IN ('queued', 'running');
