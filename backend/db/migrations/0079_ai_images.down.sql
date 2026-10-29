DROP TABLE IF EXISTS ai_image_jobs;

-- Üretilmiş görseller sıradan fotoğraf olarak kalmasın: işaret sütunu
-- düşünce "gerçek şantiye fotoğrafı" gibi görünürlerdi -- yumuşak silinir
-- (dosyalar depoda kalır, gerekirse geri alınabilir).
UPDATE project_photos SET deleted_at = now() WHERE ai_generated AND deleted_at IS NULL;

ALTER TABLE project_photos
    DROP CONSTRAINT IF EXISTS project_photos_ai_kind_matches,
    DROP COLUMN IF EXISTS ai_source_photo_id,
    DROP COLUMN IF EXISTS ai_prompt,
    DROP COLUMN IF EXISTS ai_kind,
    DROP COLUMN IF EXISTS ai_generated;

DELETE FROM user_permission_overrides WHERE permission_code = 'ai.images.use';
DELETE FROM role_permissions WHERE permission_code = 'ai.images.use';
DELETE FROM permissions WHERE code = 'ai.images.use';
