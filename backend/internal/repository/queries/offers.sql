-- name: NextOfferSeq :one
INSERT INTO offer_counters (organization_id, year, seq) VALUES ($1, $2, 1)
ON CONFLICT (organization_id, year) DO UPDATE SET seq = offer_counters.seq + 1
RETURNING seq;

-- name: CreateOffer :one
INSERT INTO offers (organization_id, offer_no, status, created_by)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: SetOfferCurrentRevision :exec
UPDATE offers SET current_revision_id = $2, status = $3 WHERE id = $1;

-- name: GetOfferByID :one
SELECT * FROM offers WHERE id = $1 AND organization_id = $2;

-- name: GetOfferByShareToken :one
SELECT * FROM offers WHERE share_token = $1;

-- name: ListOffers :many
SELECT o.*, r.customer_name, r.grand_total, r.revision_no
FROM offers o
JOIN offer_revisions r ON r.id = o.current_revision_id
WHERE o.organization_id = $1 AND o.is_passive = $2
ORDER BY o.created_at DESC
LIMIT $3 OFFSET $4;

-- name: CountOffers :one
SELECT count(*) FROM offers WHERE organization_id = $1 AND is_passive = $2;

-- name: SetOfferPassive :exec
UPDATE offers SET is_passive = $3 WHERE id = $1 AND organization_id = $2;

-- name: DeleteOffer :exec
DELETE FROM offers WHERE id = $1 AND organization_id = $2;
