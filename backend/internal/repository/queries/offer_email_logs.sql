-- name: CreateEmailLog :one
INSERT INTO offer_email_logs (organization_id, offer_id, revision_id, share_link_id, recipient, subject, status, error_message, sent_by)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
RETURNING *;

-- name: ListEmailLogsByOffer :many
SELECT * FROM offer_email_logs WHERE offer_id = $1 AND organization_id = $2 ORDER BY sent_at DESC;
