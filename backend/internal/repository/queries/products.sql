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
ORDER BY name ASC, id ASC
LIMIT $2 OFFSET $3;

-- name: CountProducts :one
SELECT count(*) FROM products
WHERE organization_id = $1
  AND ($2::text = '' OR normalized_name ILIKE '%' || $2::text || '%');

-- name: UpdateProductWithPriceHistory :one
-- Elle ürün düzenleme TEK ifadede (tek transaction): satır kilitlenip
-- (FOR NO KEY UPDATE) ESKİ fiyat okunur, ürün güncellenir ve fiyat
-- değiştiyse fiyat geçmişi satırı (reason 'manual', kaynak yok) yazılır.
-- Eşzamanlı bir senkron/kâr oranı güncellemesi satırı tutuyorsa kilit
-- beklenir ve eski fiyat, onun YAZDIĞI fiyattır (READ COMMITTED'da kilitli
-- okuma satırın en son hâlini döner) -- geçmiş satırları zincir kurar
-- (100->110 senkron, 110->120 elle). Geçmiş yazılamazsa güncelleme de
-- geri alınır. Satır yoksa (başka firma/silinmiş) sonuç boştur.
WITH old AS MATERIALIZED (
    SELECT cur.id, cur.unit_price FROM products AS cur
    WHERE cur.id = sqlc.arg(id) AND cur.organization_id = sqlc.arg(organization_id)
    FOR NO KEY UPDATE
), upd AS (
    UPDATE products AS p
    SET name = sqlc.arg(name), normalized_name = sqlc.arg(normalized_name), unit = sqlc.arg(unit),
        unit_price = sqlc.arg(unit_price), description = sqlc.arg(description), category = sqlc.arg(category)
    FROM old
    WHERE p.id = old.id
    RETURNING p.*
), hist AS (
    INSERT INTO product_price_history (product_id, old_price, new_price, note, reason)
    SELECT upd.id, old.unit_price, upd.unit_price, '', 'manual'
    FROM upd JOIN old ON old.id = upd.id
    WHERE upd.unit_price <> old.unit_price
)
SELECT * FROM upd;

-- name: DeleteProduct :execrows
DELETE FROM products WHERE id = $1 AND organization_id = $2;

-- name: ListPriceHistory :many
SELECT * FROM product_price_history
WHERE product_id = $1
ORDER BY changed_at DESC;
