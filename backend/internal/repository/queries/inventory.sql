-- Stok Takibi (migration 0072).

-- ============ Depolar ============

-- name: ListInventoryWarehouses :many
SELECT w.*,
       (SELECT count(DISTINCT b.item_id) FROM inventory_balances b
        WHERE b.warehouse_id = w.id AND b.quantity > 0)::int AS item_count
FROM inventory_warehouses w
WHERE w.organization_id = $1
ORDER BY w.is_active DESC, lower(w.name);

-- name: CountInventoryWarehouses :one
SELECT count(*)::int FROM inventory_warehouses WHERE organization_id = $1;

-- name: CreateInventoryWarehouse :one
INSERT INTO inventory_warehouses (organization_id, name, address, notes, created_by)
VALUES ($1, $2, $3, $4, sqlc.narg(created_by))
RETURNING *;

-- name: UpdateInventoryWarehouse :one
UPDATE inventory_warehouses
SET name = sqlc.arg(name), address = sqlc.arg(address), notes = sqlc.arg(notes), is_active = sqlc.arg(is_active)
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id)
RETURNING *;

-- name: GetInventoryWarehouse :one
SELECT * FROM inventory_warehouses WHERE id = $1 AND organization_id = $2;

-- name: InventoryWarehouseHasStock :one
SELECT EXISTS (SELECT 1 FROM inventory_balances WHERE warehouse_id = $1 AND quantity > 0);

-- ============ Malzeme kartları ============

-- name: NextInventoryItemCodeNumber :one
SELECT (COALESCE(max(substring(code FROM 5)::int), 0) + 1)::int AS next
FROM inventory_items
WHERE organization_id = $1 AND code ~ '^STK-[0-9]+$';

-- name: CreateInventoryItem :one
INSERT INTO inventory_items (
    organization_id, code, name, barcode, unit, category, product_id, min_stock,
    track_expiry, shelf_life_months, expiry_policy, expiry_alert_days, notes, created_by
) VALUES (
    sqlc.arg(organization_id), sqlc.arg(code), sqlc.arg(name), sqlc.arg(barcode), sqlc.arg(unit),
    sqlc.arg(category), sqlc.narg(product_id), sqlc.narg(min_stock), sqlc.arg(track_expiry),
    sqlc.narg(shelf_life_months), sqlc.arg(expiry_policy), sqlc.arg(expiry_alert_days),
    sqlc.arg(notes), sqlc.narg(created_by)
)
RETURNING *;

-- name: UpdateInventoryItem :one
UPDATE inventory_items
SET code = sqlc.arg(code), name = sqlc.arg(name), barcode = sqlc.arg(barcode), unit = sqlc.arg(unit),
    category = sqlc.arg(category), product_id = sqlc.narg(product_id), min_stock = sqlc.narg(min_stock),
    track_expiry = sqlc.arg(track_expiry), shelf_life_months = sqlc.narg(shelf_life_months),
    expiry_policy = sqlc.arg(expiry_policy), expiry_alert_days = sqlc.arg(expiry_alert_days),
    notes = sqlc.arg(notes), is_active = sqlc.arg(is_active)
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id)
RETURNING *;

-- name: GetInventoryItem :one
SELECT * FROM inventory_items WHERE id = $1 AND organization_id = $2;

-- name: GetInventoryItemForUpdate :one
SELECT * FROM inventory_items WHERE id = $1 AND organization_id = $2 FOR UPDATE;

-- name: GetInventoryItemByBarcode :one
SELECT * FROM inventory_items WHERE organization_id = $1 AND barcode = $2 AND barcode <> '';

-- name: InventoryItemHasMovements :one
SELECT EXISTS (SELECT 1 FROM inventory_movements WHERE item_id = $1);

