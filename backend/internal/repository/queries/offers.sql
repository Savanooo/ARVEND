-- name: NextOfferSeq :one
INSERT INTO offer_counters (year, seq) VALUES ($1, 1)
ON CONFLICT (year) DO UPDATE SET seq = offer_counters.seq + 1
RETURNING seq;

-- name: CreateOffer :one
INSERT INTO offers (
    offer_no, customer_name, customer_phone, customer_email, customer_address,
    offer_date, valid_until, subtotal, vat_rate, vat_amount, grand_total,
    notes, status, created_by
) VALUES (
    $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14
)
RETURNING *;

-- name: CreateOfferItem :one
INSERT INTO offer_items (offer_id, product_id, product_name, quantity, unit_price, line_total, sort_order)
VALUES ($1, $2, $3, $4, $5, $6, $7)
RETURNING *;

-- name: GetOfferByID :one
SELECT * FROM offers WHERE id = $1;

-- name: ListOfferItems :many
SELECT * FROM offer_items WHERE offer_id = $1 ORDER BY sort_order ASC;

-- name: ListOffers :many
SELECT * FROM offers
WHERE is_passive = $1
ORDER BY created_at DESC
LIMIT $2 OFFSET $3;

-- name: CountOffers :one
SELECT count(*) FROM offers WHERE is_passive = $1;

-- name: UpdateOfferStatus :one
UPDATE offers SET status = $2 WHERE id = $1
RETURNING *;

-- name: SetOfferPassive :exec
UPDATE offers SET is_passive = $2 WHERE id = $1;

-- name: DeleteOffer :exec
DELETE FROM offers WHERE id = $1;
