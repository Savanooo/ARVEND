-- ARVEND V2 — Sprint 5: Taşeron Yönetimi. Subcontract + SOV + Subcontract
-- Change Order + Progress Claim (Hakediş). Kalem listelerinin "güncelleme"
-- deseni project_change_order_items/purchase_order_items İLE AYNIDIR:
-- DeleteXItems (tümünü sil) + CreateXItem (yeniden ekle) döngüsü.
-- Bkz. docs/subcontracts.md.

-- ============ Sayaçlar ============

-- name: NextSubcontractSeq :one
INSERT INTO subcontract_counters (organization_id, year, seq) VALUES ($1, $2, 1)
ON CONFLICT (organization_id, year) DO UPDATE SET seq = subcontract_counters.seq + 1
RETURNING seq;

-- name: NextSubcontractChangeOrderSeq :one
INSERT INTO subcontract_change_order_counters (organization_id, year, seq) VALUES ($1, $2, 1)
ON CONFLICT (organization_id, year) DO UPDATE SET seq = subcontract_change_order_counters.seq + 1
RETURNING seq;

-- name: NextSubcontractProgressClaimSeq :one
INSERT INTO subcontract_progress_claim_counters (organization_id, year, seq) VALUES ($1, $2, 1)
ON CONFLICT (organization_id, year) DO UPDATE SET seq = subcontract_progress_claim_counters.seq + 1
RETURNING seq;

-- ============ Subcontract ============