-- name: ListInventoryItems :many
-- Kartlar ve stok durumları. warehouse_id verilirse miktarlar o depodan;
-- en yakın SKT, SKT'si geçmiş ve yaklaşan miktar (kartın uyarı gününe
-- göre) ve minimum stok karşılaştırması için toplam.
WITH bal AS (
    SELECT b.item_id,
           sum(b.quantity) AS quantity,
           min(l.expiry_date) FILTER (WHERE b.quantity > 0) AS nearest_expiry,
           COALESCE(sum(b.quantity) FILTER (WHERE l.expiry_date < sqlc.arg(today)::date), 0) AS expired_quantity,
           COALESCE(sum(b.quantity) FILTER (
               WHERE l.expiry_date >= sqlc.arg(today)::date
                 AND l.expiry_date <= sqlc.arg(today)::date + i.expiry_alert_days), 0) AS expiring_quantity
    FROM inventory_balances b
    JOIN inventory_items i ON i.id = b.item_id
    LEFT JOIN inventory_lots l ON l.id = b.lot_id
    WHERE b.organization_id = sqlc.arg(organization_id)
      AND (sqlc.narg(warehouse_id)::uuid IS NULL OR b.warehouse_id = sqlc.narg(warehouse_id)::uuid)
    GROUP BY b.item_id
)
SELECT i.*,
       COALESCE(bal.quantity, 0)::numeric(14,3) AS quantity,
       bal.nearest_expiry::date AS nearest_expiry,
       COALESCE(bal.expired_quantity, 0)::numeric(14,3) AS expired_quantity,
       COALESCE(bal.expiring_quantity, 0)::numeric(14,3) AS expiring_quantity
FROM inventory_items i
LEFT JOIN bal ON bal.item_id = i.id
WHERE i.organization_id = sqlc.arg(organization_id)
  AND (sqlc.arg(include_inactive)::bool OR i.is_active)
ORDER BY lower(i.name);

-- name: InventoryItemTotalQuantity :one
SELECT COALESCE(sum(quantity), 0)::numeric(14,3) FROM inventory_balances WHERE item_id = $1;

-- name: ApplyInventoryCost :one
-- Hareketli ağırlıklı ortalama: (eldeki × ortalama + miktar × birim
-- maliyet) / (eldeki + miktar). Bakiye güncellenmeden ÖNCE çağrılır;
-- negatif miktar (girişin iptali) aynı formülle geri alır. Elde bir şey
-- kalmıyorsa ortalama değişmez.
UPDATE inventory_items i
SET avg_unit_cost = CASE
        WHEN t.q + sqlc.arg(quantity)::numeric > 0 THEN GREATEST(0, round(
            (t.q * i.avg_unit_cost + sqlc.arg(quantity)::numeric * sqlc.arg(unit_cost)::numeric)
            / (t.q + sqlc.arg(quantity)::numeric), 4))
        ELSE i.avg_unit_cost END
FROM (SELECT COALESCE(sum(quantity), 0) AS q FROM inventory_balances WHERE item_id = sqlc.arg(item_id)::uuid) t
WHERE i.id = sqlc.arg(item_id)::uuid
RETURNING i.avg_unit_cost;

-- ============ Partiler ve bakiyeler ============

-- name: UpsertInventoryLot :one
INSERT INTO inventory_lots (organization_id, item_id, lot_no, expiry_date, production_date)
VALUES (sqlc.arg(organization_id), sqlc.arg(item_id), sqlc.arg(lot_no), sqlc.narg(expiry_date), sqlc.narg(production_date))
ON CONFLICT (item_id, lot_no, COALESCE(expiry_date, 'infinity'::date))
DO UPDATE SET production_date = COALESCE(inventory_lots.production_date, EXCLUDED.production_date)
RETURNING *;

-- name: GetInventoryLot :one
SELECT * FROM inventory_lots WHERE id = $1 AND organization_id = $2;

-- name: LockInventoryBalances :many
-- Depodaki bir malzemenin bakiyeleri, önce bozulacak önce (FEFO): SKT'li
-- partiler tarihe göre, SKT'sizler sonra.
SELECT b.id, b.lot_id, b.quantity, l.lot_no, l.expiry_date
FROM inventory_balances b
LEFT JOIN inventory_lots l ON l.id = b.lot_id
WHERE b.warehouse_id = $1 AND b.item_id = $2 AND b.quantity > 0
ORDER BY l.expiry_date NULLS LAST, l.created_at NULLS LAST, b.id
FOR UPDATE OF b;

-- name: GetInventoryBalanceQuantity :one
SELECT COALESCE(sum(quantity), 0)::numeric(14,3)
FROM inventory_balances
WHERE warehouse_id = sqlc.arg(warehouse_id) AND item_id = sqlc.arg(item_id)
  AND COALESCE(lot_id, '00000000-0000-0000-0000-000000000000'::uuid)
      = COALESCE(sqlc.narg(lot_id)::uuid, '00000000-0000-0000-0000-000000000000'::uuid);

-- name: AddInventoryBalance :one
-- Bakiyeye işaretli miktar ekler; sonuç eksiye düşerse CHECK hata verir.
INSERT INTO inventory_balances (organization_id, warehouse_id, item_id, lot_id, quantity)
VALUES (sqlc.arg(organization_id), sqlc.arg(warehouse_id), sqlc.arg(item_id), sqlc.narg(lot_id), sqlc.arg(quantity))
ON CONFLICT (warehouse_id, item_id, COALESCE(lot_id, '00000000-0000-0000-0000-000000000000'::uuid))
DO UPDATE SET quantity = inventory_balances.quantity + EXCLUDED.quantity, updated_at = now()
RETURNING quantity;

