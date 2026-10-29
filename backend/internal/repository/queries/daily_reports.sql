-- Günlük şantiye raporu (migration 0071).

-- name: GetDailyReport :one
SELECT r.*,
       COALESCE(cu.full_name, '')::text AS created_by_name,
       COALESCE(su.full_name, '')::text AS submitted_by_name
FROM project_daily_reports r
LEFT JOIN users cu ON cu.id = r.created_by
LEFT JOIN users su ON su.id = r.submitted_by
WHERE r.project_id = $1 AND r.organization_id = $2 AND r.report_date = $3;

-- name: ListDailyReports :many
-- Projenin raporları, en yeni gün önce; liste satırı için taşeron kişi
-- toplamı ve o günün fotoğraf sayısı.
SELECT r.id, r.report_date, r.weather, r.temperature_c, r.own_workers, r.status, r.work_done,
       COALESCE(cu.full_name, '')::text AS created_by_name,
       COALESCE((SELECT sum(s.workers) FROM project_daily_report_subcontractors s WHERE s.report_id = r.id), 0)::int
           AS subcontractor_workers,
       (SELECT count(*) FROM project_photos ph
        WHERE ph.project_id = r.project_id AND ph.deleted_at IS NULL AND NOT ph.ai_generated
          AND (ph.created_at AT TIME ZONE 'Europe/Istanbul')::date = r.report_date)::int AS photo_count
FROM project_daily_reports r
LEFT JOIN users cu ON cu.id = r.created_by
WHERE r.project_id = sqlc.arg(project_id) AND r.organization_id = sqlc.arg(organization_id)
ORDER BY r.report_date DESC
LIMIT sqlc.arg(row_limit)::int;

-- name: UpsertDailyReport :one
INSERT INTO project_daily_reports (
    organization_id, project_id, report_date, weather, temperature_c, own_workers,
    work_done, issues, materials, notes, created_by, updated_by
) VALUES (
    sqlc.arg(organization_id), sqlc.arg(project_id), sqlc.arg(report_date), sqlc.arg(weather),
    sqlc.narg(temperature_c), sqlc.arg(own_workers), sqlc.arg(work_done), sqlc.arg(issues),
    sqlc.arg(materials), sqlc.arg(notes), sqlc.narg(actor), sqlc.narg(actor)
)
ON CONFLICT (project_id, report_date) DO UPDATE
SET weather = EXCLUDED.weather, temperature_c = EXCLUDED.temperature_c, own_workers = EXCLUDED.own_workers,
    work_done = EXCLUDED.work_done, issues = EXCLUDED.issues, materials = EXCLUDED.materials,
    notes = EXCLUDED.notes, updated_by = EXCLUDED.updated_by
RETURNING *;

-- name: DeleteDailyReportSubcontractors :exec
DELETE FROM project_daily_report_subcontractors WHERE report_id = $1;

-- name: AddDailyReportSubcontractor :exec
INSERT INTO project_daily_report_subcontractors (report_id, organization_id, supplier_id, workers, work_note)
VALUES ($1, $2, $3, $4, $5);

-- name: ListDailyReportSubcontractors :many
SELECT s.supplier_id, s.workers, s.work_note, sup.legal_name, sup.specialty
FROM project_daily_report_subcontractors s
JOIN suppliers sup ON sup.id = s.supplier_id
WHERE s.report_id = $1
ORDER BY sup.legal_name;

-- name: SubmitDailyReport :one
UPDATE project_daily_reports
SET status = 'submitted', submitted_at = now(), submitted_by = sqlc.narg(actor), updated_by = sqlc.narg(actor)
WHERE project_id = sqlc.arg(project_id) AND organization_id = sqlc.arg(organization_id)
  AND report_date = sqlc.arg(report_date) AND status = 'draft'
RETURNING *;

