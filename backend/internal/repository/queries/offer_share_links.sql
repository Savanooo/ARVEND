-- name: CreateShareLink :one
INSERT INTO offer_share_links (organization_id, offer_id, revision_id, created_by, expires_at)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: GetShareLinkByToken :one
SELECT * FROM offer_share_links WHERE token = $1;

-- name: ListShareLinksByOffer :many
SELECT * FROM offer_share_links WHERE offer_id = $1 AND organization_id = $2 ORDER BY created_at DESC;

-- name: RevokeShareLink :one
UPDATE offer_share_links SET revoked_at = now()
WHERE id = $1 AND organization_id = $2 AND revoked_at IS NULL
RETURNING *;

-- name: RevokeShareLinksForOtherRevisions :many
UPDATE offer_share_links SET revoked_at = now()
WHERE offer_id = $1 AND revision_id <> $2 AND revoked_at IS NULL
RETURNING *;
