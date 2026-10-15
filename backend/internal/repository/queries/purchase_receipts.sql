-- Siparişten teslim alma (migration 0074, docs/procurement.md §12).
-- Bekleyen = sipariş - kabul - red; kabul tavanı = sipariş - önceki kabuller.
-- İptal edilmiş teslim hiçbir toplama girmez.

-- name: NextPurchaseReceiptSeq :one
-- Çağıran sipariş satırını kilitli tutar (GetPurchaseOrderForUpdate).
SELECT (COALESCE(max(sequence_no), 0) + 1)::int AS next
FROM purchase_receipts WHERE purchase_order_id = $1;

-- name: CreatePurchaseReceipt :one
INSERT INTO purchase_receipts (
    organization_id, project_id, purchase_order_id, sequence_no, received_date, delivery_note_no,
    destination, warehouse_id, notes, idempotency_key, created_by
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
RETURNING *;

-- name: CreatePurchaseReceiptItem :one
INSERT INTO purchase_receipt_items (
    organization_id, project_id, receipt_id, purchase_order_id, purchase_order_item_id,
    accepted_quantity, rejected_quantity, rejection_reason
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
RETURNING *;

-- name: GetPurchaseReceiptByIdempotencyKey :one
SELECT * FROM purchase_receipts WHERE organization_id = $1 AND idempotency_key = $2;

-- name: GetPurchaseReceiptForUpdate :one
SELECT * FROM purchase_receipts WHERE id = $1 AND organization_id = $2 AND project_id = $3 FOR UPDATE;

-- name: VoidPurchaseReceipt :one
UPDATE purchase_receipts SET voided_at = now(), voided_by = $4, void_reason = $5
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND voided_at IS NULL
RETURNING *;

-- name: ListPurchaseReceipts :many
-- Siparişin bütün teslimleri (iptaller dahil), en yeni önce.
SELECT r.*, COALESCE(w.name, '')::text AS warehouse_name, COALESCE(u.full_name, '')::text AS created_by_name
FROM purchase_receipts r
LEFT JOIN inventory_warehouses w ON w.id = r.warehouse_id
LEFT JOIN users u ON u.id = r.created_by
WHERE r.purchase_order_id = $1 AND r.organization_id = $2 AND r.project_id = $3
ORDER BY r.sequence_no DESC;

-- name: ListPurchaseReceiptItemsForOrder :many
SELECT ri.* FROM purchase_receipt_items ri
JOIN purchase_order_items poi ON poi.id = ri.purchase_order_item_id
WHERE ri.purchase_order_id = $1 AND ri.organization_id = $2
ORDER BY poi.sort_order ASC, ri.id;

-- name: ListPurchaseOrderItemReceiptTotals :many
-- Sipariş kalemi başına iptal edilmemiş teslimlerin kabul ve red toplamı.
SELECT poi.id AS purchase_order_item_id,
       COALESCE(sum(ri.accepted_quantity) FILTER (WHERE r.voided_at IS NULL), 0)::numeric(12,2) AS accepted_quantity,
       COALESCE(sum(ri.rejected_quantity) FILTER (WHERE r.voided_at IS NULL), 0)::numeric(12,2) AS rejected_quantity
FROM purchase_order_items poi
LEFT JOIN purchase_receipt_items ri ON ri.purchase_order_item_id = poi.id
LEFT JOIN purchase_receipts r ON r.id = ri.receipt_id
WHERE poi.purchase_order_id = $1 AND poi.organization_id = $2
GROUP BY poi.id;

-- name: ListPurchaseOrderReceiptSummaries :many
-- Sipariş başına teslim özeti: hiç teslim var mı, her kalem tamamlandı mı,
-- kabul edilen değer (KDV hariç / dahil -- vergi siparişin toplamıyla aynı
-- yuvarlamayla) ve siparişe bağlı onaylı masraflar. purchase_order_id
-- verilirse yalnızca o sipariş.
WITH it AS (
    SELECT poi.purchase_order_id, poi.quantity, poi.unit_price,
           COALESCE(sum(ri.accepted_quantity) FILTER (WHERE r.voided_at IS NULL), 0) AS accepted,
           COALESCE(sum(ri.rejected_quantity) FILTER (WHERE r.voided_at IS NULL), 0) AS rejected
    FROM purchase_order_items poi
    LEFT JOIN purchase_receipt_items ri ON ri.purchase_order_item_id = poi.id
    LEFT JOIN purchase_receipts r ON r.id = ri.receipt_id
    WHERE poi.project_id = sqlc.arg(project_id)::uuid AND poi.organization_id = sqlc.arg(organization_id)::uuid
    GROUP BY poi.purchase_order_id, poi.id, poi.quantity, poi.unit_price
),
costed AS (
    SELECT e.purchase_order_id, sum(e.amount) AS total
    FROM project_expenses e
    WHERE e.project_id = sqlc.arg(project_id)::uuid AND e.purchase_order_id IS NOT NULL
      AND e.voided_at IS NULL AND e.approval_status = 'approved'
    GROUP BY e.purchase_order_id
),
po_sum AS (
    SELECT po.id, po.tax_rate,
           (sum(it.accepted) + sum(it.rejected) > 0) AS has_receipts,
           bool_and(it.quantity - it.accepted - it.rejected <= 0) AS fully_received,
           sum(round(it.accepted * it.unit_price, 2)) AS accepted_net
    FROM purchase_orders po
    JOIN it ON it.purchase_order_id = po.id
    WHERE po.project_id = sqlc.arg(project_id)::uuid AND po.organization_id = sqlc.arg(organization_id)::uuid
      AND (sqlc.narg(purchase_order_id)::uuid IS NULL OR po.id = sqlc.narg(purchase_order_id)::uuid)
    GROUP BY po.id, po.tax_rate
)
SELECT s.id AS purchase_order_id,
       s.has_receipts::boolean AS has_receipts,
       s.fully_received::boolean AS fully_received,
       s.accepted_net::numeric(18,2) AS accepted_net,
       (s.accepted_net + round(s.accepted_net * s.tax_rate / 100, 2))::numeric(18,2) AS accepted_gross,
       COALESCE(c.total, 0)::numeric(18,2) AS costed
FROM po_sum s
LEFT JOIN costed c ON c.purchase_order_id = s.id;

-- name: CountActivePurchaseReceipts :one
SELECT count(*)::int FROM purchase_receipts WHERE purchase_order_id = $1 AND voided_at IS NULL;

-- name: VoidCommitmentByID :one
-- Sipariş kapatılırken teslim alınmayan kısmı serbest bırakmak için
-- (yalnızca bu siparişin kalemlerinden doğan taahhüt).
UPDATE project_commitments SET status = 'voided', voided_at = now(), voided_by = $4, void_reason = $5
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'active' AND source_type = 'purchase_order'
RETURNING *;
