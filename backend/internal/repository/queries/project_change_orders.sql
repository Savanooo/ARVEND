-- ============ Sıra Numarası ============

-- name: NextChangeOrderSeq :one
INSERT INTO change_order_counters (project_id, seq) VALUES ($1, 1)
ON CONFLICT (project_id) DO UPDATE SET seq = change_order_counters.seq + 1
RETURNING seq;

-- ============ Ek İşler ============

-- name: CreateChangeOrder :one
INSERT INTO project_change_orders (
    organization_id, project_id, sequence_no, change_type, title, description,
    vat_rate, currency, internal_notes, customer_notes, created_by, supersedes_change_order_id
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
RETURNING *;

-- name: GetChangeOrderByID :one
SELECT * FROM project_change_orders WHERE id = $1 AND organization_id = $2;

-- GetChangeOrderForUpdate, satırı KİLİT ALTINDA okur -- her durum
-- geçişinde (send/revise/cancel/respond) proje kilidinden SONRA alınır,
-- aynı sırayla, deadlock oluşmaması için (bkz. requireOpenProject).
-- name: GetChangeOrderForUpdate :one
SELECT * FROM project_change_orders WHERE id = $1 AND organization_id = $2 FOR UPDATE;

-- ListChangeOrders, her kaydın taşeron/masraf kayıtlarından GERÇEKLEŞEN
-- ve TAAHHÜT maliyetini de (change_order_id ile etiketlenmiş kayıtlardan)
-- AYNI sorguda getirir -- N+1 yok. Bu, proje toplamına zaten bir kez giren
-- AYNI kayıtların filtrelenmiş bir görünümüdür (çift sayım yok).
-- name: ListChangeOrders :many
SELECT co.*,
    COALESCE((SELECT sum(e.amount) FROM project_expenses e
              WHERE e.change_order_id = co.id AND e.voided_at IS NULL), 0)::numeric(18,2)
        AS realized_expense_cost,
    COALESCE((SELECT sum(sp.amount) FROM project_subcontractor_payments sp
              JOIN project_subcontractors s ON s.id = sp.subcontractor_id
              WHERE s.change_order_id = co.id AND sp.voided_at IS NULL), 0)::numeric(18,2)
        AS realized_subcontractor_cost,
    COALESCE((SELECT sum(GREATEST(s.contract_amount - COALESCE((
                  SELECT sum(sp2.amount) FROM project_subcontractor_payments sp2
                  WHERE sp2.subcontractor_id = s.id AND sp2.voided_at IS NULL), 0), 0))
              FROM project_subcontractors s
              WHERE s.change_order_id = co.id AND s.status <> 'cancelled'), 0)::numeric(18,2)
        AS subcontractor_remaining_commitment,
    -- "Linki Kopyala" düğmesi için: aktif (iptal/süre dolmamış) linkin
    -- token'ı, ayrı bir sorgu AÇMADAN (N+1 yok) korelasyonlu alt sorguyla.
    -- status = 'sent' şartı GetChangeOrder'daki (tekil) davranışla
    -- birebir aynı olmalı -- aksi halde onaylanmış/reddedilmiş/iptal
    -- edilmiş bir ek iş için henüz revoke edilmemiş eski bir link
    -- yanlışlıkla "aktif" gibi görünür (bkz. denetim bulgusu).
    (SELECT l.token FROM project_change_order_share_links l
     WHERE l.change_order_id = co.id AND co.status = 'sent'
       AND l.revoked_at IS NULL AND (l.expires_at IS NULL OR l.expires_at > now())
     ORDER BY l.created_at DESC LIMIT 1) AS active_share_token
FROM project_change_orders co
WHERE co.project_id = $1 AND co.organization_id = $2
ORDER BY co.sequence_no ASC;

-- name: ListChangeOrderItems :many
SELECT * FROM project_change_order_items WHERE change_order_id = $1 ORDER BY sort_order ASC;

-- name: CreateChangeOrderItem :one
-- line_total, quantity*unit_price'tan SQL'DE (Go float64 aritmetiği
-- DEĞİL) hesaplanır -- kuruş hassasiyeti korunur.
INSERT INTO project_change_order_items (
    organization_id, project_id, change_order_id, product_id, description,
    quantity, unit, unit_price, line_total, sort_order, estimated_unit_cost, estimated_cost
) VALUES (
    sqlc.arg(organization_id), sqlc.arg(project_id), sqlc.arg(change_order_id),
    sqlc.narg(product_id), sqlc.arg(description),
    sqlc.arg(quantity)::numeric, sqlc.arg(unit), sqlc.arg(unit_price)::numeric,
    round(sqlc.arg(quantity)::numeric * sqlc.arg(unit_price)::numeric, 2), sqlc.arg(sort_order),
    sqlc.narg(estimated_unit_cost)::numeric,
    CASE WHEN sqlc.narg(estimated_unit_cost)::numeric IS NULL THEN NULL
         ELSE round(sqlc.arg(quantity)::numeric * sqlc.narg(estimated_unit_cost)::numeric, 2) END
)
RETURNING *;

-- name: DeleteChangeOrderItems :exec
DELETE FROM project_change_order_items WHERE change_order_id = $1;

-- RecomputeChangeOrderTotals, kalemlerin GERÇEK toplamını (subtotal) ve
-- ondan türetilen vat_amount/grand_total'ı TEK bir atomik UPDATE'te
-- yeniden hesaplar. Her kalem ekleme/değiştirme/silme sonrasında
-- çağrılır; toplamlar HİÇBİR ZAMAN Go tarafında toplanmaz.
-- name: RecomputeChangeOrderTotals :one
UPDATE project_change_orders co
SET subtotal = sub.total,
    vat_amount = round(sub.total * co.vat_rate / 100, 2),
    grand_total = sub.total + round(sub.total * co.vat_rate / 100, 2)
FROM (
    SELECT COALESCE(sum(line_total), 0)::numeric(18,2) AS total
    FROM project_change_order_items WHERE change_order_id = $1
) sub
WHERE co.id = $1 AND co.organization_id = $2
RETURNING co.*;

-- name: UpdateChangeOrderDraft :one
-- Yalnızca DRAFT durumdaki kayıt düzenlenebilir -- WHERE koşulundaki
-- status='draft' servis katmanındaki kontrolün üzerine bir savunma
-- katmanıdır (offer_revisions'daki UpdateOfferRevision ile aynı ilke).
UPDATE project_change_orders
SET change_type = $3, title = $4, description = $5, vat_rate = $6,
    customer_notes = $7, internal_notes = $8
WHERE id = $1 AND organization_id = $2 AND status = 'draft'
RETURNING *;

-- name: SendChangeOrder :one
UPDATE project_change_orders
SET status = 'sent', sent_at = now()
WHERE id = $1 AND organization_id = $2 AND status = 'draft'
RETURNING *;

-- name: CancelChangeOrder :one
UPDATE project_change_orders
SET status = 'cancelled', cancelled_at = now()
WHERE id = $1 AND organization_id = $2 AND status IN ('draft', 'sent')
RETURNING *;

-- decision, 'approved' ya da 'rejected' olmalıdır (servis katmanında
-- doğrulanır). Yalnızca 'sent' durumundaki bir kayıt yanıtlanabilir --
-- bu WHERE koşulu, aynı bağlantıya ikinci bir yanıtın (double-submit)
-- da doğal olarak reddedilmesini sağlar.
-- name: RespondChangeOrder :one
UPDATE project_change_orders
SET status = sqlc.arg(status)::varchar, responded_at = now(),
    approved_at = CASE WHEN sqlc.arg(status)::varchar = 'approved' THEN now() ELSE approved_at END,
    rejected_at = CASE WHEN sqlc.arg(status)::varchar = 'rejected' THEN now() ELSE rejected_at END
WHERE id = $1 AND organization_id = $2 AND status = 'sent'
RETURNING *;

-- name: SupersedeChangeOrder :one
UPDATE project_change_orders
SET status = 'superseded'
WHERE id = $1 AND organization_id = $2 AND status IN ('sent', 'rejected')
RETURNING *;

-- GetChangeOrderEffectTotals, bir projenin ONAYLI ve BEKLEYEN ek iş/
-- eksiltme toplamlarını TEK sorguda döner. financial-summary'nin ve
-- public görünümün current/projected contract value hesabında
-- kullanılır. Onay anındaki "negatife düşürme" kontrolü İÇİN
-- kullanılmaz -- o karar ChangeOrderApprovalWouldGoNegative ile
-- TAMAMEN numeric'te verilir (bkz. altı, denetim bulgusu: Go float64
-- karşılaştırması kuruş hassasiyetinde yanlış ret üretebiliyordu).
-- name: GetChangeOrderEffectTotals :one
SELECT
    COALESCE(sum(grand_total) FILTER (WHERE change_type = 'addition' AND status = 'approved'), 0)::numeric(18,2)
        AS approved_additions,
    COALESCE(sum(grand_total) FILTER (WHERE change_type = 'deduction' AND status = 'approved'), 0)::numeric(18,2)
        AS approved_deductions,
    COALESCE(sum(grand_total) FILTER (WHERE change_type = 'addition' AND status IN ('draft', 'sent')), 0)::numeric(18,2)
        AS pending_additions,
    COALESCE(sum(grand_total) FILTER (WHERE change_type = 'deduction' AND status IN ('draft', 'sent')), 0)::numeric(18,2)
        AS pending_deductions
FROM project_change_orders
WHERE project_id = $1 AND organization_id = $2;

-- ChangeOrderApprovalWouldGoNegative, bir eksiltmenin onayı halinde
-- current_contract_value'nun negatife düşüp düşmeyeceğini TAMAMEN
-- numeric aritmetiğiyle (Go float64'e HİÇ dönmeden) karşılar --
-- current_contract_value = base + approved_additions - approved_deductions,
-- onaylanacak eksiltmenin kendi grand_total'ı da düşülür. co, çağıran
-- tarafından aynı transaction'da FOR UPDATE ile zaten kilitlenmiş
-- olmalıdır; bu sorgu yalnızca karşılaştırmayı yapar.
-- name: ChangeOrderApprovalWouldGoNegative :one
SELECT (p.contract_amount + t.approved_additions - t.approved_deductions - co.grand_total) < 0
    AS would_go_negative
FROM project_change_orders co
JOIN projects p ON p.id = co.project_id AND p.organization_id = co.organization_id
CROSS JOIN LATERAL (
    SELECT
        COALESCE(sum(grand_total) FILTER (WHERE change_type = 'addition' AND status = 'approved'), 0)::numeric(18,2)
            AS approved_additions,
        COALESCE(sum(grand_total) FILTER (WHERE change_type = 'deduction' AND status = 'approved'), 0)::numeric(18,2)
            AS approved_deductions
    FROM project_change_orders
    WHERE project_id = co.project_id AND organization_id = co.organization_id
) t
WHERE co.id = $1 AND co.organization_id = $2;

-- ============ Paylaşım Linki ============

-- name: CreateChangeOrderShareLink :one
INSERT INTO project_change_order_share_links (organization_id, project_id, change_order_id, created_by, expires_at)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: GetChangeOrderShareLinkByToken :one
SELECT * FROM project_change_order_share_links WHERE token = $1;

-- GetActiveChangeOrderShareLink, bu ek iş için hâlâ aktif (iptal
-- edilmemiş/süresi dolmamış) EN SON linki döner -- Send/SendEmail
-- akışında "aktif link varsa yenisini yaratma" deseni için.
-- name: GetActiveChangeOrderShareLink :one
SELECT * FROM project_change_order_share_links
WHERE change_order_id = $1 AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now())
ORDER BY created_at DESC LIMIT 1;

-- name: RevokeChangeOrderShareLinks :exec
UPDATE project_change_order_share_links
SET revoked_at = now()
WHERE change_order_id = $1 AND revoked_at IS NULL;

-- ============ E-posta Logları ============

-- name: CreateChangeOrderEmailLog :one
INSERT INTO project_change_order_email_logs (
    organization_id, project_id, change_order_id, share_link_id,
    recipient, subject, status, error_message, sent_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
RETURNING *;

-- name: ListChangeOrderEmailLogs :many
SELECT * FROM project_change_order_email_logs
WHERE change_order_id = $1 AND organization_id = $2
ORDER BY sent_at DESC;
