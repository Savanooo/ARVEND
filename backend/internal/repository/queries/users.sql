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

-- name: CreateUserWithOptions :one
-- Platform seviyesi kullanıcı oluşturma (Super Admin CLI: organization_id
-- NULL, role='super_admin') VE Super Admin'in yeni firma için provision
-- ettiği ilk Owner (organization_id dolu, must_change_password=true) --
-- CreateUser'ın aksine her iki alan da parametreli.
INSERT INTO users (organization_id, username, password_hash, full_name, role, must_change_password)
VALUES ($1, $2, $3, $4, $5, $6)
RETURNING *;

-- name: SetPasswordAndClearMustChange :execrows
-- İlk giriş "şifre belirle" akışı: parolayı değiştirir VE
-- must_change_password bayrağını temizler, tek sorguda.
UPDATE users SET password_hash = $3, must_change_password = false
WHERE id = $1 AND organization_id = $2;
