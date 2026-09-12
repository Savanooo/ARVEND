-- name: CreateEmployee :one
INSERT INTO employees (organization_id, full_name, phone, position, salary, daily_wage, start_date, description)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
RETURNING *;

-- name: GetEmployeeByID :one
SELECT * FROM employees WHERE id = $1 AND organization_id = $2;

-- name: ListEmployees :many
SELECT * FROM employees
WHERE organization_id = $1
  AND (sqlc.narg('is_active')::boolean IS NULL OR is_active = sqlc.narg('is_active')::boolean)
ORDER BY full_name ASC;

-- name: UpdateEmployee :one
UPDATE employees
SET full_name = $3, phone = $4, position = $5, salary = $6, daily_wage = $7,
    start_date = $8, description = $9, is_active = $10
WHERE id = $1 AND organization_id = $2
RETURNING *;

-- name: ArchiveEmployee :execrows
UPDATE employees SET is_active = false, archived_at = now() WHERE id = $1 AND organization_id = $2;
