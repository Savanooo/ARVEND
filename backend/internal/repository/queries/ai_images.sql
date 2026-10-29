-- Yapay zekâ görsel işleri (migration 0079; bkz. service/ai_image_service.go).

-- name: AIImageQuotaXactLock :exec
-- Firma başına sayım + ekleme tek sırada: aynı anda gelen iki istek aylık
-- sınırı birlikte aşamasın.
SELECT pg_advisory_xact_lock(sqlc.arg(lock_class)::int, hashtext(sqlc.arg(lock_key)::text));

-- name: CountOrgAIImageJobsSince :one
-- Aylık sınır: başarısız işler sayılmaz (OpenAI'de ücretlenmez); sırada ve
-- çalışan işler sayılır (sıraya yığarak sınır aşılmasın).
SELECT count(*)::int FROM ai_image_jobs
WHERE organization_id = sqlc.arg(organization_id) AND created_at >= sqlc.arg(since)::timestamptz
  AND status <> 'failed';

-- name: CountUserAIImageJobsSince :one
-- Kişi başı saatlik sınır: bütün işler (art arda hata alan istekler de).
SELECT count(*)::int FROM ai_image_jobs
WHERE organization_id = sqlc.arg(organization_id) AND user_id = sqlc.arg(user_id)
  AND created_at >= sqlc.arg(since)::timestamptz;

-- name: CountUserActiveAIImageJobs :one
SELECT count(*)::int FROM ai_image_jobs
WHERE organization_id = sqlc.arg(organization_id) AND user_id = sqlc.arg(user_id)
  AND status IN ('queued', 'running');

-- name: CreateAIImageJob :one
INSERT INTO ai_image_jobs (organization_id, project_id, user_id, kind, prompt, source_photo_id, model)
VALUES (sqlc.arg(organization_id), sqlc.arg(project_id), sqlc.arg(user_id), sqlc.arg(kind),
        sqlc.arg(prompt), sqlc.narg(source_photo_id), sqlc.arg(model))
RETURNING *;

-- name: GetAIImageJob :one
-- İşi yalnızca açan kişi görür; firma + proje şartı başka firmanın ya da
-- başka projenin iş kimliğini bilse bile okunmasını engeller.
SELECT * FROM ai_image_jobs
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id)
  AND project_id = sqlc.arg(project_id) AND user_id = sqlc.arg(user_id);

-- name: ListUserProjectAIImageJobs :many
SELECT * FROM ai_image_jobs
WHERE organization_id = sqlc.arg(organization_id) AND project_id = sqlc.arg(project_id)
  AND user_id = sqlc.arg(user_id)
ORDER BY created_at DESC
LIMIT 20;

-- name: ClaimNextAIImageJob :one
-- Sıradaki işi (en eskisi) çalışıyor olarak alır. SKIP LOCKED: aynı anda
-- çalışan işçiler aynı işi almaz. organization_id NULL = bütün firmalar
-- (üretim); dolu = yalnızca o firma (aynı veritabanını paylaşan paralel
-- test paketleri birbirinin işini almasın).
UPDATE ai_image_jobs SET status = 'running', started_at = now()
WHERE id = (
    SELECT id FROM ai_image_jobs
    WHERE status = 'queued'
      AND (sqlc.narg(organization_id)::uuid IS NULL OR organization_id = sqlc.narg(organization_id)::uuid)
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT 1
)
RETURNING *;

-- name: CompleteAIImageJob :exec
UPDATE ai_image_jobs SET status = 'done', result_photo_id = sqlc.arg(result_photo_id), error = '', finished_at = now()
WHERE id = sqlc.arg(id) AND status = 'running';

-- name: FailAIImageJob :exec
UPDATE ai_image_jobs SET status = 'failed', error = sqlc.arg(error), finished_at = now()
WHERE id = sqlc.arg(id) AND status IN ('queued', 'running');

-- name: FailInterruptedAIImageJobs :execrows
-- Sunucu açılışı: önceki süreçte sırada/çalışırken kalan işler sonsuza dek
-- "hazırlanıyor" görünmesin. Tek sunucu varsayımı (bkz. servis notu).
UPDATE ai_image_jobs SET status = 'failed', error = sqlc.arg(error), finished_at = now()
WHERE status IN ('queued', 'running')
  AND (sqlc.narg(organization_id)::uuid IS NULL OR organization_id = sqlc.narg(organization_id)::uuid);

-- name: ListOrgAIImageUsageByUser :many
-- Bu ay kim kaç görsel üretti (Sahip/Yönetici görür); aylık sınırla aynı sayım.
SELECT j.user_id, COALESCE(u.full_name, '')::text AS full_name, count(*)::int AS images
FROM ai_image_jobs j
LEFT JOIN users u ON u.id = j.user_id
WHERE j.organization_id = sqlc.arg(organization_id) AND j.created_at >= sqlc.arg(since)::timestamptz
  AND j.status <> 'failed'
GROUP BY j.user_id, u.full_name
ORDER BY images DESC, full_name;
