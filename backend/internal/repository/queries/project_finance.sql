-- ============ Ödeme Planı ============

-- name: CreatePaymentPlanItem :one
INSERT INTO project_payment_plan_items (
    organization_id, project_id, sort_order, name, percentage, planned_amount, due_date, notes, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
RETURNING *;

-- name: GetPaymentPlanItem :one
SELECT * FROM project_payment_plan_items WHERE id = $1 AND organization_id = $2;

-- ListPaymentPlanItems, her kalemin o kaleme bağlı GEÇERLİ (void
-- edilmemiş) tahsilat toplamını da getirir -- böylece partial/paid
-- durumu ve kalan tutar, kalem başına ayrı sorgu açmadan (N+1 yok)
-- okuma anında türetilebilir.
-- name: ListPaymentPlanItems :many
SELECT p.*,
       COALESCE((SELECT sum(c.amount) FROM project_collections c
                 WHERE c.payment_plan_item_id = p.id AND c.voided_at IS NULL), 0)::numeric(12,2) AS collected_amount
FROM project_payment_plan_items p
WHERE p.project_id = $1 AND p.organization_id = $2
ORDER BY p.sort_order ASC, p.created_at ASC;

-- name: UpdatePaymentPlanItem :one
UPDATE project_payment_plan_items
SET sort_order = $3, name = $4, percentage = $5, planned_amount = $6, due_date = $7, notes = $8
WHERE id = $1 AND organization_id = $2 AND status <> 'cancelled'
RETURNING *;

-- name: CancelPaymentPlanItem :one
UPDATE project_payment_plan_items SET status = 'cancelled'
WHERE id = $1 AND organization_id = $2 AND status <> 'cancelled'
RETURNING *;

-- ============ Tahsilatlar ============

-- name: CreateCollection :one
INSERT INTO project_collections (
    organization_id, project_id, payment_plan_item_id, amount, currency,
    received_date, payment_method, description, reference_no, idempotency_key, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
RETURNING *;

-- name: GetCollectionByIdempotencyKey :one
SELECT * FROM project_collections
WHERE project_id = $1 AND idempotency_key = $2;

-- name: ListCollections :many
SELECT * FROM project_collections
WHERE project_id = $1 AND organization_id = $2
ORDER BY received_date DESC, created_at DESC;

-- name: VoidCollection :one
UPDATE project_collections
SET voided_at = now(), voided_by = $3, void_reason = $4
WHERE id = $1 AND organization_id = $2 AND voided_at IS NULL
RETURNING *;

-- ============ Masraflar ============

-- name: CreateExpense :one
INSERT INTO project_expenses (
    organization_id, project_id, category, description, amount, currency,
    expense_date, supplier_name, invoice_no, notes, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
RETURNING *;

-- name: ListExpenses :many
SELECT * FROM project_expenses
WHERE project_id = $1 AND organization_id = $2
ORDER BY expense_date DESC, created_at DESC;

-- name: UpdateExpense :one
UPDATE project_expenses
SET category = $3, description = $4, amount = $5, expense_date = $6,
    supplier_name = $7, invoice_no = $8, notes = $9
WHERE id = $1 AND organization_id = $2 AND voided_at IS NULL
RETURNING *;

-- name: VoidExpense :one
UPDATE project_expenses
SET voided_at = now(), voided_by = $3, void_reason = $4
WHERE id = $1 AND organization_id = $2 AND voided_at IS NULL
RETURNING *;

-- ============ Faturalar ============

-- name: CreateInvoice :one
INSERT INTO project_invoices (
    organization_id, project_id, invoice_no, invoice_type, invoice_date,
    due_date, amount, currency, status, customer_name, notes, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
RETURNING *;

-- name: ListInvoices :many
SELECT * FROM project_invoices
WHERE project_id = $1 AND organization_id = $2
ORDER BY invoice_date DESC, created_at DESC;

-- name: GetInvoice :one
SELECT * FROM project_invoices WHERE id = $1 AND organization_id = $2;

-- name: UpdateInvoiceStatus :one
UPDATE project_invoices SET status = $3
WHERE id = $1 AND organization_id = $2
RETURNING *;

-- ============ Taşeronlar ============

-- name: CreateSubcontractor :one
INSERT INTO project_subcontractors (
    organization_id, project_id, name, company_name, phone, email, work_description,
    contract_amount, currency, start_date, end_date, status, notes, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
RETURNING *;

-- name: GetSubcontractor :one
SELECT * FROM project_subcontractors WHERE id = $1 AND organization_id = $2;

-- ListSubcontractors, her taşeronun GEÇERLİ ödeme toplamını da getirir
-- (kalan = contract_amount - paid, kart başına ayrı sorgu yok).
-- name: ListSubcontractors :many
SELECT s.*,
       COALESCE((SELECT sum(p.amount) FROM project_subcontractor_payments p
                 WHERE p.subcontractor_id = s.id AND p.voided_at IS NULL), 0)::numeric(12,2) AS paid_amount
FROM project_subcontractors s
WHERE s.project_id = $1 AND s.organization_id = $2
ORDER BY s.created_at ASC;

-- name: UpdateSubcontractor :one
UPDATE project_subcontractors
SET name = $3, company_name = $4, phone = $5, email = $6, work_description = $7,
    contract_amount = $8, start_date = $9, end_date = $10, status = $11, notes = $12
WHERE id = $1 AND organization_id = $2
RETURNING *;

-- ============ Taşeron Ödemeleri ============

-- name: CreateSubcontractorPayment :one
INSERT INTO project_subcontractor_payments (
    organization_id, project_id, subcontractor_id, amount, currency,
    paid_date, description, idempotency_key, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
RETURNING *;

-- name: GetSubcontractorPaymentByIdempotencyKey :one
SELECT * FROM project_subcontractor_payments
WHERE project_id = $1 AND idempotency_key = $2;

-- name: ListSubcontractorPayments :many
SELECT * FROM project_subcontractor_payments
WHERE project_id = $1 AND organization_id = $2
ORDER BY paid_date DESC, created_at DESC;

-- name: VoidSubcontractorPayment :one
UPDATE project_subcontractor_payments
SET voided_at = now(), voided_by = $3, void_reason = $4
WHERE id = $1 AND organization_id = $2 AND voided_at IS NULL
RETURNING *;

-- ============ Finans Özeti ============

-- GetProjectFinancialSummary, projenin TÜM finans özetini TEK sorguda
-- üretir. Bütün toplama/çıkarma işlemleri burada numeric üzerinde yapılır
-- -- Go tarafında hiçbir para aritmetiği yoktur (float64 yalnızca taşıma
-- tipidir), böylece kuruş hassasiyeti korunur.
--
-- İki maliyet/kâr kavramı bilinçli olarak ayrı tutulur:
--   realized_cost  = gerçekleşen masraflar + taşerona GERÇEKTEN ödenen
--   committed_cost = realized_cost + taşeron sözleşmelerinin KALAN taahhüdü
-- name: GetProjectFinancialSummary :one
WITH proj AS (
    SELECT pr.contract_amount, pr.currency FROM projects pr
    WHERE pr.id = $1 AND pr.organization_id = $2
),
coll AS (
    SELECT COALESCE(sum(amount), 0)::numeric(12,2) AS total
    FROM project_collections WHERE project_id = $1 AND voided_at IS NULL
),
planned AS (
    SELECT COALESCE(sum(planned_amount), 0)::numeric(12,2) AS total
    FROM project_payment_plan_items WHERE project_id = $1 AND status <> 'cancelled'
),
expense_total AS (
    SELECT COALESCE(sum(amount), 0)::numeric(12,2) AS total
    FROM project_expenses WHERE project_id = $1 AND voided_at IS NULL
),
subpay AS (
    SELECT COALESCE(sum(amount), 0)::numeric(12,2) AS total
    FROM project_subcontractor_payments WHERE project_id = $1 AND voided_at IS NULL
),
subcommit AS (
    -- İptal edilmiş taşeron sözleşmeleri taahhüde dahil edilmez.
    SELECT COALESCE(sum(contract_amount), 0)::numeric(12,2) AS total
    FROM project_subcontractors WHERE project_id = $1 AND status <> 'cancelled'
),
subremaining AS (
    -- Kalan taahhüt taşeron BAŞINA hesaplanır ve negatife düşürülmez:
    -- fazla ödenmiş bir taşeron, diğerlerinin kalan taahhüdünü azaltmamalı.
    SELECT COALESCE(sum(GREATEST(s.contract_amount - COALESCE(p.paid, 0), 0)), 0)::numeric(12,2) AS total
    FROM project_subcontractors s
    LEFT JOIN (
        SELECT subcontractor_id, sum(amount) AS paid
        FROM project_subcontractor_payments WHERE project_id = $1 AND voided_at IS NULL
        GROUP BY subcontractor_id
    ) p ON p.subcontractor_id = s.id
    WHERE s.project_id = $1 AND s.status <> 'cancelled'
),
inv AS (
    SELECT
        COALESCE(sum(amount) FILTER (WHERE status IN ('issued','sent','paid')), 0)::numeric(12,2) AS issued_total,
        COALESCE(sum(amount) FILTER (WHERE status = 'paid'), 0)::numeric(12,2) AS paid_total
    FROM project_invoices WHERE project_id = $1 AND invoice_type = 'sales'
)
SELECT
    proj.contract_amount,
    proj.currency,
    planned.total AS planned_collections,
    coll.total    AS collected_amount,
    (proj.contract_amount - coll.total)::numeric(12,2) AS remaining_receivable,
    expense_total.total     AS total_expenses,
    subcommit.total    AS total_subcontractor_commitment,
    subpay.total       AS subcontractor_paid,
    subremaining.total AS subcontractor_remaining,
    inv.issued_total   AS issued_invoice_total,
    inv.paid_total     AS paid_invoice_total,
    (expense_total.total + subpay.total)::numeric(12,2) AS realized_cost,
    (expense_total.total + subpay.total + subremaining.total)::numeric(12,2) AS committed_cost,
    (proj.contract_amount - (expense_total.total + subpay.total))::numeric(12,2) AS realized_gross_profit,
    (proj.contract_amount - (expense_total.total + subpay.total + subremaining.total))::numeric(12,2) AS estimated_gross_profit,
    CASE WHEN proj.contract_amount > 0
         THEN round((proj.contract_amount - (expense_total.total + subpay.total)) * 100 / proj.contract_amount, 2)
         ELSE 0 END::numeric(7,2) AS realized_margin_percent,
    CASE WHEN proj.contract_amount > 0
         THEN round((proj.contract_amount - (expense_total.total + subpay.total + subremaining.total)) * 100 / proj.contract_amount, 2)
         ELSE 0 END::numeric(7,2) AS estimated_margin_percent
FROM proj, coll, planned, expense_total, subpay, subcommit, subremaining, inv;

-- ============ Proje Olayları (audit) ============

-- name: CreateProjectEvent :one
INSERT INTO project_events (organization_id, project_id, event_type, user_id, metadata)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: ListProjectEvents :many
SELECT * FROM project_events
WHERE project_id = $1 AND organization_id = $2
ORDER BY created_at ASC;
