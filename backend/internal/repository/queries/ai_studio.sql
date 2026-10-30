-- Yapay Zekâ Stüdyo (migration 0080; bkz. service/ai_studio_service.go).
-- Stüdyo işi = project_id NULL olan ai_image_jobs satırı; hak sayımı ve
-- işçi proje işleriyle ortak (bkz. ai_images.sql).

-- name: CreateAIStudioJob :one
INSERT INTO ai_image_jobs (organization_id, project_id, user_id, kind, prompt, source_photo_id,
                           source_storage_key, source_mime, model, mask_storage_key)
VALUES (sqlc.arg(organization_id), NULL, sqlc.arg(user_id), sqlc.arg(kind), sqlc.arg(prompt),
        sqlc.narg(source_photo_id), sqlc.arg(source_storage_key), sqlc.arg(source_mime), sqlc.arg(model),
        sqlc.arg(mask_storage_key))
RETURNING *;

-- name: GetAIStudioJob :one
-- İşi yalnızca açan kişi görür; firma şartı başka firmanın iş kimliğini
-- bilse bile okunmasını engeller. Proje işi bu uçtan görünmez.
SELECT sqlc.embed(j), i.id AS studio_image_id
FROM ai_image_jobs j
LEFT JOIN ai_studio_images i ON i.job_id = j.id
WHERE j.id = sqlc.arg(id) AND j.organization_id = sqlc.arg(organization_id)
  AND j.user_id = sqlc.arg(user_id) AND j.project_id IS NULL;

-- name: ListUserPendingAIStudioJobs :many
-- "Hazırlanıyor…" kutucukları: kişinin sırada/çalışan stüdyo işleri.
SELECT * FROM ai_image_jobs
WHERE organization_id = sqlc.arg(organization_id) AND user_id = sqlc.arg(user_id)
  AND project_id IS NULL AND status IN ('queued', 'running')
ORDER BY created_at DESC;

-- name: CompleteAIStudioJob :execrows
-- Sonuç görseliyle aynı transaction'da: iş artık çalışmıyorsa (açılışta
-- kapatıldıysa) görsel de kaydedilmez.
UPDATE ai_image_jobs SET status = 'done', error = '', finished_at = now()
WHERE id = sqlc.arg(id) AND status = 'running' AND project_id IS NULL;

-- name: CreateAIStudioImage :one
INSERT INTO ai_studio_images (organization_id, user_id, job_id, storage_key, mime, size_bytes, kind, prompt)
VALUES (sqlc.arg(organization_id), sqlc.narg(user_id), sqlc.arg(job_id), sqlc.arg(storage_key),
        sqlc.arg(mime), sqlc.arg(size_bytes), sqlc.arg(kind), sqlc.arg(prompt))
RETURNING *;

-- name: ListAIStudioImages :many
-- Görsellerim (all_users=false: yalnızca user_id) ya da Sahip/Yönetici'nin
-- firma görünümü (all_users=true). before: bir önceki sayfanın son
-- created_at'i (NULL = ilk sayfa). user_id NULL verilirse hiçbir satır
-- eşleşmez (NULL = x) -- "kendi görsellerim" asla firma görünümüne kaymaz.
SELECT sqlc.embed(i), COALESCE(u.full_name, '')::text AS user_name
FROM ai_studio_images i
LEFT JOIN users u ON u.id = i.user_id
WHERE i.organization_id = sqlc.arg(organization_id) AND i.deleted_at IS NULL
  AND (sqlc.arg(all_users)::boolean OR i.user_id = sqlc.narg(user_id)::uuid)
  AND (sqlc.narg(before)::timestamptz IS NULL OR i.created_at < sqlc.narg(before)::timestamptz)
ORDER BY i.created_at DESC, i.id DESC
LIMIT sqlc.arg(page_limit);

