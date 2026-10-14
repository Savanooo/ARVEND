-- name: CreateOfferDeleteRequest :one
INSERT INTO offer_delete_requests (organization_id, offer_id, requested_by, reason)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: GetPendingOfferDeleteRequest :one
SELECT r.*, COALESCE(u.full_name, '')::text AS requested_by_name
FROM offer_delete_requests r
LEFT JOIN users u ON u.id = r.requested_by
WHERE r.offer_id = $1 AND r.organization_id = $2 AND r.status = 'pending';

-- name: GetPendingOfferDeleteRequestForUpdate :one
SELECT * FROM offer_delete_requests
WHERE offer_id = $1 AND organization_id = $2 AND status = 'pending'
FOR UPDATE;

-- name: DecideOfferDeleteRequest :one
UPDATE offer_delete_requests
SET status = sqlc.arg(status), decided_by = sqlc.arg(decided_by), decided_at = now(),
    decision_note = sqlc.arg(decision_note)
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id) AND status = 'pending'
RETURNING *;

-- name: ListPendingOfferDeleteRequests :many
-- Onay bekleyen silme talepleri, en eskisi önce (ana sayfa + liste).
SELECT r.id, r.offer_id, r.reason, r.created_at, r.requested_by,
       COALESCE(u.full_name, '')::text AS requested_by_name,
       o.offer_no, rev.customer_name, rev.grand_total, rev.currency
FROM offer_delete_requests r
JOIN offers o ON o.id = r.offer_id
JOIN offer_revisions rev ON rev.id = o.current_revision_id
LEFT JOIN users u ON u.id = r.requested_by
WHERE r.organization_id = $1 AND r.status = 'pending'
ORDER BY r.created_at, r.id;

-- name: ListPendingOfferDeleteRequestOfferIDs :many
-- Teklif listesinde "Silme bekliyor" etiketi için (yalnızca sayfadaki
-- teklifler sorulur).
SELECT offer_id FROM offer_delete_requests
WHERE organization_id = $1 AND status = 'pending' AND offer_id = ANY(sqlc.arg(offer_ids)::uuid[]);
