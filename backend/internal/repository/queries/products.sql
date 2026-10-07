-- name: CreateProduct :one
INSERT INTO products (organization_id, name, normalized_name, unit, unit_price, description, category, source, source_price)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
RETURNING *;

-- name: GetProductByID :one
SELECT * FROM products WHERE id = $1 AND organization_id = $2;

-- name: ListProducts :many
-- Aramasız katalog listesi (ad sırasıyla). Arama SearchProducts'tadır.
SELECT * FROM products
WHERE organization_id = $1
ORDER BY name ASC, id ASC
LIMIT $2 OFFSET $3;

-- name: CountProducts :one
SELECT count(*) FROM products
WHERE organization_id = $1;

-- name: SearchProducts :many
-- Kelime bazlı katalog araması (bkz. domain/product_search.go). Ürün, HER
-- kelime adında YA DA kategorisinde YA DA tedarikçisinde geçiyorsa eşleşir:
-- üç alan (kelimeler boşluk içermediği için hiçbir kelime iki alana taşamaz)
-- boşlukla birleştirilip "LIKE ALL" ile aranır. Desenler Go'da kaçışlanır
-- (ProductSearchPatterns): "_" ve "%" joker değildir.
--
-- Katlama Go'daki ProductSearchFold ile BİREBİR aynı olmalı:
--   ad       normalized_name (Go NormalizeName ile yazılmış) + "40 x 40" ->
--            "40x40" (regexp yalnızca x'in yanında boşluk varken çalışır) +
--            × * , -> x x .
--   kategori Türkçe harf katlaması + lower (translate lower'dan ÖNCE:
--            lower('İ') yerel ayara göre 'i̇' olur) + aynı ölçü katlaması.
--            translate pahalıdır (çok baytlı küme): firmanın her FARKLI
--            kategorisi için bir kez hesaplanır, satır başına değil.
--   tedarikçi kayıt defterinden gelen etiket (ProductSearchSources); defterde
--            olmayan bir kaynak kodu kendi adıyla aranır.
-- candidates MATERIALIZED: Postgres aksi hâlde ad katlamasını her
-- kullanıldığı yere (filtre + beş sıralama anahtarı) kopyalayıp satır
-- başına defalarca hesaplıyordu.
--
-- Sıra:
--   1. tüm kelimeler adda; 2. en az bir kelime adda -- ad eşleşmesi
--      kategori/tedarikçi eşleşmesinden önce ("profil": Kutu Profil'ler,
--      Demir Profil'in borularından önce);
--   3. tüm kelimeler bir kelimenin BAŞINDA -- "kutu 40": 40×40 ve 30×40,
--      140×140'tan önce (ölçü ayracı x, Ø, parantez, /, - kelime başı sayılır);
--   4. sorgu adda yan yana geçiyor ("kutu profil"); 5. ad ilk kelimeyle başlıyor;
--   6. kısa ad önce (yazılana daha yakın), sonra ad, id.
-- total: sayfalamadan önceki eşleşme sayısı (her satırda aynı).
WITH category_folds AS MATERIALIZED (
    SELECT d.category,
           replace(replace(replace(
               CASE WHEN d.lowered ~ '[x×*] | [x×*]'
                    THEN regexp_replace(d.lowered, '(\d) *[x×*] *(?=\d)', '\1x', 'g') ELSE d.lowered END,
           '×', 'x'), '*', 'x'), ',', '.') AS category_f
    FROM (
        SELECT DISTINCT p.category, lower(translate(p.category, 'İIıŞşĞğÜüÖöÇç', 'iiissgguuoocc')) AS lowered
        FROM products AS p
        WHERE p.organization_id = sqlc.arg(organization_id)
    ) AS d
), candidates AS MATERIALIZED (
    SELECT p.*, n.name_f,
           n.name_f || ' ' || cf.category_f || ' ' ||
           coalesce((sqlc.arg(source_labels)::text[])[array_position(sqlc.arg(source_codes)::text[], p.source::text)],
                    lower(p.source), '') AS haystack
    FROM products AS p
    JOIN category_folds AS cf ON cf.category = p.category
    CROSS JOIN LATERAL (
        SELECT replace(replace(replace(
                   CASE WHEN p.normalized_name ~ '[x×*] | [x×*]'
                        THEN regexp_replace(p.normalized_name, '(\d) *[x×*] *(?=\d)', '\1x', 'g') ELSE p.normalized_name END,
               '×', 'x'), '*', 'x'), ',', '.') AS name_f
    ) AS n
    WHERE p.organization_id = sqlc.arg(organization_id)
)
SELECT c.id, c.name, c.normalized_name, c.unit, c.unit_price, c.description, c.category, c.source,
       c.source_price, c.created_at, c.updated_at, c.organization_id, c.source_synced_at,
       count(*) OVER () AS total
FROM candidates AS c
WHERE c.haystack LIKE ALL (sqlc.arg(patterns)::text[])
ORDER BY (c.name_f LIKE ALL (sqlc.arg(patterns)::text[])) DESC,
         (c.name_f LIKE ANY (sqlc.arg(patterns)::text[])) DESC,
         (' ' || c.name_f || ' ' || translate(c.name_f, 'ø(/-x', '     ')) LIKE ALL (sqlc.arg(word_start_patterns)::text[]) DESC,
         (strpos(c.name_f, sqlc.arg(phrase)::text) > 0) DESC,
         starts_with(c.name_f, sqlc.arg(first_term)::text) DESC,
         length(c.name) ASC,
         c.name ASC, c.id ASC
LIMIT sqlc.arg(row_limit) OFFSET sqlc.arg(row_offset);

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