-- name: ListAIStudioImagesAt :many
-- Sayfa sınırında aynı created_at'li görseller (imleç yalnızca zaman
-- taşıdığı için hepsi aynı sayfada dönmeli, yoksa biri atlanırdı).
SELECT sqlc.embed(i), COALESCE(u.full_name, '')::text AS user_name
FROM ai_studio_images i
LEFT JOIN users u ON u.id = i.user_id
WHERE i.organization_id = sqlc.arg(organization_id) AND i.deleted_at IS NULL
  AND (sqlc.arg(all_users)::boolean OR i.user_id = sqlc.narg(user_id)::uuid)
  AND i.created_at = sqlc.arg(at)::timestamptz
ORDER BY i.id DESC;

-- name: ListAIStudioImageProjects :many
-- Görsellerin eklendiği projeler (fotoğrafı projede hâlâ duranlar). Proje
-- üyeliğinden muaf rol (all_projects) hepsini, diğerleri yalnızca üyesi
-- oldukları projeleri görür: başkasının eklediği projenin adı sızmasın.
SELECT l.studio_image_id, l.project_id, p.name AS project_name, l.project_photo_id
FROM ai_studio_image_projects l
JOIN ai_studio_images i ON i.id = l.studio_image_id
JOIN projects p ON p.id = l.project_id AND p.organization_id = i.organization_id
JOIN project_photos ph ON ph.id = l.project_photo_id AND ph.deleted_at IS NULL
WHERE l.studio_image_id = ANY(sqlc.arg(image_ids)::uuid[]) AND i.organization_id = sqlc.arg(organization_id)
  AND (sqlc.arg(all_projects)::boolean OR EXISTS (
        SELECT 1 FROM project_users pu
        WHERE pu.project_id = l.project_id AND pu.user_id = sqlc.narg(user_id)::uuid
          AND pu.organization_id = i.organization_id))
ORDER BY l.created_at, p.name;

-- name: GetAIStudioImage :one
SELECT * FROM ai_studio_images
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id) AND deleted_at IS NULL;

-- name: SoftDeleteAIStudioImage :execrows
-- any_user: Sahip/Yönetici başkasının görselini de siler; diğerleri yalnızca kendisininkini.
UPDATE ai_studio_images SET deleted_at = now(), deleted_by = sqlc.narg(deleted_by)
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id) AND deleted_at IS NULL
  AND (sqlc.arg(any_user)::boolean OR user_id = sqlc.narg(user_id)::uuid);

-- name: GetAIStudioSourcePhoto :one
-- Stüdyo işine kaynak olacak proje fotoğrafı: firma şartıyla; proje erişimi
-- handler'da (fotoğrafın projesine okuma izni) denetlenir.
SELECT * FROM project_photos
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id) AND deleted_at IS NULL;

-- name: GetAIStudioImageOrigin :one
-- Görselin kaynağı bir proje fotoğrafıysa o fotoğraf ve projesi (silinmiş
-- olsa da): aynı projeye eklenince galeri "kaynak: <tarih>" yazsın.
SELECT j.source_photo_id, src.project_id AS source_project_id
FROM ai_studio_images i
JOIN ai_image_jobs j ON j.id = i.job_id
LEFT JOIN project_photos src ON src.id = j.source_photo_id
WHERE i.id = sqlc.arg(id) AND i.organization_id = sqlc.arg(organization_id);

-- name: GetAIStudioImageProjectPhoto :one
-- "Projeye ekle" tekrarı: bağ var ve fotoğraf projede duruyorsa aynı fotoğraf döner.
SELECT l.project_photo_id
FROM ai_studio_image_projects l
JOIN project_photos ph ON ph.id = l.project_photo_id AND ph.deleted_at IS NULL
WHERE l.studio_image_id = sqlc.arg(studio_image_id) AND l.project_id = sqlc.arg(project_id);

-- name: UpsertAIStudioImageProject :exec
-- Fotoğraf projeden silindikten sonra yeniden eklenince bağ yeni fotoğrafa taşınır.
INSERT INTO ai_studio_image_projects (studio_image_id, project_id, project_photo_id, added_by)
VALUES (sqlc.arg(studio_image_id), sqlc.arg(project_id), sqlc.arg(project_photo_id), sqlc.narg(added_by))
ON CONFLICT (studio_image_id, project_id) DO UPDATE
SET project_photo_id = EXCLUDED.project_photo_id, added_by = EXCLUDED.added_by, created_at = now();