-- name: SubtractInventoryBalance :one
-- Bakiyeden düşer (miktar pozitif verilir); satır yoksa ErrNoRows, eksiye
-- düşerse CHECK hata verir. (Eksi değerle upsert, INSERT satırı CHECK'e
-- takıldığı için kullanılamaz.)
UPDATE inventory_balances
SET quantity = quantity - sqlc.arg(quantity), updated_at = now()
WHERE warehouse_id = sqlc.arg(warehouse_id) AND item_id = sqlc.arg(item_id)
  AND COALESCE(lot_id, '00000000-0000-0000-0000-000000000000'::uuid)
      = COALESCE(sqlc.narg(lot_id)::uuid, '00000000-0000-0000-0000-000000000000'::uuid)
RETURNING quantity;

-- name: ListInventoryItemBalances :many
SELECT b.warehouse_id, w.name AS warehouse_name, b.lot_id,
       COALESCE(l.lot_no, '')::text AS lot_no, l.expiry_date, l.production_date, b.quantity
FROM inventory_balances b
JOIN inventory_warehouses w ON w.id = b.warehouse_id
LEFT JOIN inventory_lots l ON l.id = b.lot_id
WHERE b.item_id = $1 AND b.organization_id = $2 AND b.quantity > 0
ORDER BY lower(w.name), l.expiry_date NULLS LAST, l.lot_no;

-- name: ListInventoryWarehouseBalances :many
-- Sayım ekranı: depodaki bütün bakiyeler (sıfırlar dahil değil).
SELECT b.item_id, i.code AS item_code, i.name AS item_name, i.unit, b.lot_id,
       COALESCE(l.lot_no, '')::text AS lot_no, l.expiry_date, b.quantity
FROM inventory_balances b
JOIN inventory_items i ON i.id = b.item_id
LEFT JOIN inventory_lots l ON l.id = b.lot_id
WHERE b.warehouse_id = $1 AND b.organization_id = $2 AND b.quantity > 0
ORDER BY lower(i.name), l.expiry_date NULLS LAST, l.lot_no;

-- name: ListInventoryLotAlerts :many
-- Bakiyesi olan, SKT'si geçmiş ya da kartın uyarı günü içinde dolacak partiler.
SELECT i.id AS item_id, i.code AS item_code, i.name AS item_name, i.unit, i.expiry_policy,
       w.id AS warehouse_id, w.name AS warehouse_name,
       l.id AS lot_id, l.lot_no, l.expiry_date, b.quantity
FROM inventory_balances b
JOIN inventory_items i ON i.id = b.item_id
JOIN inventory_warehouses w ON w.id = b.warehouse_id
JOIN inventory_lots l ON l.id = b.lot_id
WHERE b.organization_id = sqlc.arg(organization_id) AND b.quantity > 0
  AND l.expiry_date IS NOT NULL
  AND l.expiry_date <= sqlc.arg(today)::date + i.expiry_alert_days
ORDER BY l.expiry_date, lower(i.name);

-- name: InventorySummary :one
SELECT
    (SELECT count(*) FROM inventory_items WHERE organization_id = sqlc.arg(org_id)::uuid AND is_active)::int AS item_count,
    (SELECT COALESCE(sum(b.quantity * i.avg_unit_cost), 0) FROM inventory_balances b
     JOIN inventory_items i ON i.id = b.item_id
     WHERE b.organization_id = sqlc.arg(org_id)::uuid)::numeric(18,2) AS stock_value,
    (SELECT count(*) FROM inventory_balances b JOIN inventory_lots l ON l.id = b.lot_id
     WHERE b.organization_id = sqlc.arg(org_id)::uuid AND b.quantity > 0
       AND l.expiry_date < sqlc.arg(today)::date)::int AS expired_lot_count,
    (SELECT count(*) FROM inventory_balances b JOIN inventory_lots l ON l.id = b.lot_id
     JOIN inventory_items i ON i.id = b.item_id
     WHERE b.organization_id = sqlc.arg(org_id)::uuid AND b.quantity > 0
       AND l.expiry_date >= sqlc.arg(today)::date
       AND l.expiry_date <= sqlc.arg(today)::date + i.expiry_alert_days)::int AS expiring_lot_count,
    (SELECT count(*) FROM inventory_items i
     WHERE i.organization_id = sqlc.arg(org_id)::uuid AND i.is_active AND i.min_stock IS NOT NULL
       AND COALESCE((SELECT sum(quantity) FROM inventory_balances b WHERE b.item_id = i.id), 0) < i.min_stock)::int
       AS below_min_count;

