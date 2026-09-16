-- ARVEND V2 -- Sprint 3: Proje Sözleşmesi (Contract). Durum makinesi:
-- draft -> active -> completed; draft -> cancelled; active -> terminated.
-- Tüm geçiş sorguları, project_change_orders'daki SendChangeOrder/
-- RespondChangeOrderByShareLinkToken İLE AYNI "durum-korumalı UPDATE"
-- desenini kullanır (WHERE status='<beklenen>') -- eşzamanlı çift geçiş
-- Postgres satır kilidiyle serileşir, ikinci çağrı 0 satır alır.

-- name: CreateProjectContract :one
INSERT INTO project_contracts (organization_id, project_id, currency, created_by)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: GetProjectContract :one
SELECT * FROM project_contracts WHERE project_id = $1 AND organization_id = $2;

-- name: GetProjectContractForUpdate :one
SELECT * FROM project_contracts WHERE id = $1 AND organization_id = $2 AND project_id = $3 FOR UPDATE;

-- name: UpdateProjectContractDraftFields :one
UPDATE project_contracts
SET scope = $4, payment_terms = $5, retention_terms = $6, advance_terms = $7,
    effective_date = $8, planned_completion_date = $9
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- name: UpdateProjectContractNotes :one
UPDATE project_contracts
SET internal_notes = $4
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status IN ('draft', 'active')
RETURNING *;

-- name: ActivateProjectContract :one
UPDATE project_contracts
SET status = 'active', activated_at = now(), activated_by = $4
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- name: CancelProjectContract :one
UPDATE project_contracts
SET status = 'cancelled', cancelled_at = now(), cancelled_by = $4, cancel_reason = $5
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- name: CompleteProjectContract :one
UPDATE project_contracts
SET status = 'completed', completed_at = now(), completed_by = $4
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'active'
RETURNING *;

-- name: TerminateProjectContract :one
UPDATE project_contracts
SET status = 'terminated', terminated_at = now(), terminated_by = $4, termination_reason = $5
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'active'
RETURNING *;
