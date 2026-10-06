-- name: NextOfferSeq :one
INSERT INTO offer_counters (organization_id, year, seq) VALUES ($1, $2, 1)
ON CONFLICT (organization_id, year) DO UPDATE SET seq = offer_counters.seq + 1
RETURNING seq;

-- name: CreateOffer :one
INSERT INTO offers (organization_id, offer_no, status, created_by)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: SetOfferCurrentRevision :exec
UPDATE offers SET current_revision_id = $2, status = $3 WHERE id = $1;

-- name: GetOfferByID :one
SELECT * FROM offers WHERE id = $1 AND organization_id = $2;

-- name: ListOffers :many
-- customer_id: Müşteri detay ekranının "Teklifler" bölümü için --
-- projects.sql'deki ListProjects'in AYNI nullable-narg deseni (customer_id
-- IS NULL => filtresiz). offers tablosunun kendisinde customer_id YOK
-- (0018 migration'da kaldırıldı) -- canlı değer yalnızca current_revision
-- üzerinden erişilebilir, bu yüzden r.customer_id üzerinden filtrelenir.
-- status/search/date_from/date_to: liste ekranlarının durum sekmesi, arama
-- ve tarih filtresi SUNUCUDA uygulanır (eskiden yalnızca ilk 50 satır
-- çekilip tarayıcıda/mobilde süzülüyordu -- 51. ve sonraki teklifler hiçbir
-- filtrede görünmüyordu). search, teklif no veya müşteri adında geçer;
-- '%'/'_' joker karakterleri çağıran tarafta kaçırılır (bkz.
-- escapeLikePattern). Sıralama tie-breaker'lı (id) -- sayfalar arası kayma
-- olmasın.
SELECT o.*, r.customer_id, r.customer_name, r.grand_total, r.revision_no
FROM offers o
JOIN offer_revisions r ON r.id = o.current_revision_id
WHERE o.organization_id = sqlc.arg(organization_id) AND o.is_passive = sqlc.arg(is_passive)
  AND (sqlc.narg('customer_id')::uuid IS NULL OR r.customer_id = sqlc.narg('customer_id')::uuid)
  AND (sqlc.narg('status')::varchar IS NULL OR o.status = sqlc.narg('status')::varchar)
  AND (sqlc.narg('date_from')::date IS NULL OR o.offer_date >= sqlc.narg('date_from')::date)
  AND (sqlc.narg('date_to')::date IS NULL OR o.offer_date <= sqlc.narg('date_to')::date)
  AND (sqlc.narg('search')::varchar IS NULL
       OR o.offer_no ILIKE '%' || sqlc.narg('search')::varchar || '%'
       OR r.customer_name ILIKE '%' || sqlc.narg('search')::varchar || '%')
ORDER BY o.created_at DESC, o.id DESC
LIMIT sqlc.arg(row_limit) OFFSET sqlc.arg(row_offset);

-- name: CountOffersByStatus :many
-- ListOffers'ın AYNI filtreleri (durum HARİÇ), duruma göre gruplanmış --
-- hem sayfalamanın gerçek toplamı hem de durum sekmelerinin sayaçları bu
-- TEK sorgudan türetilir (sekmeler artık yalnızca yüklenen satırları
-- saymıyor).
SELECT o.status, count(*) AS count
FROM offers o
JOIN offer_revisions r ON r.id = o.current_revision_id
WHERE o.organization_id = sqlc.arg(organization_id) AND o.is_passive = sqlc.arg(is_passive)
  AND (sqlc.narg('customer_id')::uuid IS NULL OR r.customer_id = sqlc.narg('customer_id')::uuid)
  AND (sqlc.narg('date_from')::date IS NULL OR o.offer_date >= sqlc.narg('date_from')::date)
  AND (sqlc.narg('date_to')::date IS NULL OR o.offer_date <= sqlc.narg('date_to')::date)
  AND (sqlc.narg('search')::varchar IS NULL
       OR o.offer_no ILIKE '%' || sqlc.narg('search')::varchar || '%'
       OR r.customer_name ILIKE '%' || sqlc.narg('search')::varchar || '%')
GROUP BY o.status;

-- name: SetOfferPassive :exec
UPDATE offers SET is_passive = $3 WHERE id = $1 AND organization_id = $2;

-- name: DeleteOffer :exec
DELETE FROM offers WHERE id = $1 AND organization_id = $2;
