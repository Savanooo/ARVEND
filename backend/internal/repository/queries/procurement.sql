-- ARVEND V2 — Sprint 4: Procurement Foundation. Suppliers + Purchase
-- Request + RFQ + Supplier Quotations + Purchase Order. Bkz.
-- docs/procurement.md. Kalem listelerinin "güncelleme" deseni
-- project_change_order_items İLE AYNIDIR: DeleteXItems (tümünü sil) +
-- CreateXItem (yeniden ekle) döngüsü -- diff/patch İCAT EDİLMEDİ.

-- ============ Tedarikçiler (organizasyon-seviyesi) ============

-- name: CreateSupplier :one
INSERT INTO suppliers (
    organization_id, code, legal_name, trade_name, tax_number, tax_office,
    contact_name, email, phone, address, city, country, iban_enc, notes, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
RETURNING *;

-- name: ListSuppliers :many
-- TÜM tedarikçiler (aktif+arşivlenmiş) döner -- organization_cost_codes
-- İLE AYNI ilke, "arşivlenmiş göster" filtrelemesi istemci tarafındadır.
SELECT * FROM suppliers WHERE organization_id = $1 ORDER BY code ASC;

-- name: GetSupplier :one
SELECT * FROM suppliers WHERE id = $1 AND organization_id = $2;

-- name: UpdateSupplier :one
UPDATE suppliers SET
    legal_name = $3, trade_name = $4, tax_number = $5, tax_office = $6,
    contact_name = $7, email = $8, phone = $9, address = $10, city = $11,
    country = $12, iban_enc = $13, notes = $14
WHERE id = $1 AND organization_id = $2
RETURNING *;

-- name: ArchiveSupplier :execrows
UPDATE suppliers SET is_active = false WHERE id = $1 AND organization_id = $2;

-- name: ReactivateSupplier :execrows
UPDATE suppliers SET is_active = true WHERE id = $1 AND organization_id = $2;

-- ============ Sayaçlar ============

-- name: NextPurchaseRequestSeq :one
INSERT INTO purchase_request_counters (organization_id, year, seq) VALUES ($1, $2, 1)
ON CONFLICT (organization_id, year) DO UPDATE SET seq = purchase_request_counters.seq + 1
RETURNING seq;

-- name: NextRfqSeq :one
INSERT INTO rfq_counters (organization_id, year, seq) VALUES ($1, $2, 1)
ON CONFLICT (organization_id, year) DO UPDATE SET seq = rfq_counters.seq + 1
RETURNING seq;

-- name: NextPurchaseOrderSeq :one
INSERT INTO purchase_order_counters (organization_id, year, seq) VALUES ($1, $2, 1)
ON CONFLICT (organization_id, year) DO UPDATE SET seq = purchase_order_counters.seq + 1
RETURNING seq;

-- ============ Purchase Request ============

-- name: CreatePurchaseRequest :one
INSERT INTO purchase_requests (organization_id, project_id, pr_no, title, description, needed_by, requested_by)
VALUES ($1,$2,$3,$4,$5,$6,$7)
RETURNING *;

-- name: ListPurchaseRequests :many
SELECT * FROM purchase_requests WHERE project_id = $1 AND organization_id = $2 ORDER BY created_at DESC;

-- name: GetPurchaseRequest :one
SELECT * FROM purchase_requests WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- name: GetPurchaseRequestForUpdate :one
SELECT * FROM purchase_requests WHERE id = $1 AND organization_id = $2 AND project_id = $3 FOR UPDATE;

-- name: UpdatePurchaseRequestFields :one
-- Yalnızca draft'ta -- WHERE status='draft' koşulu servis katmanındaki
-- ErrPurchaseRequestNotEditable'a düşer (bkz. ContractDraft İLE AYNI ilke).
UPDATE purchase_requests SET title = $4, description = $5, needed_by = $6
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- name: RecomputePurchaseRequestTotal :one
UPDATE purchase_requests pr
SET estimated_total = sub.total
FROM (SELECT COALESCE(sum(estimated_total),0)::numeric(18,2) AS total
      FROM purchase_request_items WHERE purchase_request_id = $1) sub
WHERE pr.id = $1 AND pr.organization_id = $2 AND pr.project_id = $3
RETURNING pr.*;

-- name: SubmitPurchaseRequest :one
UPDATE purchase_requests SET status = 'submitted', submitted_at = now()
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- name: WithdrawPurchaseRequest :one
UPDATE purchase_requests SET status = 'draft'
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'submitted'
RETURNING *;

-- name: ApprovePurchaseRequest :one
UPDATE purchase_requests SET status = 'approved', approved_at = now(), approved_by = $4
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'submitted'
RETURNING *;

-- name: RejectPurchaseRequest :one
UPDATE purchase_requests SET status = 'rejected', rejected_at = now(), rejected_by = $4, rejection_reason = $5
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'submitted'
RETURNING *;

-- name: CancelPurchaseRequest :one
UPDATE purchase_requests SET status = 'cancelled', cancelled_at = now(), cancelled_by = $4, cancel_reason = $5
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status IN ('draft','submitted','approved')
RETURNING *;

-- ============ Purchase Request Kalemleri ============

-- name: CreatePurchaseRequestItem :one
INSERT INTO purchase_request_items (
    organization_id, project_id, purchase_request_id, wbs_node_id, cost_code_id, budget_line_id,
    description, quantity, unit, estimated_unit_cost, estimated_total, notes, sort_order
) VALUES (
    $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,
    CASE WHEN $10::numeric IS NOT NULL THEN round($8::numeric * $10::numeric, 2) ELSE $11::numeric END,
    $12,$13
)
RETURNING *;

-- name: ListPurchaseRequestItems :many
SELECT * FROM purchase_request_items WHERE purchase_request_id = $1 ORDER BY sort_order ASC;

-- name: DeletePurchaseRequestItems :exec
DELETE FROM purchase_request_items WHERE purchase_request_id = $1 AND organization_id = $2 AND project_id = $3;

-- ============ RFQ ============

-- name: CreateRFQ :one
INSERT INTO rfqs (organization_id, project_id, rfq_no, purchase_request_id, title, issue_date, due_date, notes, created_by)
VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
RETURNING *;

-- name: ListRFQs :many
SELECT * FROM rfqs WHERE project_id = $1 AND organization_id = $2 ORDER BY created_at DESC;

-- name: GetRFQ :one
SELECT * FROM rfqs WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- name: GetRFQForUpdate :one
SELECT * FROM rfqs WHERE id = $1 AND organization_id = $2 AND project_id = $3 FOR UPDATE;

-- name: UpdateRFQFields :one
UPDATE rfqs SET title = $4, due_date = $5, notes = $6
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- name: IssueRFQ :one
UPDATE rfqs SET status = 'issued'
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- name: CloseRFQ :one
UPDATE rfqs SET status = 'closed'
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'issued'
RETURNING *;

-- name: CancelRFQ :one
UPDATE rfqs SET status = 'cancelled'
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status IN ('draft','issued')
RETURNING *;

-- name: AwardRFQ :one
-- Award TEK BAŞINA actual cost oluşturmaz -- yalnızca "hangi teklif
-- kazandı" kararını kalıcı hale getirir (bkz. domain yorumu). status
-- 'issued' -> 'closed' aynı anda geçer (bkz. migration §4 durum makinesi).
UPDATE rfqs SET status = 'closed', awarded_quotation_id = $4, awarded_at = now(), awarded_by = $5, award_notes = $6
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'issued'
RETURNING *;

-- ============ RFQ Tedarikçileri ============

-- name: AddRFQSupplier :one
INSERT INTO rfq_suppliers (organization_id, rfq_id, supplier_id)
VALUES ($1,$2,$3)
RETURNING *;

-- name: ListRFQSuppliers :many
SELECT rs.*, s.code AS supplier_code, s.legal_name AS supplier_legal_name
FROM rfq_suppliers rs
JOIN suppliers s ON s.id = rs.supplier_id
WHERE rs.rfq_id = $1
ORDER BY s.code ASC;

-- name: DeleteRFQSuppliers :exec
DELETE FROM rfq_suppliers WHERE rfq_id = $1 AND organization_id = $2;

-- name: MarkRFQSupplierResponded :execrows
UPDATE rfq_suppliers SET response_status = 'responded' WHERE rfq_id = $1 AND supplier_id = $2;

-- ============ RFQ Kalemleri ============

-- name: CreateRFQItem :one
INSERT INTO rfq_items (
    organization_id, project_id, rfq_id, source_pr_item_id, wbs_node_id, cost_code_id, budget_line_id,
    description, quantity, unit, sort_order
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
RETURNING *;

-- name: ListRFQItems :many
SELECT * FROM rfq_items WHERE rfq_id = $1 ORDER BY sort_order ASC;

-- name: GetRFQItem :one
SELECT * FROM rfq_items WHERE id = $1 AND rfq_id = $2;

-- name: DeleteRFQItems :exec
DELETE FROM rfq_items WHERE rfq_id = $1 AND organization_id = $2 AND project_id = $3;

-- ============ Tedarikçi Teklifleri (Supplier Quotations) ============

-- name: CreateSupplierQuotation :one
INSERT INTO supplier_quotations (
    organization_id, project_id, rfq_id, supplier_id, quotation_number, quotation_date, valid_until,
    currency, discount, tax_rate, delivery_days, payment_terms, notes, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
RETURNING *;

-- name: ListSupplierQuotations :many
-- Teklif Karşılaştırma ekranının kaynağı -- tedarikçi kimliğini de
-- (N+1'siz) getirir.
SELECT sq.*, s.code AS supplier_code, s.legal_name AS supplier_legal_name
FROM supplier_quotations sq
JOIN suppliers s ON s.id = sq.supplier_id
WHERE sq.rfq_id = $1 AND sq.organization_id = $2
ORDER BY sq.total ASC;

-- name: GetSupplierQuotation :one
SELECT * FROM supplier_quotations WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- name: GetSupplierQuotationForUpdate :one
SELECT * FROM supplier_quotations WHERE id = $1 AND organization_id = $2 AND project_id = $3 FOR UPDATE;

-- name: UpdateSupplierQuotationFields :one
UPDATE supplier_quotations SET
    quotation_number = $4, quotation_date = $5, valid_until = $6, discount = $7,
    tax_rate = $8, delivery_days = $9, payment_terms = $10, notes = $11
WHERE id = $1 AND organization_id = $2 AND project_id = $3
RETURNING *;

-- name: RecomputeSupplierQuotationTotals :one
-- subtotal = kalemlerin toplamı; tax = round((subtotal-discount)*tax_rate/100,2);
-- total = subtotal - discount + tax (project_change_orders'ın subtotal/
-- vat_amount/grand_total İLE AYNI SQL-taraflı hesaplama ilkesi).
UPDATE supplier_quotations sq
SET subtotal = sub.total,
    tax = round(GREATEST(sub.total - sq.discount, 0) * sq.tax_rate / 100, 2),
    total = GREATEST(sub.total - sq.discount, 0) + round(GREATEST(sub.total - sq.discount, 0) * sq.tax_rate / 100, 2)
FROM (SELECT COALESCE(sum(line_total),0)::numeric(18,2) AS total
      FROM quotation_items WHERE quotation_id = $1) sub
WHERE sq.id = $1 AND sq.organization_id = $2 AND sq.project_id = $3
RETURNING sq.*;

-- name: DeleteSupplierQuotation :execrows
DELETE FROM supplier_quotations WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- ============ Teklif Kalemleri ============

-- name: CreateQuotationItem :one
INSERT INTO quotation_items (organization_id, project_id, quotation_id, rfq_item_id, quantity, unit_price, line_total, notes)
VALUES ($1,$2,$3,$4,$5,$6, round($5::numeric * $6::numeric, 2), $7)
RETURNING *;

-- name: ListQuotationItems :many
SELECT * FROM quotation_items WHERE quotation_id = $1;

-- name: DeleteQuotationItems :exec
DELETE FROM quotation_items WHERE quotation_id = $1 AND organization_id = $2 AND project_id = $3;

-- name: ListQuotationItemsForRFQ :many
-- Teklif Karşılaştırma ızgarası: bir RFQ'nun TÜM tekliflerinin TÜM
-- kalemlerini, hangi RFQ kalemine karşılık geldiğiyle birlikte tek
-- sorguda getirir (N+1 yok) -- satır=rfq_item, sütun=tedarikçi eşlemesi
-- Go tarafında gruplanır.
SELECT qi.*, sq.supplier_id, s.code AS supplier_code, s.legal_name AS supplier_legal_name
FROM quotation_items qi
JOIN supplier_quotations sq ON sq.id = qi.quotation_id
JOIN suppliers s ON s.id = sq.supplier_id
WHERE sq.rfq_id = $1 AND sq.organization_id = $2;

-- ============ Purchase Order ============

-- name: CreatePurchaseOrder :one
INSERT INTO purchase_orders (
    organization_id, project_id, po_no, supplier_id, source_rfq_id, source_quotation_id, currency,
    issue_date, expected_delivery_date, payment_terms, delivery_address, notes, tax_rate, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
RETURNING *;

-- name: ListPurchaseOrders :many
SELECT po.*, s.code AS supplier_code, s.legal_name AS supplier_legal_name
FROM purchase_orders po
JOIN suppliers s ON s.id = po.supplier_id
WHERE po.project_id = $1 AND po.organization_id = $2
ORDER BY po.created_at DESC;

-- name: GetPurchaseOrder :one
SELECT * FROM purchase_orders WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- name: GetPurchaseOrderForUpdate :one
SELECT * FROM purchase_orders WHERE id = $1 AND organization_id = $2 AND project_id = $3 FOR UPDATE;

-- name: UpdatePurchaseOrderFields :one
UPDATE purchase_orders SET
    issue_date = $4, expected_delivery_date = $5, payment_terms = $6, delivery_address = $7,
    notes = $8, tax_rate = $9
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- name: RecomputePurchaseOrderTotals :one
UPDATE purchase_orders po
SET subtotal = sub.total,
    tax = round(sub.total * po.tax_rate / 100, 2),
    total = sub.total + round(sub.total * po.tax_rate / 100, 2)
FROM (SELECT COALESCE(sum(line_total),0)::numeric(18,2) AS total
      FROM purchase_order_items WHERE purchase_order_id = $1) sub
WHERE po.id = $1 AND po.organization_id = $2 AND po.project_id = $3
RETURNING po.*;

-- name: ApprovePurchaseOrder :one
UPDATE purchase_orders SET status = 'approved', approved_at = now(), approved_by = $4
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- name: CancelPurchaseOrder :one
UPDATE purchase_orders SET status = 'cancelled', cancelled_at = now(), cancelled_by = $4, cancel_reason = $5
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status IN ('draft','approved')
RETURNING *;

-- name: ClosePurchaseOrder :one
UPDATE purchase_orders SET status = 'closed', closed_at = now(), closed_by = $4
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'approved'
RETURNING *;

-- ============ Purchase Order Kalemleri ============

-- name: CreatePurchaseOrderItem :one
INSERT INTO purchase_order_items (
    organization_id, project_id, purchase_order_id, wbs_node_id, cost_code_id, budget_line_id,
    description, quantity, unit, unit_price, line_total, sort_order
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10, round($8::numeric * $10::numeric, 2), $11)
RETURNING *;

-- name: ListPurchaseOrderItems :many
SELECT * FROM purchase_order_items WHERE purchase_order_id = $1 ORDER BY sort_order ASC;

-- name: DeletePurchaseOrderItems :exec
DELETE FROM purchase_order_items WHERE purchase_order_id = $1 AND organization_id = $2 AND project_id = $3;
