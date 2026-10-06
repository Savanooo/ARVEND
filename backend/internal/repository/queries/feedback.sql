-- name: CreateFeedbackMessage :one
INSERT INTO feedback_messages (organization_id, user_id, user_name, category, body, app_version)
VALUES ($1, $2, $3, $4, $5, $6)
RETURNING *;

-- name: ListFeedbackMessages :many
-- Super Admin listesi: en yeni önce; only_unread true ise yalnızca okunmamış.
SELECT f.*, o.name AS organization_name
FROM feedback_messages f
JOIN organizations o ON o.id = f.organization_id
WHERE (NOT sqlc.arg(only_unread)::bool OR f.read_at IS NULL)
ORDER BY f.created_at DESC
LIMIT sqlc.arg(max_rows)::int OFFSET sqlc.arg(skip_rows)::int;

-- name: CountFeedbackMessages :one
SELECT count(*) AS total, count(*) FILTER (WHERE read_at IS NULL) AS unread FROM feedback_messages;

-- name: MarkFeedbackMessageRead :execrows
UPDATE feedback_messages SET read_at = now() WHERE id = $1 AND read_at IS NULL;
