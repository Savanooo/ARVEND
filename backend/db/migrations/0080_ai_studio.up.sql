-- Yapay Zekâ Stüdyo (2026-10-30): projeden bağımsız görsel oluşturma ve
-- fotoğraf düzenleme. 0079'da görsel işi bir proje fotoğrafından açılıyor,
-- sonuç doğrudan projeye fotoğraf olarak ekleniyordu. Sahip istediğinin bu
-- olmadığını söyledi: "ayrı bir yerde resim oluşturma ya da resim atıp bunu
-- AI ile düzenleme -- şantiye/proje içinde değil, ayrı bir menü gibi".
--
-- Stüdyo işi projesizdir (project_id NULL). Kaynak fotoğraf telefondan
-- yüklenir ya da bir proje fotoğrafından KOPYALANIR (depoda ayrı nesne:
-- proje fotoğrafı sonradan silinse de iş çalışır). Sonuç kişinin stüdyo
-- görseli olur; kişi isterse "Projeye ekle" ile bir projenin fotoğraflarına
-- kopyalar (yine ai_generated işaretli).
--
-- Eski uç (POST /projects/{id}/ai-image-jobs) 1.5.22 uygulamaları için
-- aynen çalışır: proje işinde project_id dolu, sonuç yine doğrudan projeye.
-- Aylık firma hakkı, kişi başı saatlik sınır ve işçi ORTAK: hepsi
-- ai_image_jobs'tan sayılır, iş projeli de olsa stüdyo da olsa.

-- 1) İşler: proje artık isteğe bağlı. Proje kalıcı silinirse (proje
-- temizliği) proje işleri yine CASCADE ile gider -- project_id NULL her
-- zaman "stüdyo işi" demektir.
ALTER TABLE ai_image_jobs ALTER COLUMN project_id DROP NOT NULL;

-- 'edit': fotoğrafa serbest düzenleme talimatı ("duvarı griye boya") --
-- stüdyoda ve proje ucunda (sonuç kaynağın aşamasında yeni proje
-- fotoğrafı). Eski uygulamaların gönderdiği türler aynen kalır.
ALTER TABLE ai_image_jobs DROP CONSTRAINT ai_image_jobs_kind_check;
ALTER TABLE ai_image_jobs ADD CONSTRAINT ai_image_jobs_kind_check
    CHECK (kind IN ('before_after', 'enhance', 'generate', 'edit'));

-- Stüdyo işinin kaynak görseli depoda (yalnızca stüdyo işinde dolu).
-- source_photo_id stüdyo işinde yalnızca köken bilgisidir (proje
-- fotoğrafından açıldıysa): görsel aynı projeye eklenince galeri "kaynak:
-- <tarih>" yazabilsin. Stüdyo işi projeye fotoğraf üretmez.
-- mask_storage_key: 'edit' işinde kişinin "kalemle" boyadığı alan (PNG,
-- saydam = değişecek yer), stüdyo ve proje işinde; denetim için saklanır.
ALTER TABLE ai_image_jobs
    ADD COLUMN source_storage_key varchar(500) NOT NULL DEFAULT '',
    ADD COLUMN source_mime varchar(100) NOT NULL DEFAULT '',
    ADD COLUMN mask_storage_key varchar(500) NOT NULL DEFAULT '',
    ADD CONSTRAINT ai_image_jobs_mask_edit_only CHECK (mask_storage_key = '' OR kind = 'edit'),
    ADD CONSTRAINT ai_image_jobs_studio_shape CHECK (
        (project_id IS NULL AND result_photo_id IS NULL)
        OR (project_id IS NOT NULL AND source_storage_key = '')
    );

-- 2) Stüdyo görselleri: kişinin kendi alanı (Sahip/Yönetici firmanınkini de
-- görür, bkz. servis). Yumuşak silme: dosya depoda kalır.
CREATE TABLE ai_studio_images (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    user_id         uuid REFERENCES users(id) ON DELETE SET NULL,
    -- Görseli üreten iş (iş başına en çok bir görsel).
    job_id          uuid UNIQUE REFERENCES ai_image_jobs(id) ON DELETE SET NULL,
    storage_key     varchar(500) NOT NULL UNIQUE,
    mime            varchar(100) NOT NULL,
    size_bytes      bigint NOT NULL CHECK (size_bytes > 0),
    kind            varchar(20) NOT NULL CHECK (kind IN ('before_after', 'enhance', 'generate', 'edit')),
    prompt          varchar(1000) NOT NULL DEFAULT '',
    created_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,
    deleted_by      uuid REFERENCES users(id) ON DELETE SET NULL
);

-- "Görsellerim" (kişi) ve Sahip/Yönetici'nin firma görünümü: en yenisi önce.
CREATE INDEX idx_ai_studio_images_user ON ai_studio_images (organization_id, user_id, created_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX idx_ai_studio_images_org ON ai_studio_images (organization_id, created_at DESC)
    WHERE deleted_at IS NULL;

-- 3) "Projeye ekle": stüdyo görselinin projedeki kopyası. Görsel + proje
-- başına tek bağ: ikinci "Projeye ekle" aynı fotoğrafı döner (fotoğraf
-- projeden silindiyse yenisi açılır ve bağ ona taşınır).
CREATE TABLE ai_studio_image_projects (
    studio_image_id  uuid NOT NULL REFERENCES ai_studio_images(id) ON DELETE CASCADE,
    project_id       uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    project_photo_id uuid NOT NULL REFERENCES project_photos(id) ON DELETE CASCADE,
    added_by         uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (studio_image_id, project_id)
);

CREATE INDEX idx_ai_studio_image_projects_project ON ai_studio_image_projects (project_id);

-- 'edit' görseli de (proje işinin sonucu ya da "Projeye ekle" kopyası)
-- yapay zekâ işaretli fotoğraftır.
ALTER TABLE project_photos DROP CONSTRAINT project_photos_ai_kind_check;
ALTER TABLE project_photos ADD CONSTRAINT project_photos_ai_kind_check
    CHECK (ai_kind IN ('before_after', 'enhance', 'generate', 'edit'));
