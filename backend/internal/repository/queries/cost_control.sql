-- ARVEND V2 — Sprint 2: WBS + Cost Codes + Project Budget + Cost Control.
-- Formüller docs/cost-control.md'de belgelenmiştir. Bu dosyadaki
-- ListCostControlLines ve GetProjectCostControlSummary AYNI CTE
-- mantığını (satır satır maliyet/taahhüt/tahmin) kullanır -- proje
-- toplamı, satır toplamlarının SQL SUM()'udur (spec: "Project total AYNI
-- KURALLA aggregate edilmeli"), asla bağımsız bir formülle YENİDEN
-- hesaplanmaz.

-- ============ Organizasyon Olayları (org-seviyesi denetim) ============

-- name: CreateOrganizationEvent :one
INSERT INTO organization_events (organization_id, event_type, user_id, metadata)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: ListOrganizationEvents :many
SELECT * FROM organization_events WHERE organization_id = $1 ORDER BY created_at DESC LIMIT $2 OFFSET $3;

-- ============ Organizasyon Maliyet Kodları ============

-- name: CreateOrganizationCostCode :one
INSERT INTO organization_cost_codes (organization_id, code, name, description, category)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: ListOrganizationCostCodes :many
SELECT * FROM organization_cost_codes WHERE organization_id = $1 ORDER BY code ASC;

-- name: GetOrganizationCostCode :one
SELECT * FROM organization_cost_codes WHERE id = $1 AND organization_id = $2;

-- name: UpdateOrganizationCostCode :one
UPDATE organization_cost_codes SET name = $3, description = $4, category = $5
WHERE id = $1 AND organization_id = $2
RETURNING *;

-- ArchiveOrganizationCostCode, HARD DELETE DEĞİLDİR (spec: geçmiş
-- bütçe/taahhüt/gider kayıtları referans veriyor olabilir) -- yalnızca
-- is_active=false yapar; kod, mevcut kayıtlarda görünmeye devam eder,
-- yalnızca YENİ seçim listelerinden (bkz. ListOrganizationCostCodes'un
-- çağıran tarafta is_active filtrelemesi) çıkar.
-- name: ArchiveOrganizationCostCode :execrows
UPDATE organization_cost_codes SET is_active = false WHERE id = $1 AND organization_id = $2;

-- name: ReactivateOrganizationCostCode :execrows
UPDATE organization_cost_codes SET is_active = true WHERE id = $1 AND organization_id = $2;

-- ============ Proje WBS ============

-- name: CreateWBSNode :one
INSERT INTO project_wbs_nodes (organization_id, project_id, parent_id, code, name, sort_order)
VALUES ($1, $2, $3, $4, $5, $6)
RETURNING *;

