-- name: SetSuperAdminPassword :one
-- Super Admin'in şifresi -- yalnızca sunucudaki CLI'dan (cmd/reset-platform-admin-password).
-- Super Admin'in firması yok (organization_id NULL), bu yüzden firmaya bağlı
-- UpdateUserPassword onu bulamaz; rol ve silinmemişlik burada ayrıca
-- doğrulanır ki araç yanlışlıkla bir firma kullanıcısının şifresini
-- değiştiremesin.
UPDATE users
SET password_hash = $2, must_change_password = false, updated_at = now()
WHERE username = $1 AND role = 'super_admin' AND organization_id IS NULL AND deleted_at IS NULL
RETURNING id;
