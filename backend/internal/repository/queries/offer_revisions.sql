-- name: CreateOfferRevision :one
INSERT INTO offer_revisions (
    organization_id, offer_id, revision_no, customer_id, customer_name, customer_phone,
    customer_email, customer_address, valid_until, subtotal, discount_type, discount_value,
    discount_amount, vat_rate, vat_amount, grand_total, currency, notes, status, created_by
) VALUES (
    $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20
)
RETURNING *;

-- name: GetOfferRevisionByID :one
SELECT * FROM offer_revisions WHERE id = $1 AND organization_id = $2;

-- name: GetLatestRevisionNo :one
SELECT COALESCE(MAX(revision_no), -1)::int FROM offer_revisions WHERE offer_id = $1;

-- name: ListOfferRevisions :many
SELECT * FROM offer_revisions WHERE offer_id = $1 AND organization_id = $2 ORDER BY revision_no DESC;

-- name: UpdateOfferRevision :one
UPDATE offer_revisions
SET customer_id = $3, customer_name = $4, customer_phone = $5, customer_email = $6,
    customer_address = $7, valid_until = $8, subtotal = $9, vat_rate = $10,
    vat_amount = $11, grand_total = $12, notes = $13
WHERE id = $1 AND organization_id = $2 AND status = 'taslak'
RETURNING *;

-- name: UpdateOfferRevisionStatus :one
UPDATE offer_revisions SET status = $3 WHERE id = $1 AND organization_id = $2
RETURNING *;

-- name: CreateOfferRevisionItem :one
-- unit/section_label/calc_category_id/calc_snapshot: Metraj Hesaplama
-- entegrasyonu (Faz M2) -- serbest/elle girilen kalemlerde hepsi boş/NULL
-- kalır. calc_snapshot bir kez yazılır, offer_revisions ilkesiyle AYNI
-- şekilde bir daha ASLA güncellenmez (yeni revizyon = yeni satır).
INSERT INTO offer_revision_items (
    revision_id, product_id, product_name, quantity, unit_price, discount_type, discount_value,
    line_total, sort_order, unit, section_label, calc_category_id, calc_snapshot
)
VALUES (
    sqlc.arg(revision_id), sqlc.arg(product_id), sqlc.arg(product_name), sqlc.arg(quantity),
    sqlc.arg(unit_price), sqlc.arg(discount_type), sqlc.arg(discount_value), sqlc.arg(line_total),
    sqlc.arg(sort_order), sqlc.arg(unit), sqlc.narg(section_label), sqlc.narg(calc_category_id),
    sqlc.narg(calc_snapshot)
)
RETURNING *;

-- name: ListOfferRevisionItems :many
SELECT * FROM offer_revision_items WHERE revision_id = $1 ORDER BY sort_order ASC;

-- name: DeleteOfferRevisionItems :exec
DELETE FROM offer_revision_items WHERE revision_id = $1;
