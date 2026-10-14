-- Proje silme (migration 0070). Silinebilir proje: para hareketi ve satın
-- alma / taşeron sözleşmesi kaydı OLMAYAN proje (iptal edilmiş kayıtlar da
-- sayılır -- denetim izidir). Görev, not, fotoğraf, dosya, ödeme planı, ek
-- iş, bütçe/WBS, sözleşme, ekip ve hareketler projeyle birlikte silinir.

-- name: CountProjectDeleteBlockers :one
SELECT
    (SELECT count(*) FROM project_collections WHERE project_id = sqlc.arg(project_id)::uuid)::int AS collections,
    (SELECT count(*) FROM project_expenses WHERE project_id = sqlc.arg(project_id)::uuid)::int AS expenses,
    (SELECT count(*) FROM project_subcontractor_payments WHERE project_id = sqlc.arg(project_id)::uuid)::int AS subcontractor_payments,
    (SELECT count(*) FROM subcontract_payments WHERE project_id = sqlc.arg(project_id)::uuid)::int AS subcontract_payments,
    (SELECT count(*) FROM project_invoices WHERE project_id = sqlc.arg(project_id)::uuid)::int AS invoices,
    (SELECT count(*) FROM purchase_requests WHERE project_id = sqlc.arg(project_id)::uuid)::int AS purchase_requests,
    (SELECT count(*) FROM rfqs WHERE project_id = sqlc.arg(project_id)::uuid)::int AS rfqs,
    (SELECT count(*) FROM purchase_orders WHERE project_id = sqlc.arg(project_id)::uuid)::int AS purchase_orders,
    (SELECT count(*) FROM project_subcontracts WHERE project_id = sqlc.arg(project_id)::uuid)::int AS subcontracts;

-- name: ListProjectObjectKeys :many
-- Silinen projenin depodaki dosya ve fotoğrafları (işlem bittikten sonra
-- depodan da silinir).
SELECT object_key FROM project_files WHERE project_id = sqlc.arg(project_id)::uuid
UNION ALL
SELECT object_key FROM project_photos WHERE project_id = sqlc.arg(project_id)::uuid;

-- Projeye CASCADE ile bağlı OLMAYAN planlama kayıtları -- sırayla silinir
-- (tahmin/taahhüt -> revizyon -> kalem -> bütçe -> WBS, sözleşme).

-- name: DeleteProjectCostForecasts :exec
DELETE FROM project_cost_forecasts WHERE project_id = $1 AND organization_id = $2;

-- name: DeleteProjectCommitments :exec
DELETE FROM project_commitments WHERE project_id = $1 AND organization_id = $2;

-- name: DeleteProjectBudgetAdjustments :exec
DELETE FROM project_budget_adjustments WHERE project_id = $1 AND organization_id = $2;

-- name: DeleteProjectBudgetLines :exec
DELETE FROM project_budget_lines WHERE project_id = $1 AND organization_id = $2;

-- name: DeleteProjectBudgets :exec
DELETE FROM project_budgets WHERE project_id = $1 AND organization_id = $2;

-- name: DeleteProjectWBSNodes :exec
-- Tek ifade: üst/alt düğüm bağı (parent_id) ifade sonunda denetlenir.
DELETE FROM project_wbs_nodes WHERE project_id = $1 AND organization_id = $2;

-- name: DeleteProjectContracts :exec
DELETE FROM project_contracts WHERE project_id = $1 AND organization_id = $2;

-- name: DeleteProjectRow :execrows
-- Görevler, notlar, dosya/fotoğraf kayıtları, ödeme planı, ek işler, ekip,
-- hareketler, basit taşeron kayıtları, bildirimler ve silme talebi CASCADE.
DELETE FROM projects WHERE id = $1 AND organization_id = $2;

-- ---------- Silme talebi ----------

-- name: CreateProjectDeleteRequest :one
INSERT INTO project_delete_requests (organization_id, project_id, requested_by, reason)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: GetPendingProjectDeleteRequest :one
SELECT r.*, COALESCE(u.full_name, '')::text AS requested_by_name
FROM project_delete_requests r
LEFT JOIN users u ON u.id = r.requested_by
WHERE r.project_id = $1 AND r.organization_id = $2 AND r.status = 'pending';

-- name: GetPendingProjectDeleteRequestForUpdate :one
SELECT * FROM project_delete_requests
WHERE project_id = $1 AND organization_id = $2 AND status = 'pending'
FOR UPDATE;

-- name: DecideProjectDeleteRequest :one
UPDATE project_delete_requests
SET status = sqlc.arg(status), decided_by = sqlc.narg(decided_by), decided_at = now(),
    decision_note = sqlc.arg(decision_note)
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id) AND status = 'pending'
RETURNING *;

-- name: ListPendingProjectDeleteRequests :many
SELECT r.id, r.project_id, r.reason, r.created_at, r.requested_by,
       COALESCE(u.full_name, '')::text AS requested_by_name,
       p.project_no, p.name AS project_name, p.customer_name
FROM project_delete_requests r
JOIN projects p ON p.id = r.project_id
LEFT JOIN users u ON u.id = r.requested_by
WHERE r.organization_id = $1 AND r.status = 'pending'
ORDER BY r.created_at, r.id;