-- ============ Fişler ve hareketler ============

-- name: NextInventoryDocumentSeq :one
INSERT INTO inventory_document_counters (organization_id, year, seq) VALUES ($1, $2, 1)
ON CONFLICT (organization_id, year) DO UPDATE SET seq = inventory_document_counters.seq + 1
RETURNING seq;

-- name: GetInventoryDocumentByIdempotencyKey :one
SELECT * FROM inventory_documents WHERE organization_id = $1 AND idempotency_key = $2;

-- name: CreateInventoryDocument :one
INSERT INTO inventory_documents (
    organization_id, doc_no, doc_type, doc_date, warehouse_id, target_warehouse_id, project_id,
    supplier_id, counterparty, reference_no, reason, note, reversal_of_id, idempotency_key, created_by
) VALUES (
    sqlc.arg(organization_id), sqlc.arg(doc_no), sqlc.arg(doc_type), sqlc.arg(doc_date), sqlc.arg(warehouse_id),
    sqlc.narg(target_warehouse_id), sqlc.narg(project_id), sqlc.narg(supplier_id), sqlc.arg(counterparty),
    sqlc.arg(reference_no), sqlc.arg(reason), sqlc.arg(note), sqlc.narg(reversal_of_id),
    sqlc.narg(idempotency_key), sqlc.narg(created_by)
)
RETURNING *;

-- name: CreateInventoryMovement :exec
INSERT INTO inventory_movements (organization_id, document_id, line_no, warehouse_id, item_id, lot_id, quantity, unit_cost)
VALUES (sqlc.arg(organization_id), sqlc.arg(document_id), sqlc.arg(line_no), sqlc.arg(warehouse_id),
        sqlc.arg(item_id), sqlc.narg(lot_id), sqlc.arg(quantity), sqlc.arg(unit_cost));

-- name: GetInventoryDocumentForUpdate :one
SELECT * FROM inventory_documents WHERE id = $1 AND organization_id = $2 FOR UPDATE;

-- name: MarkInventoryDocumentReversed :exec
UPDATE inventory_documents
SET status = 'reversed', reversed_at = now(), reversed_by = sqlc.narg(reversed_by), reverse_reason = sqlc.arg(reverse_reason)
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id) AND status = 'posted';

-- name: SetInventoryDocumentAttachment :exec
UPDATE inventory_documents
SET attachment_key = sqlc.arg(attachment_key), attachment_mime = sqlc.arg(attachment_mime),
    attachment_name = sqlc.arg(attachment_name)
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id);

-- name: GetInventoryDocument :one
SELECT d.*,
       w.name AS warehouse_name,
       COALESCE(tw.name, '')::text AS target_warehouse_name,
       COALESCE(p.name, '')::text AS project_name,
       COALESCE(p.project_no, '')::text AS project_no,
       COALESCE(s.legal_name, '')::text AS supplier_name,
       COALESCE(cu.full_name, '')::text AS created_by_name,
       COALESCE(ru.full_name, '')::text AS reversed_by_name,
       COALESCE(orig.doc_no, '')::text AS reversal_of_no,
       COALESCE(rev.id::text, '')::text AS reversed_by_doc_id,
       COALESCE(rev.doc_no, '')::text AS reversed_by_doc_no
FROM inventory_documents d
JOIN inventory_warehouses w ON w.id = d.warehouse_id
LEFT JOIN inventory_warehouses tw ON tw.id = d.target_warehouse_id
LEFT JOIN projects p ON p.id = d.project_id
LEFT JOIN suppliers s ON s.id = d.supplier_id
LEFT JOIN users cu ON cu.id = d.created_by
LEFT JOIN users ru ON ru.id = d.reversed_by
LEFT JOIN inventory_documents orig ON orig.id = d.reversal_of_id
LEFT JOIN inventory_documents rev ON rev.reversal_of_id = d.id
WHERE d.id = $1 AND d.organization_id = $2;

-- name: ListInventoryDocumentMovements :many
SELECT m.*, i.code AS item_code, i.name AS item_name, i.unit,
       w.name AS warehouse_name,
       COALESCE(l.lot_no, '')::text AS lot_no, l.expiry_date