-- name: ListWBSNodes :many
-- TÜM düğümler (aktif+arşivlenmiş) döner -- ağaç yapısı korunur, arşivlenmiş
-- düğümler istemci tarafında soluk gösterilir (spec: "kullanılan node
-- hard-delete edilmemeli").
SELECT * FROM project_wbs_nodes WHERE project_id = $1 AND organization_id = $2
ORDER BY sort_order ASC, code ASC;

-- name: GetWBSNode :one
SELECT * FROM project_wbs_nodes WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- name: UpdateWBSNode :one
-- Yalnızca rename/reorder -- bu sprintte re-parent (parent_id değişimi)
-- YOKTUR (spec: "Complex drag/drop zorunlu değil"), bu yüzden döngü
-- riski hiç oluşmaz.
UPDATE project_wbs_nodes SET code = $4, name = $5, sort_order = $6
WHERE id = $1 AND organization_id = $2 AND project_id = $3
RETURNING *;

-- name: ArchiveWBSNode :execrows
UPDATE project_wbs_nodes SET is_active = false WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- name: CountActiveWBSChildren :one
-- Arşivleme kapısı: aktif alt düğümü olan bir düğüm arşivlenmez (bkz.
-- ArchiveWBSNode servis notu -- arşivden geri alma ucu olmadığı için
-- alt ağacı sessizce arşivlemek geri döndürülemez olurdu).
SELECT count(*)::bigint FROM project_wbs_nodes
WHERE parent_id = $1 AND organization_id = $2 AND project_id = $3 AND is_active = true;

-- ============ Proje Bütçesi ============

-- name: CreateProjectBudget :one
INSERT INTO project_budgets (organization_id, project_id, currency, created_by)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: GetProjectBudget :one
SELECT * FROM project_budgets WHERE project_id = $1 AND organization_id = $2;

-- GetProjectBudgetForUpdate, satırı KİLİT ALTINDA okur -- baseline işlemi
-- (project_change_orders'daki SendChangeOrder ile AYNI ilke) bunu
-- kullanır, ardından status='draft' koşuluyla günceller; eşzamanlı iki
-- "baseline al" isteğinden yalnızca biri satır döndürür.
-- name: GetProjectBudgetForUpdate :one
SELECT * FROM project_budgets WHERE id = $1 AND organization_id = $2 AND project_id = $3 FOR UPDATE;

-- name: BaselineProjectBudget :one
UPDATE project_budgets
SET status = 'baselined', baselined_at = now(), baselined_by = $4, version = version + 1
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- ============ Bütçe Kalemleri ============

-- name: CreateBudgetLine :one
INSERT INTO project_budget_lines (
    organization_id, project_id, budget_id, wbs_node_id, cost_code_id,
    description, quantity, unit, unit_cost, original_amount, notes
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
RETURNING *;

-- ListBudgetLinesDetailed, WBS/cost-code adlarını da (N+1'siz) getirir --
-- Bütçe düzenleme ekranının liste görünümü içindir.
-- name: ListBudgetLinesDetailed :many
SELECT bl.*, wn.code AS wbs_code, wn.name AS wbs_name, cc.code AS cost_code_code, cc.name AS cost_code_name
FROM project_budget_lines bl
LEFT JOIN project_wbs_nodes wn ON wn.id = bl.wbs_node_id
JOIN organization_cost_codes cc ON cc.id = bl.cost_code_id
WHERE bl.budget_id = $1 AND bl.organization_id = $2
ORDER BY wn.sort_order ASC NULLS LAST, cc.code ASC;

-- name: GetBudgetLine :one
SELECT * FROM project_budget_lines WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- name: UpdateBudgetLine :one
UPDATE project_budget_lines
SET wbs_node_id = $4, cost_code_id = $5, description = $6, quantity = $7, unit = $8,
    unit_cost = $9, original_amount = $10, notes = $11
WHERE id = $1 AND organization_id = $2 AND project_id = $3
RETURNING *;

-- DeleteBudgetLine, YALNIZCA draft (henüz baseline alınmamış) bütçenin
-- kalemleri için kullanılır -- servis katmanı budget.status='draft'
-- kontrolünü FOR UPDATE ile önce yapar (bkz. project_change_orders'daki
-- requireOpenProject ile AYNI ilke).
-- name: DeleteBudgetLine :execrows
DELETE FROM project_budget_lines WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- ============ Bütçe Revizyonları (Adjustments) ============

-- name: CreateBudgetAdjustment :one
INSERT INTO project_budget_adjustments (organization_id, project_id, budget_id, budget_line_id, amount, reason, created_by)
VALUES ($1,$2,$3,$4,$5,$6,$7)
RETURNING *;

-- name: ListBudgetAdjustments :many
SELECT * FROM project_budget_adjustments WHERE project_id = $1 AND organization_id = $2
ORDER BY created_at DESC;

-- name: GetBudgetAdjustmentForUpdate :one
SELECT * FROM project_budget_adjustments WHERE id = $1 AND organization_id = $2 AND project_id = $3 FOR UPDATE;

-- ApproveBudgetAdjustment/RejectBudgetAdjustment, status='draft' koşuluyla
-- korunur -- eşzamanlı iki onay/redden yalnızca biri satır döndürür
-- (project_change_orders'daki RespondChangeOrder ile AYNI ilke).
-- name: ApproveBudgetAdjustment :one
UPDATE project_budget_adjustments SET status = 'approved', approved_by = $4, approved_at = now()
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- name: RejectBudgetAdjustment :one
UPDATE project_budget_adjustments SET status = 'rejected', approved_by = $4, approved_at = now()
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'draft'
RETURNING *;

-- ============ Taahhütler (Commitments) ============

-- name: CreateCommitment :one
INSERT INTO project_commitments (
    organization_id, project_id, budget_line_id, cost_code_id, source_type,
    description, committed_amount, currency, committed_at, idempotency_key, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
RETURNING *;

-- name: GetCommitmentByIdempotencyKey :one
SELECT * FROM project_commitments WHERE project_id = $1 AND idempotency_key = $2;

-- ListCommitmentsDetailed, cost-code/wbs adlarını da (N+1'siz) getirir.
-- name: ListCommitmentsDetailed :many
SELECT c.*, cc.code AS cost_code_code, cc.name AS cost_code_name
FROM project_commitments c
JOIN organization_cost_codes cc ON cc.id = c.cost_code_id
WHERE c.project_id = $1 AND c.organization_id = $2
ORDER BY c.committed_at DESC, c.created_at DESC;

-- name: GetCommitment :one
SELECT * FROM project_commitments WHERE id = $1 AND organization_id = $2 AND project_id = $3;

-- name: VoidCommitment :one
-- Elle iptal YALNIZCA manuel taahhütler içindir: satın alma siparişinden/
-- taşeron sözleşmesinden doğan taahhüt kaynağının yaşam döngüsüyle
-- (sipariş iptali, değişiklik onayı, fesih) senkron tutulur; elle
-- voidlenirse kaynak hâlâ geçerliyken Cost Control'den sessizce düşerdi.
UPDATE project_commitments SET status = 'voided', voided_at = now(), voided_by = $4, void_reason = $5
WHERE id = $1 AND organization_id = $2 AND project_id = $3 AND status = 'active' AND source_type = 'manual'
RETURNING *;

-- Sprint 4 -- Procurement entegrasyonu. CreateCommitment (yukarı,
-- MANUEL taahhütler için) İLE KARIŞTIRILMAMALI: bu sorgu source_type/
-- source_id'yi AÇIKÇA kabul eder, yalnızca approved PO onay akışından
-- (bkz. project_purchase_order_service.go) çağrılır -- hiçbir HTTP
-- ucu bunu doğrudan istemciye AÇMAZ.

-- name: CreateCommitmentFromSource :one
INSERT INTO project_commitments (
    organization_id, project_id, budget_line_id, cost_code_id, source_type, source_id,
    description, committed_amount, currency, committed_at, created_by
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
RETURNING *;

-- name: VoidCommitmentsBySourcePOItems :many
-- PO iptalinde, o PO'nun kalemlerinden doğan TÜM aktif taahhütleri TEK
-- sorguda voider (status='voided' koşulu idempotenttir -- zaten voided
-- olanlar sonuçtan dışlanır, ikinci bir çağrı zararsızdır).
UPDATE project_commitments pc
SET status = 'voided', voided_at = now(), voided_by = $4, void_reason = $5
WHERE pc.organization_id = $1 AND pc.project_id = $2
  AND pc.source_type = 'purchase_order'
  AND pc.source_id IN (SELECT poi.id FROM purchase_order_items poi WHERE poi.purchase_order_id = $3)
  AND pc.status = 'active'
RETURNING pc.*;

-- name: ListCommitmentsBySourcePOItems :many
SELECT pc.* FROM project_commitments pc
WHERE pc.organization_id = $1 AND pc.project_id = $2
  AND pc.source_type = 'purchase_order'
  AND pc.source_id IN (SELECT poi.id FROM purchase_order_items poi WHERE poi.purchase_order_id = $3);

-- Sprint 5 -- Subcontract entegrasyonu. PO'nun İTEM-seviyesi (source_id =
-- purchase_order_items.id, kalıcı/tek seferlik) modelinden BİLİNÇLİ SAPMA:
-- bir Subcontract'ın taahhüdü değişiklik emirleri/fesihle YAŞAM BOYU
-- DEĞİŞEBİLİR, bu yüzden source_id = project_subcontracts.id (SÖZLEŞME
-- seviyesinde) kullanılır ve syncSubcontractCommitments HER ticari olayda
-- (aktivasyon/değişiklik onayı/fesih) BÜTÜN aktif taahhütleri voidleyip
-- maliyet-kodu bazında NETLENMİŞ satırlarla YENİDEN OLUŞTURUR -- bkz.
-- docs/subcontracts.md §Commitment Entegrasyonu.

-- name: VoidCommitmentsBySourceSubcontract :many
UPDATE project_commitments pc
SET status = 'voided', voided_at = now(), voided_by = $4, void_reason = $5
WHERE pc.organization_id = $1 AND pc.project_id = $2
  AND pc.source_type = 'subcontract' AND pc.source_id = $3
  AND pc.status = 'active'
RETURNING pc.*;

-- name: ListCommitmentsBySourceSubcontract :many
SELECT pc.* FROM project_commitments pc
WHERE pc.organization_id = $1 AND pc.project_id = $2
  AND pc.source_type = 'subcontract' AND pc.source_id = $3;

-- ============ Tahmin (Forecast / ETC) ============

-- name: UpsertForecast :one
INSERT INTO project_cost_forecasts (organization_id, project_id, budget_line_id, etc_amount, note, updated_by)
VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (budget_line_id) DO UPDATE
    SET etc_amount = EXCLUDED.etc_amount, note = EXCLUDED.note, updated_by = EXCLUDED.updated_by, updated_at = now()
RETURNING *;

-- name: ListForecasts :many
SELECT * FROM project_cost_forecasts WHERE project_id = $1 AND organization_id = $2;

-- ============ Maliyet Kontrolü Özeti / Kırılım Tablosu ============
--
-- Her iki sorgu da AYNI satır-bazlı mantığı (budgeted + unbudgeted CTE'ler)
-- kullanır -- proje toplamı satır toplamlarının SQL SUM()'udur. Sorgu
-- metni sqlc'nin sorgular-arası CTE paylaşımını desteklememesi nedeniyle
-- İKİ KEZ yazılmıştır (project_finance.sql'deki co_effect/GetChangeOrder-
-- EffectTotals AYNI, önceden kabul edilmiş desen) -- biri değişirse
-- diğeri de GÜNCELLENMELİDİR (bkz. docs/cost-control.md).

-- name: ListCostControlLines :many
WITH lines AS (
    SELECT bl.id AS budget_line_id, bl.wbs_node_id, bl.cost_code_id, bl.description, bl.original_amount
    FROM project_budget_lines bl WHERE bl.project_id = $1 AND bl.organization_id = $2
),
adjustments AS (
    SELECT budget_line_id, COALESCE(sum(amount), 0)::numeric(18,2) AS total
    FROM project_budget_adjustments
    WHERE project_id = $1 AND organization_id = $2 AND status = 'approved'
    GROUP BY budget_line_id
),
-- Yalnızca maliyet koduyla (bütçe kalemi SEÇİLMEDEN) girilmiş gider/
-- taahhüt, o maliyet kodunun bu projede TEK bir bütçe kalemi varsa O
-- KALEME sayılır. Önceden böyle bir kayıt, kodun bütçe kalemi olsa bile
-- ayrı bir "bütçe dışı" satıra düşüyordu: bütçe kaleminin ETC'si (revize -
-- kendi gideri) hiç azalmadığı için aynı harcama hem o satırın ETC'sinde
-- hem bütçe dışı satırın EAC'sinde sayılıyor, EAC şişiyordu. Eşleme
-- OKUMA anında yapılır (kayıtlar yeniden yazılmaz): mevcut veriye de
-- migration'sız uygulanır ve kodun ikinci bir bütçe kalemi açılırsa kayıt
-- sessizce yanlış kalemde kalmaz -- hangi kaleme ait olduğu belirsiz
-- olduğundan "bütçe dışı" satırda görünür (kullanıcı kalemi seçmelidir).
-- ListCostControlLines ve GetProjectCostControlSummary'de BİREBİR AYNI.
single_line_codes AS (
    SELECT bl.cost_code_id, (array_agg(bl.id))[1] AS budget_line_id
    FROM project_budget_lines bl WHERE bl.project_id = $1 AND bl.organization_id = $2
    GROUP BY bl.cost_code_id
    HAVING count(*) = 1
),
committed_by_line AS (
    SELECT COALESCE(c.budget_line_id, slc.budget_line_id) AS budget_line_id,
        COALESCE(sum(c.committed_amount), 0)::numeric(18,2) AS total
    FROM project_commitments c
    LEFT JOIN single_line_codes slc ON c.budget_line_id IS NULL AND slc.cost_code_id = c.cost_code_id
    WHERE c.project_id = $1 AND c.organization_id = $2 AND c.status = 'active'
      AND COALESCE(c.budget_line_id, slc.budget_line_id) IS NOT NULL
    GROUP BY COALESCE(c.budget_line_id, slc.budget_line_id)
),
actual_by_line AS (
    SELECT COALESCE(e.budget_line_id, slc.budget_line_id) AS budget_line_id,
        COALESCE(sum(e.amount), 0)::numeric(18,2) AS total
    FROM project_expenses e
    LEFT JOIN single_line_codes slc ON e.budget_line_id IS NULL AND slc.cost_code_id = e.cost_code_id
    WHERE e.project_id = $1 AND e.organization_id = $2 AND e.voided_at IS NULL
      AND COALESCE(e.budget_line_id, slc.budget_line_id) IS NOT NULL
    GROUP BY COALESCE(e.budget_line_id, slc.budget_line_id)
),
forecast_by_line AS (
    SELECT budget_line_id, etc_amount FROM project_cost_forecasts WHERE project_id = $1 AND organization_id = $2
),
budgeted AS (
    SELECT
        l.budget_line_id, l.wbs_node_id, wn.code AS wbs_code, wn.name AS wbs_name,
        l.cost_code_id, cc.code AS cost_code_code, cc.name AS cost_code_name,
        l.description::varchar AS description, l.original_amount,
        COALESCE(adj.total, 0)::numeric(18,2) AS approved_adjustments,
        (l.original_amount + COALESCE(adj.total, 0))::numeric(18,2) AS revised_budget,
        COALESCE(com.total, 0)::numeric(18,2) AS committed_cost,
        COALESCE(act.total, 0)::numeric(18,2) AS actual_cost,
        COALESCE(fc.etc_amount, GREATEST((l.original_amount + COALESCE(adj.total, 0)) - COALESCE(act.total, 0), 0))::numeric(18,2) AS etc_amount,
        (COALESCE(act.total, 0) + COALESCE(fc.etc_amount, GREATEST((l.original_amount + COALESCE(adj.total, 0)) - COALESCE(act.total, 0), 0)))::numeric(18,2) AS eac,
        ((l.original_amount + COALESCE(adj.total, 0)) - (COALESCE(act.total, 0) + COALESCE(fc.etc_amount, GREATEST((l.original_amount + COALESCE(adj.total, 0)) - COALESCE(act.total, 0), 0))))::numeric(18,2) AS variance,
        false AS is_unbudgeted
    FROM lines l
    LEFT JOIN project_wbs_nodes wn ON wn.id = l.wbs_node_id
    JOIN organization_cost_codes cc ON cc.id = l.cost_code_id
    LEFT JOIN adjustments adj ON adj.budget_line_id = l.budget_line_id
    LEFT JOIN committed_by_line com ON com.budget_line_id = l.budget_line_id
    LEFT JOIN actual_by_line act ON act.budget_line_id = l.budget_line_id
    LEFT JOIN forecast_by_line fc ON fc.budget_line_id = l.budget_line_id
),
unbudgeted_committed AS (
    SELECT c.cost_code_id, COALESCE(sum(c.committed_amount), 0)::numeric(18,2) AS total
    FROM project_commitments c
    WHERE c.project_id = $1 AND c.organization_id = $2 AND c.status = 'active' AND c.budget_line_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM single_line_codes slc WHERE slc.cost_code_id = c.cost_code_id)
    GROUP BY c.cost_code_id
),
unbudgeted_actual AS (
    SELECT e.cost_code_id, COALESCE(sum(e.amount), 0)::numeric(18,2) AS total
    FROM project_expenses e
    WHERE e.project_id = $1 AND e.organization_id = $2 AND e.voided_at IS NULL AND e.budget_line_id IS NULL AND e.cost_code_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM single_line_codes slc WHERE slc.cost_code_id = e.cost_code_id)
    GROUP BY e.cost_code_id
),
unbudgeted_codes AS (
    SELECT cost_code_id FROM unbudgeted_committed
    UNION
    SELECT cost_code_id FROM unbudgeted_actual
),
-- Bütçe dışı (unbudgeted) satırlar: bir cost_code'a doğrudan (budget_line_id
-- OLMADAN) bağlanmış taahhüt/gider var ama bu cost code'un o projede bir
-- bütçe kalemi yok (ya da birden fazla var ve hangisine ait olduğu
-- belirsiz, bkz. single_line_codes) -- "kategorisiz/plansız harcama"
-- olarak AÇIKÇA gösterilir (original_budget=0, variance HER ZAMAN negatif).
unbudgeted AS (
    SELECT
        NULL::uuid AS budget_line_id, NULL::uuid AS wbs_node_id, NULL::varchar AS wbs_code, NULL::varchar AS wbs_name,
        uc.cost_code_id, cc.code AS cost_code_code, cc.name AS cost_code_name,
        ''::varchar AS description, 0::numeric(18,2) AS original_amount,
        0::numeric(18,2) AS approved_adjustments, 0::numeric(18,2) AS revised_budget,
        COALESCE(ucom.total, 0)::numeric(18,2) AS committed_cost, COALESCE(uact.total, 0)::numeric(18,2) AS actual_cost,
        0::numeric(18,2) AS etc_amount, COALESCE(uact.total, 0)::numeric(18,2) AS eac,
        (0 - COALESCE(uact.total, 0))::numeric(18,2) AS variance, true AS is_unbudgeted
    FROM unbudgeted_codes uc
    JOIN organization_cost_codes cc ON cc.id = uc.cost_code_id
    LEFT JOIN unbudgeted_committed ucom ON ucom.cost_code_id = uc.cost_code_id
    LEFT JOIN unbudgeted_actual uact ON uact.cost_code_id = uc.cost_code_id
)
SELECT * FROM budgeted
UNION ALL
SELECT * FROM unbudgeted
ORDER BY is_unbudgeted ASC, wbs_code ASC NULLS LAST, cost_code_code ASC;

-- GetProjectCostControlSummary, ListCostControlLines'ın AYNI satır
-- mantığını SUM() ile projeye toplar VE current_contract_value'yu
-- (GetProjectFinancialSummary'deki co_effect İLE AYNI formül) ekleyip
-- forecast_profit/forecast_margin'i (AYNI GREATEST/LEAST clamp deseni,
-- sıfıra bölme koruması) hesaplar.
-- name: GetProjectCostControlSummary :one
WITH proj AS (
    SELECT pr.contract_amount, pr.currency FROM projects pr WHERE pr.id = $1 AND pr.organization_id = $2
),
co_effect AS (
    SELECT
        COALESCE(sum(grand_total) FILTER (WHERE change_type = 'addition' AND status = 'approved'), 0)::numeric(18,2) AS approved_additions,
        COALESCE(sum(grand_total) FILTER (WHERE change_type = 'deduction' AND status = 'approved'), 0)::numeric(18,2) AS approved_deductions
    FROM project_change_orders WHERE project_id = $1 AND organization_id = $2
),
current_value AS (
    SELECT (proj.contract_amount + co_effect.approved_additions - co_effect.approved_deductions)::numeric(18,2) AS total
    FROM proj, co_effect
),
lines AS (
    SELECT bl.id AS budget_line_id, bl.cost_code_id, bl.original_amount
    FROM project_budget_lines bl WHERE bl.project_id = $1 AND bl.organization_id = $2
),
adjustments AS (
    SELECT budget_line_id, COALESCE(sum(amount), 0)::numeric(18,2) AS total
    FROM project_budget_adjustments
    WHERE project_id = $1 AND organization_id = $2 AND status = 'approved'
    GROUP BY budget_line_id
),
-- Yalnızca maliyet koduyla (bütçe kalemi SEÇİLMEDEN) girilmiş gider/
-- taahhüt, o maliyet kodunun bu projede TEK bir bütçe kalemi varsa O
-- KALEME sayılır. Önceden böyle bir kayıt, kodun bütçe kalemi olsa bile
-- ayrı bir "bütçe dışı" satıra düşüyordu: bütçe kaleminin ETC'si (revize -
-- kendi gideri) hiç azalmadığı için aynı harcama hem o satırın ETC'sinde
-- hem bütçe dışı satırın EAC'sinde sayılıyor, EAC şişiyordu. Eşleme
-- OKUMA anında yapılır (kayıtlar yeniden yazılmaz): mevcut veriye de
-- migration'sız uygulanır ve kodun ikinci bir bütçe kalemi açılırsa kayıt
-- sessizce yanlış kalemde kalmaz -- hangi kaleme ait olduğu belirsiz
-- olduğundan "bütçe dışı" satırda görünür (kullanıcı kalemi seçmelidir).
-- ListCostControlLines ve GetProjectCostControlSummary'de BİREBİR AYNI.
single_line_codes AS (
    SELECT bl.cost_code_id, (array_agg(bl.id))[1] AS budget_line_id
    FROM project_budget_lines bl WHERE bl.project_id = $1 AND bl.organization_id = $2
    GROUP BY bl.cost_code_id
    HAVING count(*) = 1
),
committed_by_line AS (
    SELECT COALESCE(c.budget_line_id, slc.budget_line_id) AS budget_line_id,
        COALESCE(sum(c.committed_amount), 0)::numeric(18,2) AS total
    FROM project_commitments c
    LEFT JOIN single_line_codes slc ON c.budget_line_id IS NULL AND slc.cost_code_id = c.cost_code_id
    WHERE c.project_id = $1 AND c.organization_id = $2 AND c.status = 'active'
      AND COALESCE(c.budget_line_id, slc.budget_line_id) IS NOT NULL
    GROUP BY COALESCE(c.budget_line_id, slc.budget_line_id)
),
actual_by_line AS (
    SELECT COALESCE(e.budget_line_id, slc.budget_line_id) AS budget_line_id,
        COALESCE(sum(e.amount), 0)::numeric(18,2) AS total
    FROM project_expenses e
    LEFT JOIN single_line_codes slc ON e.budget_line_id IS NULL AND slc.cost_code_id = e.cost_code_id
    WHERE e.project_id = $1 AND e.organization_id = $2 AND e.voided_at IS NULL
      AND COALESCE(e.budget_line_id, slc.budget_line_id) IS NOT NULL
    GROUP BY COALESCE(e.budget_line_id, slc.budget_line_id)
),
forecast_by_line AS (
    SELECT budget_line_id, etc_amount FROM project_cost_forecasts WHERE project_id = $1 AND organization_id = $2
),
budgeted AS (
    SELECT
        l.original_amount,
        COALESCE(adj.total, 0)::numeric(18,2) AS approved_adjustments,
        (l.original_amount + COALESCE(adj.total, 0))::numeric(18,2) AS revised_budget,
        COALESCE(com.total, 0)::numeric(18,2) AS committed_cost,
        COALESCE(act.total, 0)::numeric(18,2) AS actual_cost,
        COALESCE(fc.etc_amount, GREATEST((l.original_amount + COALESCE(adj.total, 0)) - COALESCE(act.total, 0), 0))::numeric(18,2) AS etc_amount,
        (COALESCE(act.total, 0) + COALESCE(fc.etc_amount, GREATEST((l.original_amount + COALESCE(adj.total, 0)) - COALESCE(act.total, 0), 0)))::numeric(18,2) AS eac,
        ((l.original_amount + COALESCE(adj.total, 0)) - (COALESCE(act.total, 0) + COALESCE(fc.etc_amount, GREATEST((l.original_amount + COALESCE(adj.total, 0)) - COALESCE(act.total, 0), 0))))::numeric(18,2) AS variance
    FROM lines l
    LEFT JOIN adjustments adj ON adj.budget_line_id = l.budget_line_id
    LEFT JOIN committed_by_line com ON com.budget_line_id = l.budget_line_id
    LEFT JOIN actual_by_line act ON act.budget_line_id = l.budget_line_id
    LEFT JOIN forecast_by_line fc ON fc.budget_line_id = l.budget_line_id
),
unbudgeted_committed AS (
    SELECT c.cost_code_id, COALESCE(sum(c.committed_amount), 0)::numeric(18,2) AS total
    FROM project_commitments c
    WHERE c.project_id = $1 AND c.organization_id = $2 AND c.status = 'active' AND c.budget_line_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM single_line_codes slc WHERE slc.cost_code_id = c.cost_code_id)
    GROUP BY c.cost_code_id
),
unbudgeted_actual AS (
    SELECT e.cost_code_id, COALESCE(sum(e.amount), 0)::numeric(18,2) AS total
    FROM project_expenses e
    WHERE e.project_id = $1 AND e.organization_id = $2 AND e.voided_at IS NULL AND e.budget_line_id IS NULL AND e.cost_code_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM single_line_codes slc WHERE slc.cost_code_id = e.cost_code_id)
    GROUP BY e.cost_code_id
),
unbudgeted_codes AS (
    SELECT cost_code_id FROM unbudgeted_committed
    UNION
    SELECT cost_code_id FROM unbudgeted_actual
),
unbudgeted AS (
    SELECT
        0::numeric(18,2) AS original_amount, 0::numeric(18,2) AS approved_adjustments, 0::numeric(18,2) AS revised_budget,
        COALESCE(ucom.total, 0)::numeric(18,2) AS committed_cost, COALESCE(uact.total, 0)::numeric(18,2) AS actual_cost,
        0::numeric(18,2) AS etc_amount, COALESCE(uact.total, 0)::numeric(18,2) AS eac, (0 - COALESCE(uact.total, 0))::numeric(18,2) AS variance
    FROM unbudgeted_codes uc
    LEFT JOIN unbudgeted_committed ucom ON ucom.cost_code_id = uc.cost_code_id
    LEFT JOIN unbudgeted_actual uact ON uact.cost_code_id = uc.cost_code_id
),
all_rows AS (
    SELECT * FROM budgeted
    UNION ALL
    SELECT * FROM unbudgeted
),
totals AS (
    SELECT
        COALESCE(sum(original_amount), 0)::numeric(18,2) AS original_budget,
        COALESCE(sum(approved_adjustments), 0)::numeric(18,2) AS approved_adjustments,
        COALESCE(sum(revised_budget), 0)::numeric(18,2) AS revised_budget,
        COALESCE(sum(committed_cost), 0)::numeric(18,2) AS committed_cost,
        COALESCE(sum(actual_cost), 0)::numeric(18,2) AS actual_cost,
        COALESCE(sum(etc_amount), 0)::numeric(18,2) AS etc_total,
        COALESCE(sum(eac), 0)::numeric(18,2) AS eac_total
    FROM all_rows
)
SELECT
    proj.currency,
    current_value.total AS contract_value,
    totals.original_budget,
    totals.approved_adjustments,
    totals.revised_budget,
    totals.committed_cost,
    totals.actual_cost,
    totals.etc_total,
    totals.eac_total,
    (totals.revised_budget - totals.eac_total)::numeric(18,2) AS variance,
    (current_value.total - totals.eac_total)::numeric(18,2) AS forecast_profit,
    -- Marj yüzdesi, GetProjectFinancialSummary'deki AYNI clamp/sıfıra
    -- bölme koruması deseniyle: current_value <= 0 ise güvenle 0 döner.
    CASE WHEN current_value.total > 0
         THEN GREATEST(-99999999.99, LEAST(99999999.99,
              round((current_value.total - totals.eac_total) * 100 / current_value.total, 2)))
         ELSE 0 END::numeric(10,2) AS forecast_margin_percent
FROM proj, current_value, totals;
