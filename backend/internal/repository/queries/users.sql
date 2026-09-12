-- name: CreateUser :one
INSERT INTO users (organization_id, username, password_hash, full_name, role)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: GetUserByID :one
SELECT * FROM users WHERE id = $1;

-- name: GetUserByIDInOrg :one
SELECT * FROM users WHERE id = $1 AND organization_id = $2;

-- name: GetUserByUsername :one
SELECT * FROM users WHERE username = $1;

-- name: ListUsers :many
SELECT * FROM users
WHERE organization_id = $1
ORDER BY created_at DESC
LIMIT $2 OFFSET $3;

-- name: CountUsers :one
SELECT count(*) FROM users WHERE organization_id = $1;

-- name: CountActiveUsers :one
SELECT count(*) FROM users WHERE organization_id = $1 AND is_active = true;

-- name: UpdateUser :one
UPDATE users
SET full_name = $3, role = $4, is_active = $5
WHERE id = $1 AND organization_id = $2
RETURNING *;

-- name: UpdateUserPassword :execrows
UPDATE users SET password_hash = $3 WHERE id = $1 AND organization_id = $2;

-- name: TouchLastLogin :exec
UPDATE users SET last_login_at = now() WHERE id = $1;

-- name: DeactivateUser :execrows
UPDATE users SET is_active = false WHERE id = $1 AND organization_id = $2;
