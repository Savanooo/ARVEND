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

-- name: ListOffers :many
-- customer_id: Müşteri detay ekranının "Teklifler" bölümü için --
-- projects.sql'deki ListProjects'in AYNI nullable-narg deseni (customer_id
-- IS NULL => filtresiz). offers tablosunun kendisinde customer_id YOK
-- (0018 migration'da kaldırıldı) -- canlı değer yalnızca current_revision
-- üzerinden erişilebilir, bu yüzden r.customer_id üzerinden filtrelenir.
SELECT o.*, r.customer_id, r.customer_name, r.grand_total, r.revision_no
FROM offers o
JOIN offer_revisions r ON r.id = o.current_revision_id
WHERE o.organization_id = $1 AND o.is_passive = $2
  AND (sqlc.narg('customer_id')::uuid IS NULL OR r.customer_id = sqlc.narg('customer_id')::uuid)
ORDER BY o.created_at DESC
LIMIT $3 OFFSET $4;

-- name: CountOffers :one
SELECT count(*) FROM offers o
JOIN offer_revisions r ON r.id = o.current_revision_id
WHERE o.organization_id = $1 AND o.is_passive = $2
  AND (sqlc.narg('customer_id')::uuid IS NULL OR r.customer_id = sqlc.narg('customer_id')::uuid);

-- name: SetOfferPassive :exec
UPDATE offers SET is_passive = $3 WHERE id = $1 AND organization_id = $2;

-- name: DeleteOffer :exec
DELETE FROM offers WHERE id = $1 AND organization_id = $2;
