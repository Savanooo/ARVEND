-- name: CreateUser :one
INSERT INTO users (username, password_hash, full_name, role)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: GetUserByID :one
SELECT * FROM users WHERE id = $1;

-- name: GetUserByUsername :one
SELECT * FROM users WHERE username = $1;

-- name: ListUsers :many
SELECT * FROM users
ORDER BY created_at DESC
LIMIT $1 OFFSET $2;

-- name: CountUsers :one
SELECT count(*) FROM users;

-- name: CountActiveUsers :one
SELECT count(*) FROM users WHERE is_active = true;

-- name: UpdateUser :one
UPDATE users
SET full_name = $2, role = $3, is_active = $4
WHERE id = $1
RETURNING *;

-- name: UpdateUserPassword :exec
UPDATE users SET password_hash = $2 WHERE id = $1;

-- name: TouchLastLogin :exec
UPDATE users SET last_login_at = now() WHERE id = $1;

-- name: DeactivateUser :exec
UPDATE users SET is_active = false WHERE id = $1;