-- name: DailyReportOwnWorkersSuggestion :one
-- Projenin ekibinden (project_members, o gün ekipte olanlar) o gün puantajı
-- "geldi" ya da "yarım gün" olanların sayısı -- formdaki öneri.
SELECT count(DISTINCT m.employee_id)::int AS workers
FROM project_members m
JOIN attendance_logs a ON a.employee_id = m.employee_id AND a.date = sqlc.arg(report_date)::date
WHERE m.project_id = sqlc.arg(project_id) AND m.organization_id = sqlc.arg(organization_id)
  AND (m.start_date IS NULL OR m.start_date <= sqlc.arg(report_date)::date)
  AND (m.end_date IS NULL OR m.end_date >= sqlc.arg(report_date)::date)
  AND a.status IN ('geldi', 'yarım gün');

-- name: ListTasksCompletedOn :many
SELECT id, title, assigned_name
FROM project_tasks
WHERE project_id = sqlc.arg(project_id) AND organization_id = sqlc.arg(organization_id)
  AND status = 'completed'
  AND (completed_at AT TIME ZONE 'Europe/Istanbul')::date = sqlc.arg(report_date)::date
ORDER BY completed_at;

-- name: ListPhotosTakenOn :many
-- Yapay zekâ görselleri (migration 0079) günlük rapora girmez: rapor
-- şantiyenin gerçek kaydıdır, üretilmiş görsel değil.
SELECT id, object_key, mime_type, stage, description, original_name
FROM project_photos
WHERE project_id = sqlc.arg(project_id) AND organization_id = sqlc.arg(organization_id)
  AND deleted_at IS NULL AND NOT ai_generated
  AND (created_at AT TIME ZONE 'Europe/Istanbul')::date = sqlc.arg(report_date)::date
ORDER BY created_at;

-- name: ListSubcontractorSiteDays :many
-- Taşeronun sahada çalıştığı günler (günlük raporlardan), en yeni önce.
SELECT r.report_date, r.project_id, p.name AS project_name, p.project_no, s.workers, s.work_note
FROM project_daily_report_subcontractors s
JOIN project_daily_reports r ON r.id = s.report_id
JOIN projects p ON p.id = r.project_id
WHERE s.organization_id = sqlc.arg(organization_id)::uuid AND s.supplier_id = sqlc.arg(supplier_id)::uuid
  AND (sqlc.narg(restrict_to_user_id)::uuid IS NULL OR EXISTS (
       SELECT 1 FROM project_users pu WHERE pu.project_id = r.project_id AND pu.user_id = sqlc.narg(restrict_to_user_id)::uuid))
ORDER BY r.report_date DESC
LIMIT 90;

-- name: ListDailyReportSubcontractorOptions :many
-- Rapor formunun taşeron seçenekleri: bu projeye bağlı (basit kayıt ya da
-- sözleşme, iptal edilmemiş) ya da projenin önceki raporlarında geçen aktif
-- kartlar. Saha şefinin tedarikçi okuma izni yok -- seçici buradan dolar.
SELECT sup.id, sup.legal_name, sup.specialty
FROM suppliers sup
WHERE sup.organization_id = sqlc.arg(organization_id)::uuid AND sup.is_active
  AND (EXISTS (SELECT 1 FROM project_subcontractors s
               WHERE s.supplier_id = sup.id AND s.project_id = sqlc.arg(project_id)::uuid AND s.status <> 'cancelled')
    OR EXISTS (SELECT 1 FROM project_subcontracts c
               WHERE c.supplier_id = sup.id AND c.project_id = sqlc.arg(project_id)::uuid AND c.status NOT IN ('cancelled', 'terminated'))
    OR EXISTS (SELECT 1 FROM project_daily_report_subcontractors d
               JOIN project_daily_reports r ON r.id = d.report_id
               WHERE d.supplier_id = sup.id AND r.project_id = sqlc.arg(project_id)::uuid))
ORDER BY sup.legal_name;
