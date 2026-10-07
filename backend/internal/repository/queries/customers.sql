-- name: CreateCustomer :one
INSERT INTO customers (organization_id, name, phone, email, address, tax_office, tax_number, notes)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
RETURNING *;

-- name: GetCustomerByID :one
SELECT * FROM customers WHERE id = $1 AND organization_id = $2;

-- name: ListCustomers :many
-- search: ad, e-posta veya vergi numarasında geçer (LIKE joker karakterleri
-- çağıranda kaçırılır); search_digits (aramadaki rakamlar, baştaki 0'lar
-- atılmış) telefonun yalnızca rakamlarında aranır -- "0532 111" araması
-- "+90 (532) 111 22 33" kaydını bulur. Eskiden yalnızca ad aranıyordu:
-- telefonla/vergi no ile müşteri bulunamıyor, aynı müşteri tekrar açılıyordu.
SELECT * FROM customers
WHERE organization_id = sqlc.arg(organization_id)
  AND (sqlc.narg('is_active')::boolean IS NULL OR is_active = sqlc.narg('is_active')::boolean)
  AND (sqlc.arg(search)::text = ''
       OR name ILIKE '%' || sqlc.arg(search)::text || '%'
       OR email ILIKE '%' || sqlc.arg(search)::text || '%'
       OR tax_number ILIKE '%' || sqlc.arg(search)::text || '%'
       OR (sqlc.arg(search_digits)::text <> ''
           AND regexp_replace(phone, '[^0-9]', '', 'g') LIKE '%' || sqlc.arg(search_digits)::text || '%'))
ORDER BY name ASC;

-- name: FindCustomerDuplicates :many
-- Aynı firmada aynı vergi numarasına ya da telefona sahip müşteriler
-- (arşivdekiler dahil -- arşivdeki bir müşteriyi yeniden açmak, yenisini
-- yaratmaktan doğrudur). Karşılaştırma normalize anahtarlarla yapılır:
-- vergi no yalnızca harf/rakam, büyük harf; telefon yalnızca rakamların son
-- 10 hanesi (+90 / 0 öneki fark etmez). Boş anahtar karşılaştırılmaz.
-- Anahtarlar Go tarafında service.customerTaxKey / customerPhoneKey ile
-- AYNI kuralla üretilir.
SELECT * FROM customers
WHERE organization_id = sqlc.arg(organization_id)
  AND (sqlc.narg('exclude_id')::uuid IS NULL OR id <> sqlc.narg('exclude_id')::uuid)
  AND ((sqlc.arg(tax_key)::text <> ''
        AND upper(regexp_replace(tax_number, '[^0-9A-Za-z]', '', 'g')) = sqlc.arg(tax_key)::text)
    OR (sqlc.arg(phone_key)::text <> ''
        AND right(regexp_replace(phone, '[^0-9]', '', 'g'), 10) = sqlc.arg(phone_key)::text))
ORDER BY is_active DESC, name ASC
LIMIT 5;

-- name: UpdateCustomer :one
UPDATE customers
SET name = $3, phone = $4, email = $5, address = $6, tax_office = $7,
    tax_number = $8, notes = $9, is_active = $10
WHERE id = $1 AND organization_id = $2
RETURNING *;

-- name: ArchiveCustomer :execrows
UPDATE customers SET is_active = false WHERE id = $1 AND organization_id = $2;
