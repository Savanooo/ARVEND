-- name: CreateCustomer :one
INSERT INTO customers (organization_id, name, phone, email, address, tax_office, tax_number, notes)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
RETURNING *;

-- name: GetCustomerByID :one
SELECT * FROM customers WHERE id = $1 AND organization_id = $2;

-- name: ListCustomers :many
SELECT * FROM customers
WHERE organization_id = $1
  AND (sqlc.narg('is_active')::boolean IS NULL OR is_active = sqlc.narg('is_active')::boolean)
  AND ($2::text = '' OR name ILIKE '%' || $2::text || '%')
ORDER BY name ASC;

-- name: UpdateCustomer :one
UPDATE customers
SET name = $3, phone = $4, email = $5, address = $6, tax_office = $7,
    tax_number = $8, notes = $9, is_active = $10
WHERE id = $1 AND organization_id = $2
RETURNING *;

-- name: ArchiveCustomer :execrows
UPDATE customers SET is_active = false WHERE id = $1 AND organization_id = $2;
