-- name: InsertAuditEvent :one
INSERT INTO platform_audit_events (actor_user_id, action, target_organization_id, target_user_id, metadata)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: ListAuditEventsForOrganization :many
SELECT * FROM platform_audit_events
WHERE target_organization_id = $1
ORDER BY created_at DESC
LIMIT $2 OFFSET $3;

-- name: ListAuditEvents :many
SELECT * FROM platform_audit_events
ORDER BY created_at DESC
LIMIT $1 OFFSET $2;
