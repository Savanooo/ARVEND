-- Zam geçmişi (migration 0046): firmanın ürün fiyat değişiklikleri.
-- product_price_history'de organization_id yoktur -- firma izolasyonu HER
-- sorguda products.organization_id üzerinden JOIN ile sağlanır.
--
-- Ortak filtreler (liste + sayım + özet):
--   from_time <= changed_at < to_time (servis dahil/hariç sınırları çözer)
--   reason: 'all' ya da manual|supplier|markup
--   source: '' = hepsi, aksi hâlde kaynak kodu (elle düzenlemede source NULL)
-- Yüzde = (yeni - eski) / eski x 100; eski fiyat 0 ise NULL (tanımsız).

-- name: ListPriceChanges :many
-- sort: newest | largest_increase (yüzde büyükten küçüğe) | largest_decrease
-- (yüzde küçükten büyüğe, en çok düşen önce). Yüzdesi tanımsız satırlar
-- (eski fiyat 0) sıralamada sona düşer; eşitlikte en yeni önce.
SELECT h.id, h.product_id, p.name AS product_name, p.unit, p.category,
       h.source, h.reason, h.note, h.old_price, h.new_price, h.changed_at,
       h.old_source_price, h.new_source_price
FROM product_price_history h
JOIN products p ON p.id = h.product_id
WHERE p.organization_id = sqlc.arg(organization_id)
  AND h.changed_at >= sqlc.arg(from_time)::timestamptz
  AND h.changed_at <  sqlc.arg(to_time)::timestamptz
  AND (sqlc.arg(direction)::text = 'all'
       OR (sqlc.arg(direction)::text = 'up'   AND h.new_price > h.old_price)
       OR (sqlc.arg(direction)::text = 'down' AND h.new_price < h.old_price))
  AND (sqlc.arg(reason)::text = 'all' OR h.reason = sqlc.arg(reason)::text)
  AND (sqlc.arg(source)::text = '' OR h.source = sqlc.arg(source)::text)
  AND (sqlc.arg(category)::text = '' OR p.category = sqlc.arg(category)::text)
  AND (sqlc.arg(search)::text = '' OR p.normalized_name ILIKE '%' || sqlc.arg(search)::text || '%')
ORDER BY
  CASE WHEN sqlc.arg(sort)::text = 'largest_increase' AND h.old_price > 0
       THEN (h.new_price - h.old_price) / h.old_price END DESC NULLS LAST,
  CASE WHEN sqlc.arg(sort)::text = 'largest_decrease' AND h.old_price > 0
       THEN (h.new_price - h.old_price) / h.old_price END ASC NULLS LAST,
  h.changed_at DESC, h.id
LIMIT sqlc.arg(page_limit)::int OFFSET sqlc.arg(page_offset)::bigint;

-- name: CountPriceChanges :one
SELECT count(*)
FROM product_price_history h
JOIN products p ON p.id = h.product_id
WHERE p.organization_id = sqlc.arg(organization_id)
  AND h.changed_at >= sqlc.arg(from_time)::timestamptz
  AND h.changed_at <  sqlc.arg(to_time)::timestamptz
  AND (sqlc.arg(direction)::text = 'all'
       OR (sqlc.arg(direction)::text = 'up'   AND h.new_price > h.old_price)
       OR (sqlc.arg(direction)::text = 'down' AND h.new_price < h.old_price))
  AND (sqlc.arg(reason)::text = 'all' OR h.reason = sqlc.arg(reason)::text)
  AND (sqlc.arg(source)::text = '' OR h.source = sqlc.arg(source)::text)
  AND (sqlc.arg(category)::text = '' OR p.category = sqlc.arg(category)::text)
  AND (sqlc.arg(search)::text = '' OR p.normalized_name ILIKE '%' || sqlc.arg(search)::text || '%');

-- name: SummarizePriceChanges :one
SELECT (count(*) FILTER (WHERE h.new_price > h.old_price))::int AS increased_count,
       (count(*) FILTER (WHERE h.new_price < h.old_price))::int AS decreased_count,
       (count(DISTINCT h.product_id) FILTER (WHERE h.new_price > h.old_price))::int AS products_increased,
       round(avg((h.new_price - h.old_price) / h.old_price * 100)
             FILTER (WHERE h.new_price > h.old_price AND h.old_price > 0), 2)::numeric AS avg_increase_percent
FROM product_price_history h
JOIN products p ON p.id = h.product_id
WHERE p.organization_id = sqlc.arg(organization_id)
  AND h.changed_at >= sqlc.arg(from_time)::timestamptz
  AND h.changed_at <  sqlc.arg(to_time)::timestamptz
  AND (sqlc.arg(reason)::text = 'all' OR h.reason = sqlc.arg(reason)::text)
  AND (sqlc.arg(source)::text = '' OR h.source = sqlc.arg(source)::text);

-- name: GetMaxPriceIncrease :many
-- En yüksek yüzdeli zam (en fazla 1 satır; hiç zam yoksa boş).
SELECT h.product_id, p.name AS product_name,
       round((h.new_price - h.old_price) / h.old_price * 100, 2)::numeric AS change_percent
FROM product_price_history h
JOIN products p ON p.id = h.product_id
WHERE p.organization_id = sqlc.arg(organization_id)
  AND h.changed_at >= sqlc.arg(from_time)::timestamptz
  AND h.changed_at <  sqlc.arg(to_time)::timestamptz
  AND (sqlc.arg(reason)::text = 'all' OR h.reason = sqlc.arg(reason)::text)
  AND (sqlc.arg(source)::text = '' OR h.source = sqlc.arg(source)::text)
  AND h.new_price > h.old_price AND h.old_price > 0
ORDER BY (h.new_price - h.old_price) / h.old_price DESC, h.changed_at DESC, h.id
LIMIT 1;

-- name: ListPriceChangeEvents :many
-- Bir olay = aynı transaction'da yazılan satırlar: (changed_at, source,
-- reason). Elle düzenlemeler tek tek değil, İstanbul günü başına gruplanır
-- (event_at = o günün 00:00'ı). En yeni olay önce, en fazla max_events.
SELECT (CASE WHEN h.reason = 'manual'
             THEN date_trunc('day', h.changed_at AT TIME ZONE 'Europe/Istanbul') AT TIME ZONE 'Europe/Istanbul'
             ELSE h.changed_at END)::timestamptz AS event_at,
       h.source, h.reason,
       count(*)::int AS change_count,
       (count(*) FILTER (WHERE h.new_price > h.old_price))::int AS increased,
       (count(*) FILTER (WHERE h.new_price < h.old_price))::int AS decreased,
       round(avg((h.new_price - h.old_price) / h.old_price * 100)
             FILTER (WHERE h.old_price > 0), 2)::numeric AS avg_change_percent,
       round(max((h.new_price - h.old_price) / h.old_price * 100)
             FILTER (WHERE h.new_price > h.old_price AND h.old_price > 0), 2)::numeric AS max_increase_percent
FROM product_price_history h
JOIN products p ON p.id = h.product_id
WHERE p.organization_id = sqlc.arg(organization_id)
  AND h.changed_at >= sqlc.arg(from_time)::timestamptz
  AND h.changed_at <  sqlc.arg(to_time)::timestamptz
  AND (sqlc.arg(reason)::text = 'all' OR h.reason = sqlc.arg(reason)::text)
  AND (sqlc.arg(source)::text = '' OR h.source = sqlc.arg(source)::text)
GROUP BY 1, h.source, h.reason
ORDER BY 1 DESC, h.source NULLS LAST, h.reason
LIMIT sqlc.arg(max_events)::int;