-- name: CreateSubcontract :one
INSERT INTO project_subcontracts (
    organization_id, project_id, subcontract_no, supplier_id, title, scope_summary, currency,
    effective_date, start_date, planned_completion_date, retention_percent, advance_amount,
    payment_terms, notes, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
RETURNING *;

-- name: ListSubcontractsDetailed :many
SELECT sc.*, s.code AS supplier_code, s.legal_name AS supplier_legal_name
FROM project_subcontracts sc
JOIN suppliers s ON s.id = sc.supplier_id
WHERE sc.project_id = $1 AND sc.organization_id = $2
ORDER BY sc.created_at DESC;

-- name: GetSubcontract :one
SELECT * FROM project_subcontracts WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- name: GetSubcontractDetailed :one
SELECT sc.*, s.code AS supplier_code, s.legal_name AS supplier_legal_name
FROM project_subcontracts sc
JOIN suppliers s ON s.id = sc.supplier_id
WHERE sc.id = $1 AND sc.organization_id = $2 AND sc.project_id = $3;

-- name: GetSubcontractForUpdate :one
SELECT * FROM project_subcontracts WHERE id = $1 AND organization_id = $2 AND project_id = $3 FOR UPDATE;

-- name: UpdateSubcontractDraft :one
UPDATE project_subcontracts SET
    supplier_id = $4, title = $5, scope_summary = $6, currency = $7,
    effective_date = $8, start_date = $9, planned_completion_date = $10,
    retention_percent = $11, advance_amount = $12, payment_terms = $13, notes = $14
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- name: RecomputeSubcontractTotal :one
UPDATE project_subcontracts sc
SET original_amount = sub.total
FROM (SELECT COALESCE(sum(original_amount), 0)::numeric(18,2) AS total
      FROM subcontract_items WHERE subcontract_id = $1) sub
WHERE sc.id = $1 AND sc.organization_id = $2 AND sc.project_id = $3
RETURNING sc.*;

-- name: ActivateSubcontract :one
UPDATE project_subcontracts SET status = 'active', activated_at = now(), activated_by = $4
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- name: CompleteSubcontract :one
UPDATE project_subcontracts SET status = 'completed', completed_at = now(), completed_by = $4
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'active'
RETURNING *;

-- name: CancelSubcontract :one
UPDATE project_subcontracts SET status = 'cancelled', cancelled_at = now(), cancelled_by = $4, cancel_reason = $5
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- name: TerminateSubcontract :one
UPDATE project_subcontracts SET status = 'terminated', terminated_at = now(), terminated_by = $4, termination_reason = $5
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'active'
RETURNING *;

-- name: GetSubcontractCurrentValue :one
WITH co_effect AS (
    SELECT
        COALESCE(sum(amount) FILTER (WHERE change_type = 'addition' AND status = 'approved'), 0)::numeric(18,2) AS approved_additions,
        COALESCE(sum(amount) FILTER (WHERE change_type = 'deduction' AND status = 'approved'), 0)::numeric(18,2) AS approved_deductions,
        COALESCE(sum(amount) FILTER (WHERE change_type = 'addition' AND status IN ('draft','submitted')), 0)::numeric(18,2) AS pending_additions,
        COALESCE(sum(amount) FILTER (WHERE change_type = 'deduction' AND status IN ('draft','submitted')), 0)::numeric(18,2) AS pending_deductions
    FROM subcontract_change_orders WHERE subcontract_id = $1
)
SELECT sc.original_amount, co_effect.approved_additions, co_effect.approved_deductions,
    co_effect.pending_additions, co_effect.pending_deductions,
    (sc.original_amount + co_effect.approved_additions - co_effect.approved_deductions)::numeric(18,2) AS current_value
FROM project_subcontracts sc, co_effect
WHERE sc.id = $1 AND sc.organization_id = $2 AND sc.project_id = $3;

-- name: GetSubcontractCertifiedToDate :one
-- Bu taşeronun TÜM SOV kalemlerinin en son SERTİFİKALI hakedişteki kümülatif
-- tutarlarının toplamı -- "Remaining Commitment" (spec §24) ve fesih
-- senkronizasyonu (spec §15/§39) için kullanılır. Actual/Cost Control DEĞİL
-- (bkz. docs/subcontracts.md §Actual Cost Kararı). organization_id/
-- project_id, subcontract_progress_claims üzerinden DOĞRUDAN filtrelenir
-- (savunma derinliği -- çağıran zaten subcontract_id'yi doğrulamış olsa
-- bile, bkz. VoidCommitmentsBySourcePOItems İLE AYNI ilke).
--
-- "En son sertifikalı kümülatif" tanımı bu dosyadaki DÖRT sorguda
-- (bu, GetSubcontractTerminationTargets, ListLatestCertifiedCumulative-
-- BySubcontractItem, GetLatestCertifiedCumulativeForSubcontractItem) ve
-- project_finance.sql'deki certified_by_sc CTE'sinde BİREBİR AYNIDIR:
--   * kalem, hakediş başına previous + Σ current olarak toplanır -- düzeltme
--     ÖNCESİ bir hakedişte aynı SOV kalemi iki satırda yer almışsa (artık
--     reddediliyor) iki satır da sertifikalıdır, tek satırı seçmek
--     sertifikalı işi eksik gösterir ve sonraki hakedişin aynı tutarı
--     yeniden sertifikalamasına izin verirdi;
--   * "en son" = certified_at DESC, eşitlikte hakediş id DESC --
--     DISTINCT ON/LIMIT 1'in eşitlikte rastgele satır seçmesi engellenir.
WITH certified_lines AS (
    SELECT pci.subcontract_item_id, pc.id AS claim_id, pc.certified_at,
        (max(pci.previous_progress_amount) + sum(pci.current_progress_amount))::numeric(18,2) AS cumulative
    FROM subcontract_progress_claim_items pci
    JOIN subcontract_progress_claims pc ON pc.id = pci.progress_claim_id
    WHERE pc.subcontract_id = $1 AND pc.organization_id = $2 AND pc.project_id = $3 AND pc.status = 'certified'
    GROUP BY pci.subcontract_item_id, pc.id, pc.certified_at
),
latest_certified AS (
    SELECT DISTINCT ON (subcontract_item_id) subcontract_item_id, cumulative
    FROM certified_lines
    ORDER BY subcontract_item_id, certified_at DESC, claim_id DESC
)
SELECT COALESCE(sum(cumulative), 0)::numeric(18,2) AS total FROM latest_certified;

-- name: ListLatestCertifiedCumulativeBySubcontractItem :many
-- SOV kalemi başına en son sertifikalı kümülatif tutar (tanım için bkz.
-- GetSubcontractCertifiedToDate) -- hakediş/değişiklik sınırlarının
-- (checkClaimCaps) kalem ve grup bazlı kontrolü için.
WITH certified_lines AS (
    SELECT pci.subcontract_item_id, pc.id AS claim_id, pc.certified_at,
        (max(pci.previous_progress_amount) + sum(pci.current_progress_amount))::numeric(18,2) AS cumulative
    FROM subcontract_progress_claim_items pci
    JOIN subcontract_progress_claims pc ON pc.id = pci.progress_claim_id
    WHERE pc.subcontract_id = $1 AND pc.organization_id = $2 AND pc.project_id = $3 AND pc.status = 'certified'
    GROUP BY pci.subcontract_item_id, pc.id, pc.certified_at
)
SELECT DISTINCT ON (subcontract_item_id) subcontract_item_id, cumulative
FROM certified_lines
ORDER BY subcontract_item_id, certified_at DESC, claim_id DESC;

-- name: ListSubcontractItemTotalsByCostCode :many
-- syncSubcontractCommitments'ın "normal" (aktivasyon/değişiklik-onayı)
-- hedefinin İLK YARISI: SOV kalemleri, maliyet kodu/bütçe kalemi başına
-- toplanmış. İKİNCİ yarısı (ListApprovedSubcontractChangeItemTotalsByCostCode)
-- İLE Go'da NETLENİR (bkz. docs/subcontracts.md §Commitment Entegrasyonu) --
-- iki farklı kaynaktan gelen satırları TEK bir UNION'lu CTE'de birleştirip
-- GROUP BY yapan sürüm sqlc'nin statik analizörünü karıştırdığı için
-- (gerçek Postgres'te GEÇERLİ, ama sqlc kendi iç kataloğuyla "ambiguous
-- column" hatası veriyor) BİLİNÇLİ OLARAK iki basit sorguya bölündü.
SELECT cost_code_id, budget_line_id, sum(original_amount)::numeric(18,2) AS total
FROM subcontract_items
WHERE subcontract_id = $1 AND organization_id = $2 AND project_id = $3
GROUP BY cost_code_id, budget_line_id;

-- name: ListApprovedSubcontractChangeItemTotalsByCostCode :many
SELECT scoi.cost_code_id, scoi.budget_line_id,
    sum(CASE WHEN sco.change_type = 'addition' THEN scoi.amount ELSE -scoi.amount END)::numeric(18,2) AS total
FROM subcontract_change_order_items scoi
JOIN subcontract_change_orders sco ON sco.id = scoi.change_order_id
WHERE sco.subcontract_id = $1 AND sco.organization_id = $2 AND sco.project_id = $3 AND sco.status = 'approved'
GROUP BY scoi.cost_code_id, scoi.budget_line_id;

-- name: GetSubcontractTerminationTargets :many
-- syncSubcontractCommitments'ın "fesih" hedefi: SOV kalemleri başına en son
-- SERTİFİKALI hakediş kümülatif tutarı, maliyet kodu/bütçe kalemi başına
-- NETLENMİŞ -- "earned/certified amount korunur, remaining unperformed
-- commitment release edilir" (spec §15) kuralının doğrudan uygulanışı.
-- "En son sertifikalı kümülatif" tanımı: bkz. GetSubcontractCertifiedToDate.
WITH certified_lines AS (
    SELECT pci.subcontract_item_id, pc.id AS claim_id, pc.certified_at,
        (max(pci.previous_progress_amount) + sum(pci.current_progress_amount))::numeric(18,2) AS cumulative
    FROM subcontract_progress_claim_items pci
    JOIN subcontract_progress_claims pc ON pc.id = pci.progress_claim_id
    WHERE pc.subcontract_id = $1 AND pc.organization_id = $2 AND pc.project_id = $3 AND pc.status = 'certified'
    GROUP BY pci.subcontract_item_id, pc.id, pc.certified_at
),
latest_certified AS (
    SELECT DISTINCT ON (subcontract_item_id) subcontract_item_id, cumulative
    FROM certified_lines
    ORDER BY subcontract_item_id, certified_at DESC, claim_id DESC
)
SELECT si.cost_code_id, si.budget_line_id,
    COALESCE(sum(lc.cumulative), 0)::numeric(18,2) AS net_amount
FROM subcontract_items si
LEFT JOIN latest_certified lc ON lc.subcontract_item_id = si.id
WHERE si.subcontract_id = $1 AND si.organization_id = $2 AND si.project_id = $3
GROUP BY si.cost_code_id, si.budget_line_id
HAVING COALESCE(sum(lc.cumulative), 0) > 0;

-- ============ Subcontract Items (SOV) ============

-- name: CreateSubcontractItem :one
INSERT INTO subcontract_items (
    organization_id, project_id, subcontract_id, wbs_node_id, cost_code_id, budget_line_id,
    description, quantity, unit, unit_price, original_amount, sort_order
) VALUES (
    $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,
    CASE WHEN $8::numeric IS NOT NULL AND $10::numeric IS NOT NULL THEN round($8::numeric * $10::numeric, 2) ELSE $11::numeric END,
    $12
)
RETURNING *;

-- name: ListSubcontractItems :many
SELECT * FROM subcontract_items WHERE subcontract_id = $1 ORDER BY sort_order ASC, created_at ASC;

-- name: DeleteSubcontractItems :exec
DELETE FROM subcontract_items WHERE subcontract_id = $1 AND organization_id = $2 AND project_id = $3;

-- ============ Subcontract Change Orders ============

-- name: CreateSubcontractChangeOrder :one
INSERT INTO subcontract_change_orders (
    organization_id, project_id, subcontract_id, number, title, description, change_type, reason, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
RETURNING *;

-- name: ListSubcontractChangeOrders :many
SELECT * FROM subcontract_change_orders WHERE subcontract_id = $1 ORDER BY created_at DESC;

-- name: GetSubcontractChangeOrder :one
SELECT * FROM subcontract_change_orders WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- name: GetSubcontractChangeOrderForUpdate :one
SELECT * FROM subcontract_change_orders WHERE id = $1 AND organization_id = $2 AND project_id = $3 FOR UPDATE;

-- name: UpdateSubcontractChangeOrderDraft :one
UPDATE subcontract_change_orders SET title = $4, description = $5, change_type = $6, reason = $7
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- name: RecomputeSubcontractChangeOrderTotal :one
UPDATE subcontract_change_orders sco
SET amount = sub.total
FROM (SELECT COALESCE(sum(amount), 0)::numeric(18,2) AS total
      FROM subcontract_change_order_items WHERE change_order_id = $1) sub
WHERE sco.id = $1 AND sco.organization_id = $2 AND sco.project_id = $3
RETURNING sco.*;

-- name: SubmitSubcontractChangeOrder :one
UPDATE subcontract_change_orders SET status = 'submitted', requested_at = now()
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- name: ApproveSubcontractChangeOrder :one
UPDATE subcontract_change_orders SET status = 'approved', approved_at = now(), approved_by = $4
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'submitted'
RETURNING *;

-- name: RejectSubcontractChangeOrder :one
UPDATE subcontract_change_orders SET status = 'rejected', rejected_at = now(), rejected_by = $4, rejection_reason = $5
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'submitted'
RETURNING *;

-- name: CancelSubcontractChangeOrder :one
UPDATE subcontract_change_orders SET status = 'cancelled', cancelled_at = now(), cancelled_by = $4
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status IN ('draft', 'submitted')
RETURNING *;

-- name: CreateSubcontractChangeOrderItem :one
INSERT INTO subcontract_change_order_items (
    organization_id, project_id, change_order_id, wbs_node_id, cost_code_id, budget_line_id,
    description, amount, sort_order
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
RETURNING *;

-- name: ListSubcontractChangeOrderItems :many
SELECT * FROM subcontract_change_order_items WHERE change_order_id = $1 ORDER BY sort_order ASC;

-- name: DeleteSubcontractChangeOrderItems :exec
DELETE FROM subcontract_change_order_items WHERE change_order_id = $1 AND organization_id = $2 AND project_id = $3;

-- ============ Subcontract Progress Claims (Hakediş) ============

-- name: CreateSubcontractProgressClaim :one
INSERT INTO subcontract_progress_claims (
    organization_id, project_id, subcontract_id, claim_number, period_start, period_end,
    retention_percent_snapshot, advance_recovery_amount, other_deductions, notes, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
RETURNING *;

-- name: ListSubcontractProgressClaims :many
SELECT * FROM subcontract_progress_claims WHERE subcontract_id = $1 ORDER BY created_at DESC;

-- name: GetSubcontractProgressClaim :one
SELECT * FROM subcontract_progress_claims WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- name: GetSubcontractProgressClaimForUpdate :one
SELECT * FROM subcontract_progress_claims WHERE id = $1 AND organization_id = $2 AND project_id = $3 FOR UPDATE;

-- name: UpdateSubcontractProgressClaimDraft :one
UPDATE subcontract_progress_claims SET
    period_start = $4, period_end = $5, retention_percent_snapshot = $6,
    advance_recovery_amount = $7, other_deductions = $8, notes = $9
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- name: RecomputeSubcontractProgressClaimTotals :one
-- gross_work_amount kalemlerden; previous_certified_amount bu taşeronun
-- ÖNCEKİ sertifikalı hakedişlerinin (bu hakediş HARİÇ) current_certified_
-- amount'larının EN SONUNCUSU (kümülatif zincir); retention/net backend'de
-- HER ZAMAN hesaplanır (spec §22, "double-count edilmemeli"). `prev`,
-- HİÇBİR önceki sertifikalı hakediş yokken bile TEK bir satır döner
-- (skaler alt sorgu, LIMIT 1'in kendisi FROM listesinde DEĞİL SELECT
-- listesinde) -- aksi halde UPDATE...FROM'daki CROSS JOIN, 0 satırlı bir
-- FROM kaynağı yüzünden HİÇBİR satırı güncellemez (ilk hakediş boş sonuç
-- üretir).
UPDATE subcontract_progress_claims pc
SET gross_work_amount = sub.gross,
    retention_amount = round(sub.gross * pc.retention_percent_snapshot / 100, 2),
    previous_certified_amount = COALESCE(prev.amount, 0),
    current_certified_amount = COALESCE(prev.amount, 0) + sub.gross,
    net_payable = (sub.gross - round(sub.gross * pc.retention_percent_snapshot / 100, 2) - pc.advance_recovery_amount - pc.other_deductions)::numeric(18,2)
FROM (SELECT COALESCE(sum(current_progress_amount), 0)::numeric(18,2) AS gross
      FROM subcontract_progress_claim_items WHERE progress_claim_id = $1) sub,
     (SELECT (
          SELECT current_certified_amount FROM subcontract_progress_claims
          WHERE subcontract_id = (SELECT subcontract_id FROM subcontract_progress_claims WHERE id = $1)
            AND status = 'certified' AND id <> $1
          ORDER BY certified_at DESC, id DESC LIMIT 1
      ) AS amount) prev
WHERE pc.id = $1 AND pc.organization_id = $2 AND pc.project_id = $3
RETURNING pc.*;

-- name: SubmitSubcontractProgressClaim :one
UPDATE subcontract_progress_claims SET status = 'submitted', submitted_at = now()
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- name: CertifySubcontractProgressClaim :one
UPDATE subcontract_progress_claims SET status = 'certified', certified_at = now(), certified_by = $4
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'submitted'
RETURNING *;

-- name: RejectSubcontractProgressClaim :one
UPDATE subcontract_progress_claims SET status = 'rejected', rejected_at = now(), rejected_by = $4, rejection_reason = $5
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'submitted'
RETURNING *;

-- name: CancelSubcontractProgressClaim :one
UPDATE subcontract_progress_claims SET status = 'cancelled', cancelled_at = now(), cancelled_by = $4
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status IN ('draft', 'submitted')
RETURNING *;

-- name: CreateSubcontractProgressClaimItem :one
INSERT INTO subcontract_progress_claim_items (
    organization_id, project_id, progress_claim_id, subcontract_item_id,
    scheduled_value, previous_progress_amount, current_progress_amount, cumulative_progress_amount, sort_order
) VALUES ($1,$2,$3,$4,$5,$6,$7, $6::numeric + $7::numeric, $8)
RETURNING *;

-- name: ListSubcontractProgressClaimItemsDetailed :many
SELECT pci.*, si.description AS item_description, si.unit AS item_unit
FROM subcontract_progress_claim_items pci
JOIN subcontract_items si ON si.id = pci.subcontract_item_id
WHERE pci.progress_claim_id = $1
ORDER BY pci.sort_order ASC;

-- name: DeleteSubcontractProgressClaimItems :exec
DELETE FROM subcontract_progress_claim_items WHERE progress_claim_id = $1 AND organization_id = $2 AND project_id = $3;

-- ============ Subcontract Payments (Gerçek Ödemeler) ============
-- Sprint 5 follow-up. Collection (project_finance.sql) İLE AYNI desen:
-- durum makinesi yok, create+void; idempotency anahtarı TAŞERON bazında
-- (SubcontractorPayment İLE AYNI ilke, bkz. migration 0026 gerekçesi).

-- name: CreateSubcontractPayment :one
INSERT INTO subcontract_payments (
    organization_id, project_id, subcontract_id, progress_claim_id, amount, currency,
    paid_date, payment_method, reference_no, description, idempotency_key, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
RETURNING *;

-- name: GetSubcontractPayment :one
SELECT * FROM subcontract_payments WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- name: GetSubcontractPaymentByIdempotencyKey :one
SELECT * FROM subcontract_payments WHERE subcontract_id = $1 AND idempotency_key = $2;

-- name: ListSubcontractPayments :many
SELECT * FROM subcontract_payments
WHERE subcontract_id = $1 AND organization_id = $2 AND project_id = $3
ORDER BY paid_date DESC, created_at DESC;

-- name: VoidSubcontractPayment :one
UPDATE subcontract_payments SET voided_at = now(), voided_by = $4, void_reason = $5
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND voided_at IS NULL
RETURNING *;

-- name: GetSubcontractPaidToDate :one
-- SubcontractValueSummary'nin PaidToDate'i -- yalnızca voidlenmemiş
-- ödemelerin toplamı (bkz. GetSubcontractCertifiedToDate İLE AYNI savunma
-- derinliği: organization_id/project_id doğrudan filtrelenir).
SELECT COALESCE(sum(amount), 0)::numeric(18,2) AS total
FROM subcontract_payments
WHERE subcontract_id = $1 AND organization_id = $2 AND project_id = $3 AND voided_at IS NULL;

-- name: GetSubcontractPaidForProgressClaim :one
-- Bir hakedişe BAĞLI, iptal edilmemiş ödemelerin toplamı -- hakedişe bağlı
-- yeni bir ödeme hakedişin net ödenecek tutarını aşamaz (bkz.
-- CreateSubcontractPayment; çağıran sözleşme satırını kilitli tutar, aynı
-- sözleşmeye eşzamanlı iki ödeme bu toplamı birlikte delemez).
SELECT COALESCE(sum(amount), 0)::numeric(18,2) AS total
FROM subcontract_payments
WHERE progress_claim_id = $1 AND organization_id = $2 AND project_id = $3 AND voided_at IS NULL;

-- name: GetSubcontractPaidTotalForProject :one
-- GetProjectFinancialSummary'nin new-module taşeron maliyeti CTE'si için --
-- projedeki TÜM (henüz voidlenmemiş) taşeron ödemelerinin toplamı.
SELECT COALESCE(sum(amount), 0)::numeric(18,2) AS total
FROM subcontract_payments
WHERE project_id = $1 AND organization_id = $2 AND voided_at IS NULL;

-- name: ListSubcontractPaidTotalsBySubcontractForProject :many
-- GetProjectFinancialSummary'nin "kalan taahhüt" (subcontract_remaining)
-- CTE'si için -- proje İÇİNDEKİ HER sözleşmenin kendi ödeme toplamı
-- (sözleşme başına GREATEST(current_value - paid, 0) hesaplanabilsin diye).
SELECT subcontract_id, sum(amount)::numeric(18,2) AS total
FROM subcontract_payments
WHERE project_id = $1 AND organization_id = $2 AND voided_at IS NULL
GROUP BY subcontract_id;

-- name: GetLatestCertifiedCumulativeForSubcontractItem :one
-- Yeni bir hakediş kalemi oluşturulurken previous_progress_amount'ı
-- OTOMATİK doldurmak için -- yalnızca SERTİFİKALI hakedişler sayılır
-- (draft/submitted/rejected/cancelled bir hakedişin rakamları "önceki"
-- zincire ASLA sızmaz). Tanım GetSubcontractCertifiedToDate İLE AYNI:
-- en son sertifikalı hakediş (certified_at DESC, eşitlikte id DESC --
-- deterministik), o hakedişteki satırlarından previous + Σ current.
SELECT COALESCE(
    (SELECT (max(pci.previous_progress_amount) + sum(pci.current_progress_amount))
     FROM subcontract_progress_claim_items pci
     WHERE pci.subcontract_item_id = $1
       AND pci.progress_claim_id = (
           SELECT pc.id
           FROM subcontract_progress_claims pc
           JOIN subcontract_progress_claim_items x ON x.progress_claim_id = pc.id
           WHERE x.subcontract_item_id = $1 AND pc.status = 'certified'
           ORDER BY pc.certified_at DESC, pc.id DESC LIMIT 1)),
    0
)::numeric(18,2) AS cumulative;

-- name: LockSubcontractForPayment :one
-- Taşeron sözleşmesine ödemede sözleşme satırı KİLİTLENİR; güncel bedel
-- (asıl bedel + onaylı ek - onaylı eksiltme) ve geçerli ödeme toplamı
-- okunur: toplam ödeme güncel bedeli aşamaz (bkz.
-- LockSubcontractorForPayment).
SELECT (sc.original_amount
        + COALESCE((SELECT sum(CASE co.change_type WHEN 'addition' THEN co.amount ELSE -co.amount END)
                    FROM subcontract_change_orders co
                    WHERE co.subcontract_id = sc.id AND co.status = 'approved'), 0))::numeric(18,2) AS current_value,
       COALESCE((SELECT sum(p.amount) FROM subcontract_payments p
                 WHERE p.subcontract_id = sc.id AND p.voided_at IS NULL), 0)::numeric(18,2) AS paid_amount
FROM project_subcontracts sc
WHERE sc.id = $1 AND sc.organization_id = $2 AND sc.project_id = $3
FOR UPDATE OF sc;
