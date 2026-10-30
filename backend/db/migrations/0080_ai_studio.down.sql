-- Stüdyo görselleri ve "Projeye ekle" bağları düşer. Projeye eklenmiş
-- kopyalar (project_photos satırları) KALIR: projenin fotoğrafı olmuşlardır,
-- yapay zekâ işaretleri durur. 'edit' türü 0079'da yok -- 'generate'
-- sayılır. Stüdyo ve maske dosyaları (ai-studio/..., ai-masks/...) depoda
-- kalır (elle silinebilir).
DROP TABLE IF EXISTS ai_studio_image_projects;
DROP TABLE IF EXISTS ai_studio_images;

UPDATE project_photos SET ai_kind = 'generate' WHERE ai_kind = 'edit';
ALTER TABLE project_photos DROP CONSTRAINT IF EXISTS project_photos_ai_kind_check;
ALTER TABLE project_photos ADD CONSTRAINT project_photos_ai_kind_check
    CHECK (ai_kind IN ('before_after', 'enhance', 'generate'));

-- Projesiz (stüdyo) işler 0079 şemasına sığmaz: silinir; bu ayın hak
-- sayımından da düşerler (geri dönüşü sunucu yöneticisi bilerek yapar).
-- Proje 'edit' işleri kalır, 'generate' sayılır (maske kısıtı önce düşer).
DELETE FROM ai_image_jobs WHERE project_id IS NULL;
ALTER TABLE ai_image_jobs
    DROP CONSTRAINT IF EXISTS ai_image_jobs_studio_shape,
    DROP CONSTRAINT IF EXISTS ai_image_jobs_mask_edit_only,
    DROP COLUMN IF EXISTS mask_storage_key,
    DROP COLUMN IF EXISTS source_mime,
    DROP COLUMN IF EXISTS source_storage_key;
UPDATE ai_image_jobs SET kind = 'generate' WHERE kind = 'edit';
ALTER TABLE ai_image_jobs DROP CONSTRAINT IF EXISTS ai_image_jobs_kind_check;
ALTER TABLE ai_image_jobs ADD CONSTRAINT ai_image_jobs_kind_check
    CHECK (kind IN ('before_after', 'enhance', 'generate'));
ALTER TABLE ai_image_jobs ALTER COLUMN project_id SET NOT NULL;
