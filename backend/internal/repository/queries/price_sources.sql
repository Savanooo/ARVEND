-- Tedarikçi fiyat listesi senkronu (migration 0045). Toplu yazmalar
-- unnest(dizi) ile TEK ifadede yapılır -- ~600 ürünlük bir liste için
-- satır başına ayrı UPDATE/INSERT gidip gelmesi olmasın. SELECT listesindeki
-- birden çok unnest(...) PostgreSQL 10+'da eşzamanlı (satır satır eşleşerek)
-- açılır; diziler servis katmanında hep AYNI uzunlukta kurulur. (sqlc çok
-- argümanlı unnest(a, b) biçimini tanımadığı için bu biçim kullanılır.)

-- name: GetOrganizationPriceSource :one
SELECT * FROM organization_price_sources
WHERE organization_id = $1 AND source = $2;

-- name: ListPriceSourceCategoryMarkups :many
SELECT category, markup_percent FROM organization_price_source_category_markups
WHERE organization_id = $1 AND source = $2
ORDER BY category;

-- name: UpsertOrganizationPriceSourceSettings :one
INSERT INTO organization_price_sources (organization_id, source, markup_percent, auto_sync, updated_by)
VALUES ($1, $2, $3, $4, $5)
ON CONFLICT (organization_id, source) DO UPDATE
SET markup_percent = EXCLUDED.markup_percent,
    auto_sync      = EXCLUDED.auto_sync,
    updated_by     = EXCLUDED.updated_by
RETURNING *;

-- name: DeletePriceSourceCategoryMarkups :exec
DELETE FROM organization_price_source_category_markups
WHERE organization_id = $1 AND source = $2;

-- name: InsertPriceSourceCategoryMarkups :exec
INSERT INTO organization_price_source_category_markups (organization_id, source, category, markup_percent)
SELECT sqlc.arg(organization_id)::uuid, sqlc.arg(source)::text, u.category, u.markup_percent
FROM (
    SELECT unnest(sqlc.arg(categories)::text[])         AS category,
           unnest(sqlc.arg(markup_percents)::numeric[]) AS markup_percent
) AS u;

-- name: RecordPriceSourceSyncSuccess :one
-- last_synced_at = now(): aynı transaction'daki products.source_synced_at
-- ile BİREBİR aynı an (eksik ürün hesabı bu eşitliğe dayanır).
INSERT INTO organization_price_sources (
    organization_id, source, last_synced_at, last_status, last_error,
    last_total, last_created, last_updated, last_unchanged, last_missing)
VALUES (sqlc.arg(organization_id), sqlc.arg(source), now(), 'success', '',
    sqlc.arg(total), sqlc.arg(created), sqlc.arg(updated), sqlc.arg(unchanged), sqlc.arg(missing))
ON CONFLICT (organization_id, source) DO UPDATE
SET last_synced_at = now(),
    last_status    = 'success',
    last_error     = '',
    last_total     = EXCLUDED.last_total,
    last_created   = EXCLUDED.last_created,
    last_updated   = EXCLUDED.last_updated,
    last_unchanged = EXCLUDED.last_unchanged,
    last_missing   = EXCLUDED.last_missing
RETURNING last_synced_at;

-- name: RecordPriceSourceSyncFailure :exec
-- Başarısız deneme: last_synced_at ve son başarılı sayılar KORUNUR.
INSERT INTO organization_price_sources (organization_id, source, last_status, last_error)
VALUES (sqlc.arg(organization_id), sqlc.arg(source), 'failed', sqlc.arg(last_error))
ON CONFLICT (organization_id, source) DO UPDATE
SET last_status = 'failed',
    last_error  = EXCLUDED.last_error;

-- name: ListAutoSyncOrganizations :many
-- Gece işi: otomatik senkronu açık, erişimi olan (active/trial), silinmemiş
-- firmalar. synced_before: bu çalıştırmanın planlandığı an -- başka bir API
-- instance'ı aynı geceyi az önce işlediyse o firmalar tekrar alınmaz.
SELECT s.organization_id
FROM organization_price_sources s
JOIN organizations o ON o.id = s.organization_id
WHERE s.source = sqlc.arg(source)
  AND s.auto_sync
  AND o.status IN ('active', 'trial')
  AND o.deleted_at IS NULL
  AND (s.last_synced_at IS NULL OR s.last_synced_at < sqlc.arg(synced_before)::timestamptz)
ORDER BY o.created_at, o.id;

-- name: TryPriceSourceXactLock :one
SELECT pg_try_advisory_xact_lock(sqlc.arg(lock_class)::int, hashtext(sqlc.arg(lock_key)::text));

-- name: PriceSourceXactLock :exec
SELECT pg_advisory_xact_lock(sqlc.arg(lock_class)::int, hashtext(sqlc.arg(lock_key)::text));

