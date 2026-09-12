-- name: NextProjectSeq :one
INSERT INTO project_counters (organization_id, year, seq) VALUES ($1, $2, 1)
ON CONFLICT (organization_id, year) DO UPDATE SET seq = project_counters.seq + 1
RETURNING seq;

-- name: CreateProject :one
INSERT INTO projects (
    organization_id, project_no, name, project_type, source_offer_id, source_revision_id,
    customer_id, customer_name, customer_phone, customer_email, customer_address,
    contract_amount, currency, status, start_date, end_date, description, internal_notes, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19)
RETURNING *;

-- name: GetProjectByID :one
SELECT * FROM projects WHERE id = $1 AND organization_id = $2;

-- name: GetProjectBySourceRevision :one
SELECT * FROM projects WHERE source_revision_id = $1 AND organization_id = $2;

-- name: GetProjectBySourceOffer :one
SELECT * FROM projects WHERE source_offer_id = $1 AND organization_id = $2
ORDER BY created_at DESC LIMIT 1;

-- name: ListProjects :many
SELECT p.*, o.offer_no, r.revision_no
FROM projects p
JOIN offers o ON o.id = p.source_offer_id
JOIN offer_revisions r ON r.id = p.source_revision_id
WHERE p.organization_id = $1
  AND (sqlc.narg('status')::varchar IS NULL OR p.status = sqlc.narg('status')::varchar)
  AND (sqlc.narg('customer_id')::uuid IS NULL OR p.customer_id = sqlc.narg('customer_id')::uuid)
  AND (sqlc.narg('project_type')::varchar IS NULL OR p.project_type = sqlc.narg('project_type')::varchar)
  AND (sqlc.narg('currency')::varchar IS NULL OR p.currency = sqlc.narg('currency')::varchar)
  AND (sqlc.narg('start_from')::date IS NULL OR p.start_date >= sqlc.narg('start_from')::date)
  AND (sqlc.narg('search')::varchar IS NULL
       OR p.name ILIKE '%' || sqlc.narg('search')::varchar || '%'
       OR p.project_no ILIKE '%' || sqlc.narg('search')::varchar || '%'
       OR p.customer_name ILIKE '%' || sqlc.narg('search')::varchar || '%')
ORDER BY p.created_at DESC
LIMIT $2 OFFSET $3;

-- name: CountProjects :one
SELECT count(*) FROM projects p
WHERE p.organization_id = $1
  AND (sqlc.narg('status')::varchar IS NULL OR p.status = sqlc.narg('status')::varchar)
  AND (sqlc.narg('customer_id')::uuid IS NULL OR p.customer_id = sqlc.narg('customer_id')::uuid)
  AND (sqlc.narg('project_type')::varchar IS NULL OR p.project_type = sqlc.narg('project_type')::varchar)
  AND (sqlc.narg('currency')::varchar IS NULL OR p.currency = sqlc.narg('currency')::varchar)
  AND (sqlc.narg('start_from')::date IS NULL OR p.start_date >= sqlc.narg('start_from')::date)
  AND (sqlc.narg('search')::varchar IS NULL
       OR p.name ILIKE '%' || sqlc.narg('search')::varchar || '%'
       OR p.project_no ILIKE '%' || sqlc.narg('search')::varchar || '%'
       OR p.customer_name ILIKE '%' || sqlc.narg('search')::varchar || '%');

-- UpdateProject, YALNIZCA kullanıcı tarafından değiştirilebilen alanları
-- günceller. project_no, source_offer_id, source_revision_id,
-- contract_amount, currency ve müşteri snapshot'ı bilinçli olarak burada
-- YOKTUR -- bunlar kaynak teklife ait dondurulmuş verilerdir.
-- name: UpdateProject :one
UPDATE projects
SET name = $3, project_type = $4, status = $5, start_date = $6, end_date = $7,
    description = $8, internal_notes = $9
WHERE id = $1 AND organization_id = $2
RETURNING *;
