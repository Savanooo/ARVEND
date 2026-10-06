-- name: CreateEmployee :one
INSERT INTO employees (organization_id, full_name, phone, position, salary, daily_wage, start_date, description, user_id)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
RETURNING *;

-- name: GetEmployeeByID :one
SELECT * FROM employees WHERE id = $1 AND organization_id = $2;

-- name: ListEmployees :many
SELECT * FROM employees
WHERE organization_id = $1
  AND (sqlc.narg('is_active')::boolean IS NULL OR is_active = sqlc.narg('is_active')::boolean)
ORDER BY full_name ASC;

-- name: GetEmployeeForUpdate :one
-- Ücret değişikliğini (eski -> yeni) aynı transaction içinde güvenle
-- karşılaştırmak için satırı kilitler (bkz. EmployeeService.Update).
SELECT * FROM employees WHERE id = $1 AND organization_id = $2 FOR UPDATE;

-- name: UpdateEmployee :one
UPDATE employees
SET full_name = $3, phone = $4, position = $5, salary = $6, daily_wage = $7,
    start_date = $8, description = $9, is_active = $10, user_id = $11
WHERE id = $1 AND organization_id = $2
RETURNING *;

-- name: ArchiveEmployee :execrows
UPDATE employees SET is_active = false, archived_at = now() WHERE id = $1 AND organization_id = $2;

-- name: GetEmployeeByUserID :one
-- GET /tasks/mine'ın "bana ATANAN görevler" çözümlemesinin TEK kaynağı --
-- giriş yapan kullanıcının bağlı olduğu personel kaydını (varsa) bulur.
-- Bağlantısız bir kullanıcı için 0 satır döner (pgx.ErrNoRows) -- çağıran
-- bunu "hiç göreve atanmamış" olarak ele alır (boş liste, ASLA tüm
-- projelerin görevlerine düşmez).
SELECT * FROM employees WHERE user_id = $1 AND organization_id = $2;