-- name: ListSourceProductsForUpdate :many
-- Firmanın YALNIZCA bu kaynaktan gelen ürünleri; elle eklenen (source
-- NULL/başka) ürünler aynı ada sahip olsa bile ASLA eşleşmez.
-- description + source_synced_at: hiç senkronlanmamış (BYZ'den aktarılmış)
-- satırlarda Ulaş kategorisi açıklamadadır (bkz. matchSourceRows).
-- FOR NO KEY UPDATE (FOR UPDATE DEĞİL): senkron anahtar kolonlara
-- dokunmaz; FOR UPDATE, teklif/reçete/değişiklik talebi kalemi eklerken
-- FK kontrolünün aldığı FOR KEY SHARE ile çakışıp o kayıtları bekletir,
-- satırları farklı sırayla kilitleyen bir teklif kaydıyla kilitlenmeye
-- (deadlock) yol açardı. Eşzamanlı ürün UPDATE/DELETE'ine karşı yine
-- sıralanır.
SELECT id, name, unit, unit_price, source_price, category, description, source_synced_at
FROM products
WHERE organization_id = sqlc.arg(organization_id) AND source = sqlc.arg(source)::text
ORDER BY created_at, id
FOR NO KEY UPDATE;

-- name: UpdateSourceProducts :execrows
-- Senkronun eşleşen satırları: ad/birim/açıklama/id KORUNUR (açıklama
-- kullanıcıya aittir), yalnızca fiyatlar + kaynak kategorisi + görülme
-- anı yazılır.
UPDATE products AS p
SET unit_price       = u.unit_price,
    source_price     = u.source_price,
    category         = u.category,
    source_synced_at = now()
FROM (
    SELECT unnest(sqlc.arg(ids)::uuid[])              AS id,
           unnest(sqlc.arg(unit_prices)::numeric[])   AS unit_price,
           unnest(sqlc.arg(source_prices)::numeric[]) AS source_price,
           unnest(sqlc.arg(categories)::text[])       AS category
) AS u
WHERE p.id = u.id
  AND p.organization_id = sqlc.arg(organization_id)
  AND p.source = sqlc.arg(source)::text;

-- name: InsertSourceProducts :execrows
INSERT INTO products (organization_id, name, normalized_name, unit, unit_price, description,
    category, source, source_price, source_synced_at)
SELECT sqlc.arg(organization_id)::uuid, u.name, u.normalized_name, u.unit, u.unit_price, '',
    u.category, sqlc.arg(source)::text, u.source_price, now()
FROM (
    SELECT unnest(sqlc.arg(names)::text[])             AS name,
           unnest(sqlc.arg(normalized_names)::text[])  AS normalized_name,
           unnest(sqlc.arg(units)::text[])             AS unit,
           unnest(sqlc.arg(unit_prices)::numeric[])    AS unit_price,
           unnest(sqlc.arg(source_prices)::numeric[])  AS source_price,
           unnest(sqlc.arg(categories)::text[])        AS category
) AS u;

-- name: UpdateProductUnitPrices :execrows
UPDATE products AS p
SET unit_price = u.unit_price
FROM (
    SELECT unnest(sqlc.arg(ids)::uuid[])            AS id,
           unnest(sqlc.arg(unit_prices)::numeric[]) AS unit_price
) AS u
WHERE p.id = u.id
  AND p.organization_id = sqlc.arg(organization_id)
  AND p.source = sqlc.arg(source)::text;

-- name: InsertPriceHistoryBatch :exec
INSERT INTO product_price_history (product_id, old_price, new_price, note)
SELECT u.product_id, u.old_price, u.new_price, sqlc.arg(note)::text
FROM (
    SELECT unnest(sqlc.arg(product_ids)::uuid[])    AS product_id,
           unnest(sqlc.arg(old_prices)::numeric[])  AS old_price,
           unnest(sqlc.arg(new_prices)::numeric[])  AS new_price
) AS u;

-- name: CountSourceProductsNotSyncedNow :one
-- Senkron transaction'ı İÇİNDE: bu senkronda görülmeyen (source_synced_at
-- now()'dan eski veya NULL) kaynak ürünleri = listeden düşenler.
SELECT count(*) FROM products
WHERE organization_id = sqlc.arg(organization_id) AND source = sqlc.arg(source)::text
  AND (source_synced_at IS NULL OR source_synced_at < now());

-- name: SummarizeSourceProducts :one
-- missing yalnızca en az bir başarılı senkron olduysa anlamlıdır (hiç
-- senkron yoksa BYZ'den aktarılan satırların hepsi "eksik" görünmesin).
SELECT count(*)::int AS product_count,
       (count(*) FILTER (
            WHERE s.last_synced_at IS NOT NULL
              AND (p.source_synced_at IS NULL OR p.source_synced_at < s.last_synced_at)
       ))::int AS missing_count
FROM products p
LEFT JOIN organization_price_sources s
       ON s.organization_id = p.organization_id AND s.source = p.source
WHERE p.organization_id = sqlc.arg(organization_id) AND p.source = sqlc.arg(source)::text;

-- name: ListSourceProductCategories :many
SELECT category, count(*)::int AS product_count
FROM products
WHERE organization_id = sqlc.arg(organization_id) AND source = sqlc.arg(source)::text AND category <> ''
GROUP BY category
ORDER BY category;
