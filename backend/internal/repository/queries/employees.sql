-- name: CreateEmployee :one
INSERT INTO employees (full_name, phone, position, salary, daily_wage, start_date, description)
VALUES ($1, $2, $3, $4, $5, $6, $7)
RETURNING *;

-- name: GetEmployeeByID :one
SELECT * FROM employees WHERE id = $1;

-- name: ListEmployees :many
SELECT * FROM employees
WHERE (sqlc.narg('is_active')::boolean IS NULL OR is_active = sqlc.narg('is_active')::boolean)
ORDER BY full_name ASC;

-- name: UpdateEmployee :one
UPDATE employees
SET full_name = $2, phone = $3, position = $4, salary = $5, daily_wage = $6,
    start_date = $7, description = $8, is_active = $9
WHERE id = $1
RETURNING *;

-- name: ArchiveEmployee :exec
UPDATE employees SET is_active = false, archived_at = now() WHERE id = $1;
