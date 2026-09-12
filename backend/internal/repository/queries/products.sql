-- name: CreateProduct :one
INSERT INTO products (name, normalized_name, unit, unit_price, description, category, source, source_price)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
RETURNING *;

-- name: GetProductByID :one
SELECT * FROM products WHERE id = $1;

-- name: ListProducts :many
SELECT * FROM products
WHERE ($3::text = '' OR normalized_name ILIKE '%' || $3::text || '%')
ORDER BY name ASC
LIMIT $1 OFFSET $2;

-- name: CountProducts :one
SELECT count(*) FROM products
WHERE ($1::text = '' OR normalized_name ILIKE '%' || $1::text || '%');

-- name: UpdateProduct :one
UPDATE products
SET name = $2, normalized_name = $3, unit = $4, unit_price = $5,
    description = $6, category = $7
WHERE id = $1
RETURNING *;

-- name: DeleteProduct :exec
DELETE FROM products WHERE id = $1;

-- name: CreatePriceHistory :exec
INSERT INTO product_price_history (product_id, old_price, new_price, note)
VALUES ($1, $2, $3, $4);

-- name: ListPriceHistory :many
SELECT * FROM product_price_history
WHERE product_id = $1
ORDER BY changed_at DESC;
