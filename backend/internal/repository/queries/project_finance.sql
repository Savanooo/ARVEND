-- ============ Ödeme Planı ============

-- name: CreatePaymentPlanItem :one
INSERT INTO project_payment_plan_items (
    organization_id, project_id, sort_order, name, percentage, planned_amount, due_date, notes, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
RETURNING *;

-- name: GetPaymentPlanItem :one
-- project_id EKLENDİ: başka bir projenin kalem UUID'si, aynı organizasyon
-- içinde bile olsa buradan görüntülenemez (bkz. IDOR denetim bulgusu --
-- child-resource sorguları yalnızca organization_id ile değil, ebeveyn
-- project_id ile de sınırlanmalı).
SELECT * FROM project_payment_plan_items WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- ListPaymentPlanItems, her kalemin o kaleme bağlı GEÇERLİ (void
-- edilmemiş) tahsilat toplamını da getirir -- böylece partial/paid
-- durumu ve kalan tutar, kalem başına ayrı sorgu açmadan (N+1 yok)
-- okuma anında türetilebilir.
-- name: ListPaymentPlanItems :many
SELECT p.*,
       COALESCE((SELECT sum(c.amount) FROM project_collections c
                 WHERE c.payment_plan_item_id = p.id AND c.voided_at IS NULL), 0)::numeric(18,2) AS collected_amount
FROM project_payment_plan_items p
WHERE p.project_id = $1 AND p.organization_id = $2
ORDER BY p.sort_order ASC, p.created_at ASC;

-- name: UpdatePaymentPlanItem :one
-- project_id EKLENDİ (bkz. GetPaymentPlanItem notu).
UPDATE project_payment_plan_items
SET sort_order = $3, name = $4, percentage = $5, planned_amount = $6, due_date = $7, notes = $8
WHERE id = $1 AND organization_id = $2 AND status <> 'cancelled' AND project_id = $9
RETURNING *;

-- name: CancelPaymentPlanItem :one
-- project_id EKLENDİ (bkz. GetPaymentPlanItem notu).
UPDATE project_payment_plan_items SET status = 'cancelled'
WHERE id = $1 AND organization_id = $2 AND status <> 'cancelled' AND project_id = $3
RETURNING *;

-- GetPaymentPlanTotal, planlanan toplamı SQL/numeric üzerinde hesaplar.
-- Bu değer daha önce Go'da float64 ile satır satır toplanıyordu; aynı
-- kalemlerin financial-summary'deki "planned_collections" alanıyla ikili
-- birleştirme sırasında ikili (float) yuvarlama farkından ötürü
-- ayrışabiliyordu (bkz. denetim bulgusu).
-- name: GetPaymentPlanTotal :one
SELECT COALESCE(sum(planned_amount), 0)::numeric(18,2) AS total
FROM project_payment_plan_items
WHERE project_id = $1 AND organization_id = $2 AND status <> 'cancelled';

-- ============ Tahsilatlar ============

-- name: CreateCollection :one
INSERT INTO project_collections (
    organization_id, project_id, payment_plan_item_id, amount, currency,
    received_date, payment_method, description, reference_no, idempotency_key, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
RETURNING *;

-- GetCollection, void durumundan BAĞIMSIZ okur. VoidCollection'ın
-- "bulunamadı" ile "zaten iptal edilmiş" durumlarını ayırt etmesi için
-- kullanılır (bkz. denetim bulgusu: ikisi de yanlışlıkla 404 dönüyordu).
-- project_id EKLENDİ (bkz. GetPaymentPlanItem notu).
-- name: GetCollection :one
SELECT * FROM project_collections WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- name: GetCollectionByIdempotencyKey :one
SELECT * FROM project_collections
WHERE project_id = $1 AND idempotency_key = $2;

-- name: ListCollections :many
SELECT * FROM project_collections
WHERE project_id = $1 AND organization_id = $2
ORDER BY received_date DESC, created_at DESC;

-- name: VoidCollection :one
-- project_id EKLENDİ (bkz. GetPaymentPlanItem notu).
UPDATE project_collections
SET voided_at = now(), voided_by = $3, void_reason = $4
WHERE id = $1 AND organization_id = $2 AND voided_at IS NULL AND project_id = $5
RETURNING *;

-- ============ Masraflar ============

-- name: CreateExpense :one
-- change_order_id OPSİYONELDİR: bir masrafı bir ek işe etiketler. Bu
-- SADECE proje toplamının filtrelenmiş bir görünümü içindir (bkz.
-- project_change_orders.sql ListChangeOrders notu) -- masraf, NULL
-- olsun ya da olmasın, proje toplamına yalnızca BİR KEZ girer.
INSERT INTO project_expenses (
    organization_id, project_id, category, description, amount, currency,
    expense_date, supplier_name, invoice_no, notes, idempotency_key, created_by, change_order_id
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
RETURNING *;

-- GetExpense, void durumundan BAĞIMSIZ okur (bkz. GetCollection notu).
-- project_id EKLENDİ (bkz. GetPaymentPlanItem notu).
-- name: GetExpense :one
SELECT * FROM project_expenses WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- name: GetExpenseByIdempotencyKey :one
SELECT * FROM project_expenses
WHERE project_id = $1 AND idempotency_key = $2;

-- name: ListExpenses :many
SELECT * FROM project_expenses
WHERE project_id = $1 AND organization_id = $2
ORDER BY expense_date DESC, created_at DESC;

-- name: UpdateExpense :one
-- project_id EKLENDİ (bkz. GetPaymentPlanItem notu).
UPDATE project_expenses
SET category = $3, description = $4, amount = $5, expense_date = $6,
    supplier_name = $7, invoice_no = $8, notes = $9
WHERE id = $1 AND organization_id = $2 AND voided_at IS NULL AND project_id = $10
RETURNING *;

-- name: VoidExpense :one
-- project_id EKLENDİ (bkz. GetPaymentPlanItem notu).
UPDATE project_expenses
SET voided_at = now(), voided_by = $3, void_reason = $4
WHERE id = $1 AND organization_id = $2 AND voided_at IS NULL AND project_id = $5
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
-- project_id EKLENDİ (bkz. GetPaymentPlanItem notu).
SELECT * FROM project_invoices WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- name: UpdateInvoiceStatus :one
-- project_id EKLENDİ (bkz. GetPaymentPlanItem notu).
UPDATE project_invoices SET status = $3
WHERE id = $1 AND organization_id = $2 AND project_id = $4
RETURNING *;

-- ============ Taşeronlar ============

-- name: CreateSubcontractor :one
-- change_order_id OPSİYONELDİR (bkz. CreateExpense notu).
INSERT INTO project_subcontractors (
    organization_id, project_id, name, company_name, phone, email, work_description,
    contract_amount, currency, start_date, end_date, status, notes, created_by, change_order_id
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
RETURNING *;

-- name: GetSubcontractor :one
-- project_id EKLENDİ: CreateSubcontractorPayment'ın taşeronu URL'deki
-- projeye ait olduğunu doğrulaması için (bkz. GetPaymentPlanItem notu --
-- aksi halde Proje A'ya yetkili biri, Proje B'nin taşeron UUID'sini
-- bilerek Proje A URL'si üzerinden ona ödeme kaydedebilirdi).
SELECT * FROM project_subcontractors WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- ListSubcontractors, her taşeronun GEÇERLİ ödeme toplamını da getirir
-- (kalan = contract_amount - paid, kart başına ayrı sorgu yok).
-- name: ListSubcontractors :many
SELECT s.*,
       COALESCE((SELECT sum(p.amount) FROM project_subcontractor_payments p
                 WHERE p.subcontractor_id = s.id AND p.voided_at IS NULL), 0)::numeric(18,2) AS paid_amount
FROM project_subcontractors s
WHERE s.project_id = $1 AND s.organization_id = $2
ORDER BY s.created_at ASC;

-- name: UpdateSubcontractor :one
-- project_id EKLENDİ (bkz. GetSubcontractor notu).
UPDATE project_subcontractors
SET name = $3, company_name = $4, phone = $5, email = $6, work_description = $7,
    contract_amount = $8, start_date = $9, end_date = $10, status = $11, notes = $12
WHERE id = $1 AND organization_id = $2 AND project_id = $13
RETURNING *;

-- ============ Taşeron Ödemeleri ============

-- name: CreateSubcontractorPayment :one
INSERT INTO project_subcontractor_payments (
    organization_id, project_id, subcontractor_id, amount, currency,
    paid_date, description, idempotency_key, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
RETURNING *;

-- GetSubcontractorPayment, void durumundan BAĞIMSIZ okur (bkz.
-- GetCollection notu). project_id EKLENDİ (bkz. GetPaymentPlanItem notu).
-- name: GetSubcontractorPayment :one
SELECT * FROM project_subcontractor_payments WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- GetSubcontractorPaymentByIdempotencyKey, anahtarı TAŞERON bazında
-- arar (proje bazında DEĞİL) -- aksi halde aynı projede iki farklı
-- taşerona aynı anahtarla girilen ödemelerden biri diğerinin kaydı
-- sanılıp sessizce kaybolurdu (bkz. 0026 migration notu).
-- name: GetSubcontractorPaymentByIdempotencyKey :one
SELECT * FROM project_subcontractor_payments
WHERE subcontractor_id = $1 AND idempotency_key = $2;

-- name: ListSubcontractorPayments :many
SELECT * FROM project_subcontractor_payments
WHERE project_id = $1 AND organization_id = $2
ORDER BY paid_date DESC, created_at DESC;

-- name: VoidSubcontractorPayment :one
-- project_id EKLENDİ (bkz. GetPaymentPlanItem notu).
UPDATE project_subcontractor_payments
SET voided_at = now(), voided_by = $3, void_reason = $4
WHERE id = $1 AND organization_id = $2 AND voided_at IS NULL AND project_id = $5
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
    SELECT COALESCE(sum(amount), 0)::numeric(18,2) AS total
    FROM project_collections WHERE project_id = $1 AND voided_at IS NULL
),
planned AS (
    SELECT COALESCE(sum(planned_amount), 0)::numeric(18,2) AS total
    FROM project_payment_plan_items WHERE project_id = $1 AND status <> 'cancelled'
),
expense_total AS (
    SELECT COALESCE(sum(amount), 0)::numeric(18,2) AS total
    FROM project_expenses WHERE project_id = $1 AND voided_at IS NULL
),
subpay AS (
    SELECT COALESCE(sum(amount), 0)::numeric(18,2) AS total
    FROM project_subcontractor_payments WHERE project_id = $1 AND voided_at IS NULL
),
subcommit AS (
    -- İptal edilmiş taşeron sözleşmeleri taahhüde dahil edilmez.
    SELECT COALESCE(sum(contract_amount), 0)::numeric(18,2) AS total
    FROM project_subcontractors WHERE project_id = $1 AND status <> 'cancelled'
),
subremaining AS (
    -- Kalan taahhüt taşeron BAŞINA hesaplanır ve negatife düşürülmez:
    -- fazla ödenmiş bir taşeron, diğerlerinin kalan taahhüdünü azaltmamalı.
    SELECT COALESCE(sum(GREATEST(s.contract_amount - COALESCE(p.paid, 0), 0)), 0)::numeric(18,2) AS total
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
        COALESCE(sum(amount) FILTER (WHERE status IN ('issued','sent','paid')), 0)::numeric(18,2) AS issued_total,
        COALESCE(sum(amount) FILTER (WHERE status = 'paid'), 0)::numeric(18,2) AS paid_total
    FROM project_invoices WHERE project_id = $1 AND invoice_type = 'sales'
),
-- Faz 8: projects.contract_amount ASLA değişmez (ana sözleşme). "Güncel
-- proje bedeli", onaylı ek işler/eksiltmelerden HER SEFERİNDE aggregate
-- edilir -- bir kolon olarak TUTULMAZ (bkz. 0027 migration notu).
co_effect AS (
    SELECT
        COALESCE(sum(grand_total) FILTER (WHERE change_type = 'addition' AND status = 'approved'), 0)::numeric(18,2)
            AS approved_additions,
        COALESCE(sum(grand_total) FILTER (WHERE change_type = 'deduction' AND status = 'approved'), 0)::numeric(18,2)
            AS approved_deductions,
        COALESCE(sum(grand_total) FILTER (WHERE change_type = 'addition' AND status IN ('draft','sent')), 0)::numeric(18,2)
            AS pending_additions,
        COALESCE(sum(grand_total) FILTER (WHERE change_type = 'deduction' AND status IN ('draft','sent')), 0)::numeric(18,2)
            AS pending_deductions
    FROM project_change_orders WHERE project_id = $1 AND organization_id = $2
),
current_value AS (
    SELECT (proj.contract_amount + co_effect.approved_additions - co_effect.approved_deductions)::numeric(18,2) AS total
    FROM proj, co_effect
)
SELECT
    proj.contract_amount AS base_contract_amount,
    proj.contract_amount,
    proj.currency,
    co_effect.approved_additions,
    co_effect.approved_deductions,
    current_value.total AS current_contract_value,
    co_effect.pending_additions,
    co_effect.pending_deductions,
    (current_value.total + co_effect.pending_additions - co_effect.pending_deductions)::numeric(18,2)
        AS potential_contract_value,
    planned.total AS planned_collections,
    coll.total    AS collected_amount,
    (current_value.total - coll.total)::numeric(18,2) AS remaining_receivable,
    expense_total.total     AS total_expenses,
    subcommit.total    AS total_subcontractor_commitment,
    subpay.total       AS subcontractor_paid,
    subremaining.total AS subcontractor_remaining,
    inv.issued_total   AS issued_invoice_total,
    inv.paid_total     AS paid_invoice_total,
    (expense_total.total + subpay.total)::numeric(18,2) AS realized_cost,
    (expense_total.total + subpay.total + subremaining.total)::numeric(18,2) AS committed_cost,
    (current_value.total - (expense_total.total + subpay.total))::numeric(18,2) AS realized_gross_profit,
    (current_value.total - (expense_total.total + subpay.total + subremaining.total))::numeric(18,2) AS estimated_gross_profit,
    -- Marj yüzdesi matematiksel olarak SINIRSIZDIR (küçük bir sözleşme
    -- bedeline karşı çok büyük bir maliyet girilirse oran patlar). Cast
    -- overflow'la 500 üretmek yerine GREATEST/LEAST ile makul ama geniş
    -- bir bant içine (±99.999.999,99%) kelepçelenir -- gerçek/gerçekçi
    -- hiçbir proje bu bandı zorlamaz, yalnızca veri girişi hatalarında
    -- doygunlaşır (bkz. denetim bulgusu: eski numeric(7,2) taşıyordu).
    -- current_contract_value <= 0 (henüz nadir, ama onaylı eksiltmeler
    -- ana sözleşmeyi sıfıra kadar düşürebilir) durumunda marj güvenle 0
    -- döner -- sıfıra bölme yoktur.
    CASE WHEN current_value.total > 0
         THEN GREATEST(-99999999.99, LEAST(99999999.99,
              round((current_value.total - (expense_total.total + subpay.total)) * 100 / current_value.total, 2)))
         ELSE 0 END::numeric(10,2) AS realized_margin_percent,
    CASE WHEN current_value.total > 0
         THEN GREATEST(-99999999.99, LEAST(99999999.99,
              round((current_value.total - (expense_total.total + subpay.total + subremaining.total)) * 100 / current_value.total, 2)))
         ELSE 0 END::numeric(10,2) AS estimated_margin_percent
FROM proj, coll, planned, expense_total, subpay, subcommit, subremaining, inv, co_effect, current_value;

-- ============ Proje Olayları (audit) ============

-- name: CreateProjectEvent :one
INSERT INTO project_events (organization_id, project_id, event_type, user_id, metadata)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: ListProjectEvents :many
SELECT * FROM project_events
WHERE project_id = $1 AND organization_id = $2
ORDER BY created_at ASC;
