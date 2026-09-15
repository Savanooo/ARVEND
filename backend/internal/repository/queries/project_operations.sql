-- ============ Ekip ============

-- name: CreateProjectMember :one
INSERT INTO project_members (
    organization_id, project_id, employee_id, employee_name, role_title,
    start_date, end_date, notes, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
RETURNING *;

-- name: ListProjectMembers :many
SELECT * FROM project_members
WHERE project_id = $1 AND organization_id = $2
ORDER BY (end_date IS NOT NULL), created_at ASC;

-- name: GetProjectMember :one
-- project_id EKLENDİ: başka bir projenin üye UUID'si, aynı organizasyon
-- içinde bile olsa buradan görüntülenemez (bkz. IDOR denetim bulgusu --
-- child-resource sorguları yalnızca organization_id ile değil, ebeveyn
-- project_id ile de sınırlanmalı).
SELECT * FROM project_members WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- EndProjectMembership, üyeyi SİLMEZ: bitiş tarihi yazılır, geçmiş kayıt
-- korunur (aynı kişi sonra yeniden atanabilir). project_id EKLENDİ (bkz.
-- GetProjectMember notu).
-- name: EndProjectMembership :one
UPDATE project_members SET end_date = $3
WHERE id = $1 AND organization_id = $2 AND end_date IS NULL AND project_id = $4
RETURNING *;

-- ============ Planlama ============

-- name: CreateScheduleItem :one
INSERT INTO project_schedule_items (
    organization_id, project_id, name, description, start_date, end_date, status, sort_order, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
RETURNING *;

-- ListScheduleItems, her aşamanın görev sayılarını da getirir (aşama
-- başına ayrı sorgu yok).
-- name: ListScheduleItems :many
SELECT s.*,
       COALESCE((SELECT count(*) FROM project_tasks t
                 WHERE t.schedule_item_id = s.id AND t.status <> 'cancelled'), 0)::bigint AS task_count,
       COALESCE((SELECT count(*) FROM project_tasks t
                 WHERE t.schedule_item_id = s.id AND t.status = 'completed'), 0)::bigint AS completed_task_count
FROM project_schedule_items s
WHERE s.project_id = $1 AND s.organization_id = $2
ORDER BY s.sort_order ASC, s.start_date ASC NULLS LAST, s.created_at ASC;

-- name: GetScheduleItem :one
-- project_id EKLENDİ (bkz. GetProjectMember notu). resolveTaskRelations'ın
-- kendi çapraz-doğrulaması (item.ProjectID == pid) korunur; bu sorgu
-- seviyesindeki ek katman savunma derinliğidir.
SELECT * FROM project_schedule_items WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- name: UpdateScheduleItem :one
UPDATE project_schedule_items
SET name = $3, description = $4, start_date = $5, end_date = $6, status = $7, sort_order = $8
WHERE id = $1 AND organization_id = $2 AND project_id = $9
RETURNING *;

-- ============ Görevler ============

-- name: CreateTask :one
INSERT INTO project_tasks (
    organization_id, project_id, schedule_item_id, title, description,
    assigned_employee_id, assigned_name, priority, status, due_date, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
RETURNING *;

-- name: ListTasks :many
SELECT * FROM project_tasks
WHERE project_id = $1 AND organization_id = $2
ORDER BY (status = 'completed' OR status = 'cancelled'),
         due_date ASC NULLS LAST, created_at ASC;

-- name: GetTask :one
-- project_id EKLENDİ (bkz. GetProjectMember notu -- IDOR denetim bulgusu:
-- taskId + BAŞKA projenin id'si ile GetTask öncesi org_id eşleşse bile
-- kayıt dönerdi).
SELECT * FROM project_tasks WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- GetTaskForUpdate, satırı KİLİT ALTINDA okur. UpdateTask bunu kullanır:
-- aksi halde iki eşzamanlı "durumu completed yap" isteği ikisi de eski
-- (completed öncesi) durumu görüp İKİ kez task_completed olayı
-- yazabilirdi (bkz. denetim bulgusu). project_id EKLENDİ (bkz. GetTask notu).
-- name: GetTaskForUpdate :one
SELECT * FROM project_tasks WHERE id = $1 AND organization_id = $2 AND project_id = $3 FOR UPDATE;

-- UpdateTask, completed_at'i durumla TUTARLI yazar: tamamlandıysa o anki
-- zaman, değilse NULL (DB'deki CHECK kısıtı da bunu zorunlu kılar).
-- project_id EKLENDİ (bkz. GetTask notu).
-- name: UpdateTask :one
UPDATE project_tasks
SET title = $3, description = $4, schedule_item_id = $5, assigned_employee_id = $6,
    assigned_name = $7, priority = $8, status = $9, due_date = $10,
    completed_at = CASE WHEN $9::varchar = 'completed'
                        THEN COALESCE(completed_at, now())
                        ELSE NULL END
WHERE id = $1 AND organization_id = $2 AND project_id = $11
RETURNING *;

-- CompleteTask, görevi yalnızca HENÜZ tamamlanmamışsa tamamlar. Eşzamanlı
-- iki "tamamla" isteğinden yalnızca biri satır döndürür; ikincisi sessizce
-- ikinci kez tamamlamak yerine hiçbir şey yapmaz (idempotent davranış).
-- project_id EKLENDİ (bkz. GetTask notu).
-- name: CompleteTask :one
UPDATE project_tasks
SET status = 'completed', completed_at = now()
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status <> 'completed'
RETURNING *;

-- name: CountProjectTaskStats :one
SELECT
    COALESCE(count(*) FILTER (WHERE status <> 'cancelled'), 0)::bigint AS total,
    COALESCE(count(*) FILTER (WHERE status IN ('todo', 'in_progress')), 0)::bigint AS open_count,
    COALESCE(count(*) FILTER (WHERE status = 'completed'), 0)::bigint AS completed_count,
    COALESCE(count(*) FILTER (WHERE status IN ('todo', 'in_progress')
                              AND due_date IS NOT NULL AND due_date < CURRENT_DATE), 0)::bigint AS overdue_count
FROM project_tasks WHERE project_id = $1 AND organization_id = $2;

-- name: CountActiveMembers :one
SELECT COALESCE(count(*), 0)::bigint FROM project_members
WHERE project_id = $1 AND organization_id = $2 AND end_date IS NULL;

-- ============ Dosyalar ============

-- name: CreateProjectFile :one
INSERT INTO project_files (
    organization_id, project_id, original_name, object_key, mime_type,
    size_bytes, sha256, category, description, uploaded_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
RETURNING *;

-- name: ListProjectFiles :many
SELECT * FROM project_files
WHERE project_id = $1 AND organization_id = $2 AND deleted_at IS NULL
ORDER BY created_at DESC;

-- GetProjectFile, indirme ucunun tek yetki kapısıdır: organization_id VE
-- project_id eşleşmeden hiçbir dosya döndürülmez (project_id EKLENDİ --
-- bkz. GetProjectMember notu: aksi halde AYNI organizasyondaki başka bir
-- projenin dosya UUID'si, yetkili olunan bir proje URL'siyle indirilebilirdi).
-- name: GetProjectFile :one
SELECT * FROM project_files
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND deleted_at IS NULL;

-- name: GetProjectFileBySHA :one
SELECT * FROM project_files
WHERE project_id = $1 AND sha256 = $2 AND deleted_at IS NULL;

-- name: SoftDeleteProjectFile :one
-- project_id EKLENDİ (bkz. GetProjectFile notu).
UPDATE project_files SET deleted_at = now(), deleted_by = $3
WHERE id = $1 AND organization_id = $2 AND project_id = $4 AND deleted_at IS NULL
RETURNING *;

-- ============ Fotoğraflar ============

-- name: CreateProjectPhoto :one
INSERT INTO project_photos (
    organization_id, project_id, original_name, object_key, mime_type,
    size_bytes, sha256, stage, description, taken_at, uploaded_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
RETURNING *;

-- name: ListProjectPhotos :many
SELECT * FROM project_photos
WHERE project_id = $1 AND organization_id = $2 AND deleted_at IS NULL
ORDER BY stage ASC, COALESCE(taken_at, created_at) DESC;

-- name: GetProjectPhoto :one
-- project_id EKLENDİ (bkz. GetProjectFile notu).
SELECT * FROM project_photos
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND deleted_at IS NULL;

-- name: GetProjectPhotoBySHA :one
SELECT * FROM project_photos
WHERE project_id = $1 AND sha256 = $2 AND deleted_at IS NULL;

-- name: SoftDeleteProjectPhoto :one
-- project_id EKLENDİ (bkz. GetProjectFile notu).
UPDATE project_photos SET deleted_at = now(), deleted_by = $3
WHERE id = $1 AND organization_id = $2 AND project_id = $4 AND deleted_at IS NULL
RETURNING *;

-- ============ Notlar ============

-- name: CreateProjectNote :one
INSERT INTO project_notes (organization_id, project_id, content, created_by, created_by_name)
VALUES ($1,$2,$3,$4,$5)
RETURNING *;

-- name: ListProjectNotes :many
SELECT * FROM project_notes
WHERE project_id = $1 AND organization_id = $2
ORDER BY created_at DESC;

-- name: UpdateProjectNote :one
-- project_id EKLENDİ (bkz. GetProjectMember notu).
UPDATE project_notes SET content = $3
WHERE id = $1 AND organization_id = $2 AND project_id = $4
RETURNING *;

-- name: DeleteProjectNote :execrows
-- project_id EKLENDİ (bkz. GetProjectMember notu).
DELETE FROM project_notes WHERE id = $1 AND organization_id = $2 AND project_id = $3;