FROM inventory_movements m
JOIN inventory_items i ON i.id = m.item_id
JOIN inventory_warehouses w ON w.id = m.warehouse_id
LEFT JOIN inventory_lots l ON l.id = m.lot_id
WHERE m.document_id = $1 AND m.organization_id = $2
ORDER BY m.line_no, m.quantity;

-- name: ListInventoryDocuments :many
-- Hareket geçmişi, en yeni önce. Depo filtresi aktarımın iki ucunu da
-- kapsar; malzeme filtresi fişin satırlarında arar.
SELECT d.id, d.doc_no, d.doc_type, d.doc_date, d.status, d.counterparty, d.reference_no, d.reason,
       d.created_at, d.reversal_of_id,
       w.name AS warehouse_name,
       COALESCE(tw.name, '')::text AS target_warehouse_name,
       COALESCE(p.name, '')::text AS project_name,
       COALESCE(cu.full_name, '')::text AS created_by_name,
       (SELECT count(DISTINCT m.item_id) FROM inventory_movements m WHERE m.document_id = d.id)::int AS item_count,
       COALESCE((SELECT i.name FROM inventory_movements m JOIN inventory_items i ON i.id = m.item_id
                 WHERE m.document_id = d.id ORDER BY m.line_no LIMIT 1), '')::text AS first_item_name
FROM inventory_documents d
JOIN inventory_warehouses w ON w.id = d.warehouse_id
LEFT JOIN inventory_warehouses tw ON tw.id = d.target_warehouse_id
LEFT JOIN projects p ON p.id = d.project_id
LEFT JOIN users cu ON cu.id = d.created_by
WHERE d.organization_id = sqlc.arg(organization_id)
  AND (sqlc.narg(doc_type)::text IS NULL OR d.doc_type = sqlc.narg(doc_type)::text)
  AND (sqlc.narg(warehouse_id)::uuid IS NULL OR d.warehouse_id = sqlc.narg(warehouse_id)::uuid
       OR d.target_warehouse_id = sqlc.narg(warehouse_id)::uuid)
  AND (sqlc.narg(item_id)::uuid IS NULL OR EXISTS (
       SELECT 1 FROM inventory_movements m WHERE m.document_id = d.id AND m.item_id = sqlc.narg(item_id)::uuid))
  AND (sqlc.narg(project_id)::uuid IS NULL OR d.project_id = sqlc.narg(project_id)::uuid)
ORDER BY d.doc_date DESC, d.created_at DESC
LIMIT sqlc.arg(row_limit)::int OFFSET sqlc.arg(row_offset)::int;

-- ============ Günlük stok uyarısı ============

-- name: ListInventoryAlertCounts :many
-- Firma başına: SKT'si geçmiş ve yaklaşan (bakiyesi olan) partiler,
-- minimum stoğun altındaki aktif kartlar. Yalnızca en az biri olanlar.
WITH lots AS (
    SELECT b.organization_id,
           count(*) FILTER (WHERE l.expiry_date < sqlc.arg(today)::date) AS expired,
           count(*) FILTER (WHERE l.expiry_date >= sqlc.arg(today)::date
                              AND l.expiry_date <= sqlc.arg(today)::date + i.expiry_alert_days) AS expiring
    FROM inventory_balances b
    JOIN inventory_lots l ON l.id = b.lot_id
    JOIN inventory_items i ON i.id = b.item_id
    WHERE b.quantity > 0 AND l.expiry_date IS NOT NULL
    GROUP BY b.organization_id
), low AS (
    SELECT i.organization_id, count(*) AS below
    FROM inventory_items i
    WHERE i.is_active AND i.min_stock IS NOT NULL
      AND COALESCE((SELECT sum(quantity) FROM inventory_balances b WHERE b.item_id = i.id), 0) < i.min_stock
    GROUP BY i.organization_id
)
SELECT COALESCE(lots.organization_id, low.organization_id)::uuid AS organization_id,
       COALESCE(lots.expired, 0)::int AS expired_lot_count,
       COALESCE(lots.expiring, 0)::int AS expiring_lot_count,
       COALESCE(low.below, 0)::int AS below_min_count
FROM lots
FULL JOIN low ON low.organization_id = lots.organization_id
WHERE COALESCE(lots.expired, 0) + COALESCE(lots.expiring, 0) + COALESCE(low.below, 0) > 0;

-- name: InventoryAlertSentSince :one
SELECT EXISTS (
    SELECT 1 FROM notifications
    WHERE organization_id = $1 AND user_id = $2 AND type = 'inventory_alert' AND created_at >= $3
);
