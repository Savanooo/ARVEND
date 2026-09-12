-- name: CreateProduct :one
INSERT INTO products (organization_id, name, normalized_name, unit, unit_price, description, category, source, source_price)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
RETURNING *;

-- name: GetProductByID :one
SELECT * FROM products WHERE id = $1 AND organization_id = $2;

-- name: ListProducts :many
SELECT * FROM products
WHERE organization_id = $1
  AND ($4::text = '' OR normalized_name ILIKE '%' || $4::text || '%')
ORDER BY name ASC
LIMIT $2 OFFSET $3;

-- name: CountProducts :one
SELECT count(*) FROM products
WHERE organization_id = $1
  AND ($2::text = '' OR normalized_name ILIKE '%' || $2::text || '%');

-- name: UpdateProduct :one
UPDATE products
SET name = $3, normalized_name = $4, unit = $5, unit_price = $6,
    description = $7, category = $8
WHERE id = $1 AND organization_id = $2
RETURNING *;

-- name: DeleteProduct :execrows
DELETE FROM products WHERE id = $1 AND organization_id = $2;

-- name: CreatePriceHistory :exec
INSERT INTO product_price_history (product_id, old_price, new_price, note)
VALUES ($1, $2, $3, $4);

-- name: ListPriceHistory :many
SELECT * FROM product_price_history
WHERE product_id = $1
ORDER BY changed_at DESC;
