-- Ana sayfa özeti (GET /api/v1/dashboard) -- bkz. service/dashboard_*.go.
--
-- Ortak kurallar:
--   * Proje kapsamlı HER sorgu "ap" CTE'siyle başlar: firmanın projeleri,
--     üyelik kısıtlı rollerde (restrict_to_user_id dolu) yalnızca kullanıcının
--     project_users üyeliği olanlar -- ListProjects/CountProjects ile BİREBİR
--     aynı EXISTS kuralı (proje kimlikleri Go'ya YÜKLENMEZ).
--   * Alt tablolar ap'ye bağlanır VE organization_id'yi TEKRAR süzer
--     (derinlemesine savunma).
--   * "Açık proje" = planned/active/paused; "iptal dışı" = status <> cancelled.
--     İptal edilmiş projeler hiçbir dikkat kaydı üretmez.
--   * Tarihler Go'da İstanbul takvimiyle hesaplanıp parametre olarak gelir;
--     CURRENT_DATE/now()::date KULLANILMAZ. timestamptz kolonları İstanbul
--     gece yarısı sınırlarıyla (…_ts) karşılaştırılır.
--   * Para toplamları numeric'te yapılır ve ::numeric(18,2)'ye çevrilir;
--     yüzdeler SQL'de, sıfıra bölme korumalı ve 1 ondalığa yuvarlanır.
--   * Türkçe durum değerleri (teklif, mesai) SQL'e yazılmaz, domain
--     sabitlerinden parametre olarak gelir.

-- ============================================================ meta

-- name: DashboardPrimaryCurrency :one
SELECT COALESCE(
    (SELECT s.default_currency FROM organization_commercial_settings s
     WHERE s.organization_id = @org_id::uuid),
    'TRY')::text AS primary_currency;

-- name: DashboardAccessibleProjectCount :one
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT count(*)::int AS project_count FROM ap;

-- name: DashboardOnboardingCounts :one
-- Kurulum adımlarının "tamamlandı" sayıları (yalnızca kaba admin için,
-- firma geneli -- üyelik ekseni yok).
SELECT
    (SELECT count(*) FROM customers c
      WHERE c.organization_id = @org_id::uuid AND c.is_active)::int AS active_customers,
    (SELECT count(*) FROM products pr
      WHERE pr.organization_id = @org_id::uuid)::int AS products,
    (SELECT count(*) FROM employees e
      WHERE e.organization_id = @org_id::uuid AND e.archived_at IS NULL AND e.is_active)::int AS active_employees,
    (SELECT count(*) FROM users u
      WHERE u.organization_id = @org_id::uuid AND u.deleted_at IS NULL AND u.is_active)::int AS active_users,
    (SELECT count(*) FROM offers o
      WHERE o.organization_id = @org_id::uuid AND NOT o.is_passive)::int AS active_offers,
    (SELECT count(*) FROM projects p
      WHERE p.organization_id = @org_id::uuid)::int AS projects;

-- ============================================================ projects

-- name: DashboardProjectCounts :one
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT
    (count(*) FILTER (WHERE ap.status = 'planned'))::int   AS planned,
    (count(*) FILTER (WHERE ap.status = 'active'))::int    AS active,
    (count(*) FILTER (WHERE ap.status = 'paused'))::int    AS paused,
    (count(*) FILTER (WHERE ap.status = 'completed'))::int AS completed,
    (count(*) FILTER (WHERE ap.status = 'cancelled'))::int AS cancelled,
    count(*)::int AS total,
    (count(*) FILTER (WHERE ap.status IN ('planned', 'active', 'paused')
                        AND ap.end_date < @today::date))::int AS past_end_date,
    (count(*) FILTER (WHERE ap.status IN ('planned', 'active', 'paused')
                        AND ap.end_date BETWEEN @today::date AND @plus29::date))::int AS ending_within_30d
FROM ap;

-- name: DashboardOpenProjects :many
-- Açık projeler (proje satırları, "bitişi geçen" ve "yaklaşan bitiş"
-- kayıtları). Süre ilerlemesi SQL'de: (bugün - başlangıç) / (bitiş -
-- başlangıç), 0-100 arasına sıkıştırılır; tarih eksikse ya da bitiş
-- başlangıçtan önce/aynıysa NULL.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT ap.id, ap.project_no, ap.name, ap.status, ap.customer_name, ap.currency,
       ap.start_date, ap.end_date,
       (CASE WHEN ap.start_date IS NOT NULL AND ap.end_date IS NOT NULL AND ap.end_date > ap.start_date
             THEN round(LEAST(GREATEST((sqlc.arg('today')::date - ap.start_date)::numeric
                                       / (ap.end_date - ap.start_date) * 100, 0), 100), 1)
        END)::numeric AS time_progress_pct
FROM ap
WHERE ap.status IN ('planned', 'active', 'paused')
ORDER BY ap.end_date ASC NULLS LAST, ap.name ASC, ap.id;

-- name: DashboardProjectTaskStats :many
-- CountProjectTaskStats formülü, açık projeler için tek sorguda:
-- tamamlanan / iptal dışı; gecikmiş = açık ve vadesi bugünden önce.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT t.project_id,
       (CASE WHEN count(*) FILTER (WHERE t.status <> 'cancelled') > 0
             THEN round((count(*) FILTER (WHERE t.status = 'completed'))::numeric
                        / (count(*) FILTER (WHERE t.status <> 'cancelled')) * 100, 1)
        END)::numeric AS task_progress_pct,
       (count(*) FILTER (WHERE t.status IN ('todo', 'in_progress')
                           AND t.due_date < @today::date))::int AS overdue_count
FROM project_tasks t
JOIN ap ON ap.id = t.project_id AND ap.status IN ('planned', 'active', 'paused')
WHERE t.organization_id = @org_id::uuid
GROUP BY t.project_id;

-- name: DashboardProjectFinanceStats :many
-- Açık projeler için güncel bedel (GetProjectFinancialSummary co_effect
-- formülü), tahsilat oranı ve vadesi geçmiş ödeme planı kalemi sayısı.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
),
po AS (SELECT ap.id, ap.contract_amount, ap.currency FROM ap WHERE ap.status IN ('planned', 'active', 'paused')),
co AS (
    SELECT c.project_id,
           COALESCE(sum(c.grand_total) FILTER (WHERE c.change_type = 'addition' AND c.status = 'approved'), 0)
         - COALESCE(sum(c.grand_total) FILTER (WHERE c.change_type = 'deduction' AND c.status = 'approved'), 0) AS net
    FROM project_change_orders c
    WHERE c.organization_id = @org_id::uuid AND c.project_id IN (SELECT po.id FROM po)
    GROUP BY c.project_id
),
coll AS (
    SELECT c.project_id, sum(c.amount) AS total
    FROM project_collections c
    WHERE c.organization_id = @org_id::uuid AND c.voided_at IS NULL AND c.project_id IN (SELECT po.id FROM po)
    GROUP BY c.project_id
),
plan_coll AS (
    SELECT c.payment_plan_item_id, sum(c.amount) AS collected
    FROM project_collections c
    WHERE c.organization_id = @org_id::uuid AND c.voided_at IS NULL AND c.payment_plan_item_id IS NOT NULL
    GROUP BY c.payment_plan_item_id
),
od AS (
    SELECT i.project_id, count(*) AS cnt
    FROM project_payment_plan_items i
    LEFT JOIN plan_coll pc ON pc.payment_plan_item_id = i.id
    WHERE i.organization_id = @org_id::uuid AND i.project_id IN (SELECT po.id FROM po)
      AND i.status <> 'cancelled' AND i.due_date < @today::date
      AND i.planned_amount - COALESCE(pc.collected, 0) > 0
    GROUP BY i.project_id
)
SELECT po.id AS project_id, po.currency::text AS currency,
       (po.contract_amount + COALESCE(co.net, 0))::numeric(18,2) AS current_value,
       (CASE WHEN po.contract_amount + COALESCE(co.net, 0) > 0
             THEN round(COALESCE(coll.total, 0) / (po.contract_amount + COALESCE(co.net, 0)) * 100, 1)
        END)::numeric AS collection_pct,
       COALESCE(od.cnt, 0)::int AS overdue_plan_count
FROM po
LEFT JOIN co ON co.project_id = po.id
LEFT JOIN coll ON coll.project_id = po.id
LEFT JOIN od ON od.project_id = po.id;

-- name: DashboardProjectsOverBudget :many
-- Onaylı (baselined) bütçesi olan açık projelerde, GetProjectCostControl
-- Summary ile aynı kaynaklar: revize bütçe = orijinal kalemler + onaylı
-- revizyonlar; gerçekleşen = bütçe kalemine bağlı, iptal edilmemiş
-- masraflar. Aşım: gerçekleşen > revize > 0.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
),
pb AS (
    SELECT b.project_id, b.currency, ap.project_no, ap.name
    FROM project_budgets b
    JOIN ap ON ap.id = b.project_id AND ap.status IN ('planned', 'active', 'paused')
    WHERE b.organization_id = @org_id::uuid AND b.status = 'baselined'
),
lines AS (
    SELECT bl.project_id, sum(bl.original_amount) AS total
    FROM project_budget_lines bl
    WHERE bl.organization_id = @org_id::uuid AND bl.project_id IN (SELECT pb.project_id FROM pb)
    GROUP BY bl.project_id
),
adj AS (
    SELECT a.project_id, sum(a.amount) AS total
    FROM project_budget_adjustments a
    WHERE a.organization_id = @org_id::uuid AND a.status = 'approved'
      AND a.project_id IN (SELECT pb.project_id FROM pb)
    GROUP BY a.project_id
),
act AS (
    SELECT e.project_id, sum(e.amount) AS total
    FROM project_expenses e
    WHERE e.organization_id = @org_id::uuid AND e.voided_at IS NULL AND e.budget_line_id IS NOT NULL
      AND e.project_id IN (SELECT pb.project_id FROM pb)
    GROUP BY e.project_id
),
per AS (
    SELECT pb.project_id, pb.currency, pb.project_no, pb.name,
           COALESCE(lines.total, 0) + COALESCE(adj.total, 0) AS revised,
           COALESCE(act.total, 0) AS actual
    FROM pb
    LEFT JOIN lines ON lines.project_id = pb.project_id
    LEFT JOIN adj ON adj.project_id = pb.project_id
    LEFT JOIN act ON act.project_id = pb.project_id
)
SELECT per.project_id, per.currency::text AS currency, per.project_no, per.name,
       (per.actual - per.revised)::numeric(18,2) AS overrun_amount,
       round((per.actual - per.revised) / per.revised * 100, 1)::numeric AS overrun_pct
FROM per
WHERE per.revised > 0 AND per.actual > per.revised
ORDER BY (per.actual - per.revised) / per.revised DESC, per.name ASC, per.project_id;

-- name: DashboardActiveProjectsWithoutContract :many
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT ap.id, ap.project_no, ap.name
FROM ap
WHERE ap.status = 'active'
  AND NOT EXISTS (SELECT 1 FROM project_contracts pc
                  WHERE pc.project_id = ap.id AND pc.organization_id = @org_id::uuid)
ORDER BY ap.name ASC, ap.id;

-- ============================================================ finance

-- name: DashboardFinanceByCurrency :many
-- Proje kümesi P = ap içinde iptal dışı projeler; para birimi projeninki.
-- Güncel bedel GetProjectFinancialSummary co_effect formülü; gerçekleşen
-- maliyet = masraf + eski taşeron ödemeleri + Sprint 5 taşeron ödemeleri
-- (iki ödeme tablosu fiziksel olarak ayrı, migration 0039 -- çift sayım
-- yok). Açık alacak proje BAŞINA sıfırın altına düşürülmez.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
),
pn AS (SELECT ap.id, ap.currency, ap.contract_amount FROM ap WHERE ap.status <> 'cancelled'),
co AS (
    SELECT c.project_id,
           COALESCE(sum(c.grand_total) FILTER (WHERE c.change_type = 'addition' AND c.status = 'approved'), 0)
         - COALESCE(sum(c.grand_total) FILTER (WHERE c.change_type = 'deduction' AND c.status = 'approved'), 0) AS net
    FROM project_change_orders c
    WHERE c.organization_id = @org_id::uuid AND c.project_id IN (SELECT pn.id FROM pn)
    GROUP BY c.project_id
),
coll AS (
    SELECT c.project_id, sum(c.amount) AS total
    FROM project_collections c
    WHERE c.organization_id = @org_id::uuid AND c.voided_at IS NULL AND c.project_id IN (SELECT pn.id FROM pn)
    GROUP BY c.project_id
),
cost AS (
    SELECT x.project_id, sum(x.amount) AS total
    FROM (
        SELECT e.project_id, e.amount FROM project_expenses e
        WHERE e.organization_id = @org_id::uuid AND e.voided_at IS NULL
        UNION ALL
        SELECT sp.project_id, sp.amount FROM project_subcontractor_payments sp
        WHERE sp.organization_id = @org_id::uuid AND sp.voided_at IS NULL
        UNION ALL
        SELECT np.project_id, np.amount FROM subcontract_payments np
        WHERE np.organization_id = @org_id::uuid AND np.voided_at IS NULL
    ) x
    WHERE x.project_id IN (SELECT pn.id FROM pn)
    GROUP BY x.project_id
),
plan_coll AS (
    SELECT c.payment_plan_item_id, sum(c.amount) AS collected
    FROM project_collections c
    WHERE c.organization_id = @org_id::uuid AND c.voided_at IS NULL AND c.payment_plan_item_id IS NOT NULL
    GROUP BY c.payment_plan_item_id
),
od AS (
    SELECT i.project_id, count(*) AS cnt, sum(i.planned_amount - COALESCE(pc.collected, 0)) AS amount,
           min(i.due_date) AS oldest
    FROM project_payment_plan_items i
    LEFT JOIN plan_coll pc ON pc.payment_plan_item_id = i.id
    WHERE i.organization_id = @org_id::uuid AND i.project_id IN (SELECT pn.id FROM pn)
      AND i.status <> 'cancelled' AND i.due_date < @today::date
      AND i.planned_amount - COALESCE(pc.collected, 0) > 0
    GROUP BY i.project_id
),
inv AS (
    SELECT v.project_id, count(*) AS cnt, sum(v.amount) AS amount, min(v.due_date) AS oldest
    FROM project_invoices v
    WHERE v.organization_id = @org_id::uuid AND v.project_id IN (SELECT pn.id FROM pn)
      AND v.invoice_type = 'sales' AND v.status IN ('issued', 'sent') AND v.due_date < @today::date
    GROUP BY v.project_id
),
per AS (
    SELECT pn.currency,
           pn.contract_amount + COALESCE(co.net, 0) AS current_value,
           COALESCE(coll.total, 0) AS collected,
           COALESCE(cost.total, 0) AS realized,
           COALESCE(od.cnt, 0) AS od_cnt, COALESCE(od.amount, 0) AS od_amount, od.oldest AS od_oldest,
           COALESCE(inv.cnt, 0) AS inv_cnt, COALESCE(inv.amount, 0) AS inv_amount, inv.oldest AS inv_oldest
    FROM pn
    LEFT JOIN co ON co.project_id = pn.id
    LEFT JOIN coll ON coll.project_id = pn.id
    LEFT JOIN cost ON cost.project_id = pn.id
    LEFT JOIN od ON od.project_id = pn.id
    LEFT JOIN inv ON inv.project_id = pn.id
)
SELECT per.currency::text AS currency,
       sum(per.current_value)::numeric(18,2) AS portfolio_value,
       sum(per.collected)::numeric(18,2) AS collected_total,
       sum(GREATEST(per.current_value - per.collected, 0))::numeric(18,2) AS open_receivable,
       sum(per.realized)::numeric(18,2) AS realized_cost,
       (CASE WHEN sum(per.current_value) > 0
             THEN round(sum(per.collected) / sum(per.current_value) * 100, 1) END)::numeric AS collection_pct,
       sum(per.od_cnt)::int AS overdue_plan_count,
       sum(per.od_amount)::numeric(18,2) AS overdue_plan_amount,
       min(per.od_oldest)::date AS overdue_plan_oldest,
       sum(per.inv_cnt)::int AS overdue_invoice_count,
       sum(per.inv_amount)::numeric(18,2) AS overdue_invoice_amount,
       min(per.inv_oldest)::date AS overdue_invoice_oldest
FROM per
GROUP BY per.currency
ORDER BY per.currency;

-- name: DashboardFinanceMonthly :many
-- Aylık nakit hareketleri (trend_start .. next_month_start), iptal edilmiş
-- projeler DAHİL (nakit gerçektir). Taşeron ödemesi = eski + Sprint 5.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
),
flows AS (
    SELECT ap.currency, date_trunc('month', c.received_date)::date AS m,
           c.amount AS coll, 0::numeric AS exp, 0::numeric AS sub
    FROM project_collections c JOIN ap ON ap.id = c.project_id
    WHERE c.organization_id = @org_id::uuid AND c.voided_at IS NULL
      AND c.received_date >= @trend_start::date AND c.received_date < @next_month_start::date
    UNION ALL
    SELECT ap.currency, date_trunc('month', e.expense_date)::date, 0::numeric, e.amount, 0::numeric
    FROM project_expenses e JOIN ap ON ap.id = e.project_id
    WHERE e.organization_id = @org_id::uuid AND e.voided_at IS NULL
      AND e.expense_date >= @trend_start::date AND e.expense_date < @next_month_start::date
    UNION ALL
    SELECT ap.currency, date_trunc('month', sp.paid_date)::date, 0::numeric, 0::numeric, sp.amount
    FROM project_subcontractor_payments sp JOIN ap ON ap.id = sp.project_id
    WHERE sp.organization_id = @org_id::uuid AND sp.voided_at IS NULL
      AND sp.paid_date >= @trend_start::date AND sp.paid_date < @next_month_start::date
    UNION ALL
    SELECT ap.currency, date_trunc('month', np.paid_date)::date, 0::numeric, 0::numeric, np.amount
    FROM subcontract_payments np JOIN ap ON ap.id = np.project_id
    WHERE np.organization_id = @org_id::uuid AND np.voided_at IS NULL
      AND np.paid_date >= @trend_start::date AND np.paid_date < @next_month_start::date
)
SELECT flows.currency::text AS currency, flows.m::date AS month,
       sum(flows.coll)::numeric(18,2) AS collections,
       sum(flows.exp)::numeric(18,2) AS expenses,
       sum(flows.sub)::numeric(18,2) AS subcontract_payments
FROM flows
GROUP BY flows.currency, flows.m
ORDER BY flows.currency, flows.m;

-- name: DashboardPlanItemsDue :many
-- Kalan tutarı olan (iptal dışı) ödeme planı kalemleri, vade aralığında,
-- en eski vade önce. Vadesi geçenler için from = NULL, to = dün;
-- yaklaşanlar için bugün .. bugün+13.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
),
plan_coll AS (
    SELECT c.payment_plan_item_id, sum(c.amount) AS collected
    FROM project_collections c
    WHERE c.organization_id = @org_id::uuid AND c.voided_at IS NULL AND c.payment_plan_item_id IS NOT NULL
    GROUP BY c.payment_plan_item_id
)
SELECT i.id, i.project_id, i.name, ap.name AS project_name, ap.currency::text AS currency,
       (i.planned_amount - COALESCE(pc.collected, 0))::numeric(18,2) AS remaining,
       i.due_date
FROM project_payment_plan_items i
JOIN ap ON ap.id = i.project_id AND ap.status <> 'cancelled'
LEFT JOIN plan_coll pc ON pc.payment_plan_item_id = i.id
WHERE i.organization_id = @org_id::uuid AND i.status <> 'cancelled'
  AND i.due_date IS NOT NULL
  AND (sqlc.narg('due_from')::date IS NULL OR i.due_date >= sqlc.narg('due_from')::date)
  AND i.due_date <= @due_to::date
  AND i.planned_amount - COALESCE(pc.collected, 0) > 0
ORDER BY i.due_date ASC, i.id
LIMIT @row_limit::int;

-- name: DashboardOverdueSalesInvoicesTop :many
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT v.id, v.project_id, v.invoice_no, ap.name AS project_name, ap.currency::text AS currency,
       v.amount, v.due_date
FROM project_invoices v
JOIN ap ON ap.id = v.project_id AND ap.status <> 'cancelled'
WHERE v.organization_id = @org_id::uuid AND v.invoice_type = 'sales'
  AND v.status IN ('issued', 'sent') AND v.due_date < @today::date
ORDER BY v.due_date ASC, v.id
LIMIT 3;

-- ============================================================ change_orders

-- name: DashboardChangeOrdersByCurrency :many
-- Ek işler (projects.finance.read): müşteri onayında (sent), taslak ve bu
-- ay onaylananların net etkisi (ek - eksiltme), ek işin para biriminde.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT c.currency::text AS currency,
       (count(*) FILTER (WHERE c.status = 'sent'))::int AS awaiting_count,
       COALESCE(sum(c.grand_total) FILTER (WHERE c.status = 'sent'), 0)::numeric(18,2) AS awaiting_amount,
       (min((c.sent_at AT TIME ZONE 'Europe/Istanbul')::date) FILTER (WHERE c.status = 'sent'))::date AS awaiting_oldest,
       (count(*) FILTER (WHERE c.status = 'draft'))::int AS draft_count,
       COALESCE(sum(c.grand_total) FILTER (WHERE c.status = 'draft'), 0)::numeric(18,2) AS draft_amount,
       (COALESCE(sum(c.grand_total) FILTER (WHERE c.status = 'approved' AND c.change_type = 'addition'), 0)
      - COALESCE(sum(c.grand_total) FILTER (WHERE c.status = 'approved' AND c.change_type = 'deduction'), 0)
       )::numeric(18,2) AS approved_net_this_month
FROM project_change_orders c
JOIN ap ON ap.id = c.project_id AND ap.status <> 'cancelled'
WHERE c.organization_id = @org_id::uuid
  AND (c.status IN ('sent', 'draft')
       OR (c.status = 'approved'
           AND c.approved_at >= @month_start_ts::timestamptz
           AND c.approved_at < @next_month_start_ts::timestamptz))
GROUP BY c.currency
ORDER BY c.currency;

-- name: DashboardChangeOrdersAwaitingTop :many
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT c.id, c.project_id, c.title, ap.name AS project_name, c.currency::text AS currency, c.grand_total,
       (c.sent_at AT TIME ZONE 'Europe/Istanbul')::date AS sent_date
FROM project_change_orders c
JOIN ap ON ap.id = c.project_id AND ap.status <> 'cancelled'
WHERE c.organization_id = @org_id::uuid AND c.status = 'sent'
ORDER BY c.sent_at ASC NULLS LAST, c.id
LIMIT 3;

-- ============================================================ offers

-- name: DashboardOffersByCurrency :many
-- Firma geneli, arşivlenmiş (is_passive) teklifler HARİÇ; tutar ve para
-- birimi güncel revizyondan. Karar tarihi offer_events'ten: müşteri
-- kararı (customer_accepted/rejected) ya da iç karar (offer_updated,
-- metadata.to_status = güncel durum; eski kayıtlarda metadata yoksa
-- güncel durum varsayılır) -- offers.updated_at KULLANILMAZ.
WITH o AS (
    SELECT o.id, o.status, o.offer_date, o.current_revision_id,
           r.currency, r.grand_total, r.valid_until
    FROM offers o
    JOIN offer_revisions r ON r.id = o.current_revision_id AND r.organization_id = o.organization_id
    WHERE o.organization_id = @org_id::uuid AND o.is_passive = false
),
dec AS (
    SELECT o.id,
           (SELECT max(e.created_at) FROM offer_events e
            WHERE e.organization_id = @org_id::uuid AND e.offer_id = o.id
              AND e.revision_id = o.current_revision_id
              AND (e.event_type IN ('customer_accepted', 'customer_rejected')
                   OR (e.event_type = 'offer_updated'
                       AND COALESCE(e.metadata->>'to_status', o.status) = o.status))) AS decided_at
    FROM o
    WHERE o.status IN (@status_accepted::text, @status_rejected::text)
),
x AS (
    -- viewed_7d: teklifin EN SON görüntülenmesi son 7 günde mi? Teklif
    -- BAŞINA tek indeks araması (idx_offer_events_offer_id, ORDER BY ...
    -- LIMIT 1 ilk satırda durur): her paylaşım linki açılışı ayrı bir
    -- customer_viewed yazdığından firma geneli görüntülenme satırlarını
    -- taramak görüntülenme sayısıyla büyürdü.
    SELECT o.*, dec.decided_at,
           COALESCE(lv.created_at >= @d7_start_ts::timestamptz, false) AS viewed_7d,
           (o.status = @status_accepted::text AND NOT EXISTS (
                SELECT 1 FROM projects p
                WHERE p.source_offer_id = o.id AND p.organization_id = @org_id::uuid)) AS not_converted
    FROM o
    LEFT JOIN dec ON dec.id = o.id
    LEFT JOIN LATERAL (
        SELECT e.created_at FROM offer_events e
        WHERE e.offer_id = o.id AND e.organization_id = @org_id::uuid
          AND e.event_type = 'customer_viewed'
        ORDER BY e.created_at DESC
        LIMIT 1
    ) lv ON true
)
SELECT x.currency::text AS currency,
       count(*)::int AS total,
       (count(*) FILTER (WHERE x.status = @status_draft::text))::int AS draft_count,
       COALESCE(sum(x.grand_total) FILTER (WHERE x.status = @status_draft::text), 0)::numeric(18,2) AS draft_amount,
       (count(*) FILTER (WHERE x.status = @status_sent::text))::int AS awaiting_count,
       COALESCE(sum(x.grand_total) FILTER (WHERE x.status = @status_sent::text), 0)::numeric(18,2) AS awaiting_amount,
       (count(*) FILTER (WHERE x.status = @status_accepted::text
                           AND x.decided_at >= @d90_start_ts::timestamptz))::int AS accepted_90d_count,
       COALESCE(sum(x.grand_total) FILTER (WHERE x.status = @status_accepted::text
                           AND x.decided_at >= @d90_start_ts::timestamptz), 0)::numeric(18,2) AS accepted_90d_amount,
       (count(*) FILTER (WHERE x.status = @status_rejected::text
                           AND x.decided_at >= @d90_start_ts::timestamptz))::int AS rejected_90d_count,
       COALESCE(sum(x.grand_total) FILTER (WHERE x.status = @status_rejected::text
                           AND x.decided_at >= @d90_start_ts::timestamptz), 0)::numeric(18,2) AS rejected_90d_amount,
       (count(*) FILTER (WHERE x.status = @status_sent::text
                           AND x.valid_until BETWEEN @today::date AND @plus6::date))::int AS expiring_7d_count,
       (count(*) FILTER (WHERE x.status = @status_sent::text AND x.valid_until < @today::date))::int AS expired_count,
       COALESCE(sum(x.grand_total) FILTER (WHERE x.status = @status_sent::text
                           AND x.valid_until < @today::date), 0)::numeric(18,2) AS expired_amount,
       (min(x.valid_until) FILTER (WHERE x.status = @status_sent::text AND x.valid_until < @today::date))::date AS expired_oldest,
       (count(*) FILTER (WHERE x.viewed_7d))::int AS viewed_7d_count,
       (count(*) FILTER (WHERE x.not_converted))::int AS not_converted_count,
       COALESCE(sum(x.grand_total) FILTER (WHERE x.not_converted), 0)::numeric(18,2) AS not_converted_amount,
       (min((x.decided_at AT TIME ZONE 'Europe/Istanbul')::date) FILTER (WHERE x.not_converted))::date AS not_converted_oldest
FROM x
GROUP BY x.currency
ORDER BY x.currency;

-- name: DashboardOffersExpiredTop :many
SELECT o.id, o.offer_no, r.customer_name, r.currency::text AS currency, r.grand_total, r.valid_until
FROM offers o
JOIN offer_revisions r ON r.id = o.current_revision_id AND r.organization_id = o.organization_id
WHERE o.organization_id = @org_id::uuid AND o.is_passive = false
  AND o.status = @status_sent::text AND r.valid_until < @today::date
ORDER BY r.valid_until ASC, o.offer_no ASC
LIMIT 3;

-- name: DashboardOffersNotConvertedTop :many
-- En uzun süredir dönüşüm bekleyenler önce: karar tarihi DashboardOffers
-- ByCurrency'deki "dec" ile BİREBİR aynı kural (grubun oldest_days'i de
-- oradan gelir). offer_date teklifin oluşturulma günüdür, kabulden bu yana
-- geçen bekleme süresini göstermez.
WITH nc AS (
    SELECT o.id, o.offer_no, r.customer_name, r.currency, r.grand_total,
           (SELECT max(e.created_at) FROM offer_events e
            WHERE e.organization_id = @org_id::uuid AND e.offer_id = o.id
              AND e.revision_id = o.current_revision_id
              AND (e.event_type IN ('customer_accepted', 'customer_rejected')
                   OR (e.event_type = 'offer_updated'
                       AND COALESCE(e.metadata->>'to_status', o.status) = o.status))) AS decided_at
    FROM offers o
    JOIN offer_revisions r ON r.id = o.current_revision_id AND r.organization_id = o.organization_id
    WHERE o.organization_id = @org_id::uuid AND o.is_passive = false
      AND o.status = @status_accepted::text
      AND NOT EXISTS (SELECT 1 FROM projects p
                      WHERE p.source_offer_id = o.id AND p.organization_id = @org_id::uuid)
)
SELECT nc.id, nc.offer_no, nc.customer_name, nc.currency::text AS currency, nc.grand_total
FROM nc
ORDER BY nc.decided_at ASC NULLS LAST, nc.offer_no ASC, nc.id
LIMIT 3;

-- name: DashboardUpcomingOfferExpiries :many
SELECT o.id, o.offer_no, r.customer_name, r.currency::text AS currency, r.grand_total, r.valid_until
FROM offers o
JOIN offer_revisions r ON r.id = o.current_revision_id AND r.organization_id = o.organization_id
WHERE o.organization_id = @org_id::uuid AND o.is_passive = false
  AND o.status = @status_sent::text
  AND r.valid_until BETWEEN @today::date AND @plus13::date
ORDER BY r.valid_until ASC, o.offer_no ASC
LIMIT 8;

-- ============================================================ procurement

-- name: DashboardProcurementCounts :one
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
),
apn AS (SELECT ap.id FROM ap WHERE ap.status <> 'cancelled'),
rq AS (
    SELECT r.status, r.due_date,
           EXISTS (SELECT 1 FROM supplier_quotations q
                   WHERE q.rfq_id = r.id AND q.organization_id = @org_id::uuid) AS has_quote
    FROM rfqs r
    WHERE r.organization_id = @org_id::uuid AND r.project_id IN (SELECT apn.id FROM apn)
      AND r.status = 'issued'
)
SELECT
    (SELECT count(*) FROM purchase_requests pr
      WHERE pr.organization_id = @org_id::uuid AND pr.project_id IN (SELECT apn.id FROM apn)
        AND pr.status = 'draft')::int AS pr_draft,
    (SELECT count(*) FROM purchase_requests pr
      WHERE pr.organization_id = @org_id::uuid AND pr.project_id IN (SELECT apn.id FROM apn)
        AND pr.status = 'submitted')::int AS pr_submitted,
    (SELECT count(*) FROM rq)::int AS rfq_issued,
    (SELECT count(*) FROM rq WHERE rq.due_date < @today::date AND rq.has_quote)::int AS rfq_awaiting_award,
    (SELECT min(rq.due_date) FROM rq WHERE rq.due_date < @today::date AND rq.has_quote)::date AS rfq_awaiting_award_oldest,
    (SELECT count(*) FROM rq WHERE rq.due_date < @today::date AND NOT rq.has_quote)::int AS rfq_past_due_no_quote,
    (SELECT min(rq.due_date) FROM rq WHERE rq.due_date < @today::date AND NOT rq.has_quote)::date AS rfq_past_due_no_quote_oldest,
    (SELECT count(*) FROM purchase_orders po
      WHERE po.organization_id = @org_id::uuid AND po.project_id IN (SELECT apn.id FROM apn)
        AND po.status = 'draft')::int AS po_draft,
    (SELECT count(*) FROM purchase_orders po
      WHERE po.organization_id = @org_id::uuid AND po.project_id IN (SELECT apn.id FROM apn)
        AND po.status = 'approved')::int AS po_approved_open,
    (SELECT count(*) FROM purchase_orders po
      WHERE po.organization_id = @org_id::uuid AND po.project_id IN (SELECT apn.id FROM apn)
        AND po.status = 'approved' AND po.expected_delivery_date < @today::date)::int AS po_late_delivery;

-- name: DashboardProcurementAttention :many
-- Tutar taşıyan dikkat kodlarının para birimi başına toplamları: onay bekleyen
-- talepler (tahmini tutar, proje para birimi), sipariş taslakları ve
-- teslimi geciken siparişler (siparişin kendi para birimi). oldest: bekleme
-- ya da vade başlangıcı (İstanbul takvim günü).
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT 'purchase_request_approval'::text AS code, ap.currency::text AS currency, count(*)::int AS cnt,
       COALESCE(sum(pr.estimated_total), 0)::numeric(18,2) AS amount,
       min((COALESCE(pr.submitted_at, pr.created_at) AT TIME ZONE 'Europe/Istanbul')::date)::date AS oldest
FROM purchase_requests pr
JOIN ap ON ap.id = pr.project_id AND ap.status <> 'cancelled'
WHERE pr.organization_id = @org_id::uuid AND pr.status = 'submitted'
GROUP BY ap.currency
UNION ALL
SELECT 'purchase_order_draft'::text, po.currency::text, count(*)::int,
       COALESCE(sum(po.total), 0)::numeric(18,2),
       min((po.created_at AT TIME ZONE 'Europe/Istanbul')::date)::date
FROM purchase_orders po
JOIN ap ON ap.id = po.project_id AND ap.status <> 'cancelled'
WHERE po.organization_id = @org_id::uuid AND po.status = 'draft'
GROUP BY po.currency
UNION ALL
SELECT 'po_late_delivery'::text, po.currency::text, count(*)::int,
       COALESCE(sum(po.total), 0)::numeric(18,2),
       min(po.expected_delivery_date)::date
FROM purchase_orders po
JOIN ap ON ap.id = po.project_id AND ap.status <> 'cancelled'
WHERE po.organization_id = @org_id::uuid AND po.status = 'approved' AND po.expected_delivery_date < @today::date
GROUP BY po.currency;

-- name: DashboardPurchaseRequestsSubmittedTop :many
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT pr.id, pr.project_id, pr.pr_no, pr.title, ap.name AS project_name, ap.currency::text AS currency,
       pr.estimated_total,
       (COALESCE(pr.submitted_at, pr.created_at) AT TIME ZONE 'Europe/Istanbul')::date AS since_date
FROM purchase_requests pr
JOIN ap ON ap.id = pr.project_id AND ap.status <> 'cancelled'
WHERE pr.organization_id = @org_id::uuid AND pr.status = 'submitted'
ORDER BY COALESCE(pr.submitted_at, pr.created_at) ASC, pr.id
LIMIT 3;

-- name: DashboardPurchaseOrdersTop :many
-- Sipariş kayıtları: mode 'draft' (onaylanmamış taslaklar, en eski önce)
-- ya da 'late' (teslimi geciken onaylı siparişler, en eski vade önce).
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT po.id, po.project_id, po.po_no, ap.name AS project_name, po.currency::text AS currency, po.total,
       (CASE WHEN @mode::text = 'late' THEN po.expected_delivery_date
             ELSE (po.created_at AT TIME ZONE 'Europe/Istanbul')::date END)::date AS ref_date
FROM purchase_orders po
JOIN ap ON ap.id = po.project_id AND ap.status <> 'cancelled'
WHERE po.organization_id = @org_id::uuid
  AND ((@mode::text = 'draft' AND po.status = 'draft')
       OR (@mode::text = 'late' AND po.status = 'approved' AND po.expected_delivery_date < @today::date))
ORDER BY (CASE WHEN @mode::text = 'late' THEN po.expected_delivery_date
               ELSE (po.created_at AT TIME ZONE 'Europe/Istanbul')::date END) ASC, po.id
LIMIT 3;

-- name: DashboardRFQsPastDueTop :many
-- Süresi dolmuş açık (issued) RFQ'lar: with_quotes = true ise teklif
-- toplanmış (karar bekliyor), false ise hiç teklif gelmemiş.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT r.id, r.project_id, r.rfq_no, r.title, ap.name AS project_name, r.due_date
FROM rfqs r
JOIN ap ON ap.id = r.project_id AND ap.status <> 'cancelled'
WHERE r.organization_id = @org_id::uuid AND r.status = 'issued' AND r.due_date < @today::date
  AND EXISTS (SELECT 1 FROM supplier_quotations q
              WHERE q.rfq_id = r.id AND q.organization_id = @org_id::uuid) = @with_quotes::boolean
ORDER BY r.due_date ASC, r.id
LIMIT 3;

-- name: DashboardProcurementApprovedThisMonth :many
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT po.currency::text AS currency, count(*)::int AS cnt, COALESCE(sum(po.total), 0)::numeric(18,2) AS amount
FROM purchase_orders po
JOIN ap ON ap.id = po.project_id AND ap.status <> 'cancelled'
WHERE po.organization_id = @org_id::uuid AND po.status <> 'cancelled'
  AND po.approved_at >= @month_start_ts::timestamptz AND po.approved_at < @next_month_start_ts::timestamptz
GROUP BY po.currency
ORDER BY po.currency;

-- name: DashboardUpcomingPODeliveries :many
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT po.id, po.project_id, po.po_no, ap.name AS project_name, po.expected_delivery_date
FROM purchase_orders po
JOIN ap ON ap.id = po.project_id AND ap.status <> 'cancelled'
WHERE po.organization_id = @org_id::uuid AND po.status = 'approved'
  AND po.expected_delivery_date BETWEEN @today::date AND @plus13::date
ORDER BY po.expected_delivery_date ASC, po.id
LIMIT 8;

-- ============================================================ subcontracts

-- name: DashboardSubcontractActiveCount :one
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT count(*)::int AS active_count
FROM project_subcontracts s
JOIN ap ON ap.id = s.project_id AND ap.status <> 'cancelled'
WHERE s.organization_id = @org_id::uuid AND s.status = 'active';

-- name: DashboardSubcontractValues :many
-- Güncel sözleşme değeri: GetSubcontractCurrentValue / new_sc_value
-- formülü (orijinal + onaylı ekler - onaylı eksiltmeler), taslak ve iptal
-- sözleşmeler hariç.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
),
sc AS (
    SELECT s.id, s.currency, s.original_amount
    FROM project_subcontracts s
    JOIN ap ON ap.id = s.project_id AND ap.status <> 'cancelled'
    WHERE s.organization_id = @org_id::uuid AND s.status NOT IN ('draft', 'cancelled')
),
coe AS (
    SELECT co.subcontract_id,
           COALESCE(sum(co.amount) FILTER (WHERE co.change_type = 'addition' AND co.status = 'approved'), 0) AS adds,
           COALESCE(sum(co.amount) FILTER (WHERE co.change_type = 'deduction' AND co.status = 'approved'), 0) AS deds
    FROM subcontract_change_orders co
    WHERE co.organization_id = @org_id::uuid AND co.subcontract_id IN (SELECT sc.id FROM sc)
    GROUP BY co.subcontract_id
)
SELECT sc.currency::text AS currency,
       sum(sc.original_amount + COALESCE(coe.adds, 0) - COALESCE(coe.deds, 0))::numeric(18,2) AS current_value
FROM sc
LEFT JOIN coe ON coe.subcontract_id = sc.id
GROUP BY sc.currency
ORDER BY sc.currency;

-- name: DashboardSubcontractPaid :many
-- Ödenen (projects.subcontract_payments.read): iptal edilmemiş Sprint 5
-- ödemeleri, DashboardSubcontractValues ile aynı sözleşme kümesi;
-- oran = ödenen / güncel değer.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
),
sc AS (
    SELECT s.id, s.currency, s.original_amount
    FROM project_subcontracts s
    JOIN ap ON ap.id = s.project_id AND ap.status <> 'cancelled'
    WHERE s.organization_id = @org_id::uuid AND s.status NOT IN ('draft', 'cancelled')
),
coe AS (
    SELECT co.subcontract_id,
           COALESCE(sum(co.amount) FILTER (WHERE co.change_type = 'addition' AND co.status = 'approved'), 0) AS adds,
           COALESCE(sum(co.amount) FILTER (WHERE co.change_type = 'deduction' AND co.status = 'approved'), 0) AS deds
    FROM subcontract_change_orders co
    WHERE co.organization_id = @org_id::uuid AND co.subcontract_id IN (SELECT sc.id FROM sc)
    GROUP BY co.subcontract_id
),
paid AS (
    SELECT pm.subcontract_id, sum(pm.amount) AS total
    FROM subcontract_payments pm
    WHERE pm.organization_id = @org_id::uuid AND pm.voided_at IS NULL
      AND pm.subcontract_id IN (SELECT sc.id FROM sc)
    GROUP BY pm.subcontract_id
),
per AS (
    SELECT sc.currency, sc.original_amount + COALESCE(coe.adds, 0) - COALESCE(coe.deds, 0) AS current_value,
           COALESCE(paid.total, 0) AS paid
    FROM sc
    LEFT JOIN coe ON coe.subcontract_id = sc.id
    LEFT JOIN paid ON paid.subcontract_id = sc.id
)
SELECT per.currency::text AS currency,
       sum(per.paid)::numeric(18,2) AS paid_to_date,
       (CASE WHEN sum(per.current_value) > 0
             THEN round(sum(per.paid) / sum(per.current_value) * 100, 1) END)::numeric AS paid_pct
FROM per
GROUP BY per.currency
ORDER BY per.currency;

-- Taşeron dikkat kodları spec §4.6 desenindedir: para birimi başına TEK
-- toplam sorgusu (sayı, tutar, en eski gün) + en eski 3 kaydı getiren
-- ayrı bir LIMIT 3 sorgusu -- satırların tamamı Go'ya taşınmaz.

-- name: DashboardClaimsSubmittedTotals :many
-- Onay bekleyen taşeron hakedişleri (projects.subcontract_claims.read),
-- sözleşmenin para biriminde net ödenecek tutar.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT s.currency::text AS currency, count(*)::int AS cnt,
       COALESCE(sum(c.net_payable), 0)::numeric(18,2) AS amount,
       min((COALESCE(c.submitted_at, c.created_at) AT TIME ZONE 'Europe/Istanbul')::date)::date AS oldest
FROM subcontract_progress_claims c
JOIN ap ON ap.id = c.project_id AND ap.status <> 'cancelled'
JOIN project_subcontracts s ON s.id = c.subcontract_id AND s.organization_id = @org_id::uuid
WHERE c.organization_id = @org_id::uuid AND c.status = 'submitted'
GROUP BY s.currency
ORDER BY s.currency;

-- name: DashboardClaimsSubmittedTop :many
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT c.id, c.project_id, c.subcontract_id, c.claim_number, ap.name AS project_name,
       s.currency::text AS currency, c.net_payable,
       (COALESCE(c.submitted_at, c.created_at) AT TIME ZONE 'Europe/Istanbul')::date AS since_date
FROM subcontract_progress_claims c
JOIN ap ON ap.id = c.project_id AND ap.status <> 'cancelled'
JOIN project_subcontracts s ON s.id = c.subcontract_id AND s.organization_id = @org_id::uuid
WHERE c.organization_id = @org_id::uuid AND c.status = 'submitted'
ORDER BY COALESCE(c.submitted_at, c.created_at) ASC, c.id
LIMIT 3;

-- name: DashboardClaimsCertifiedUnpaidTotals :many
-- Onaylanmış ama tamamı ödenmemiş hakedişler (claims.read +
-- subcontract_payments.read): net ödenecek - bağlı, iptal edilmemiş
-- ödemeler. Hakedişe bağlanmamış avans ödemeleri bu tutarı azaltmaz.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
),
paid AS (
    SELECT pm.progress_claim_id, sum(pm.amount) AS total
    FROM subcontract_payments pm
    WHERE pm.organization_id = @org_id::uuid AND pm.voided_at IS NULL AND pm.progress_claim_id IS NOT NULL
    GROUP BY pm.progress_claim_id
)
SELECT s.currency::text AS currency, count(*)::int AS cnt,
       COALESCE(sum(c.net_payable - COALESCE(paid.total, 0)), 0)::numeric(18,2) AS amount,
       min((COALESCE(c.certified_at, c.updated_at) AT TIME ZONE 'Europe/Istanbul')::date)::date AS oldest
FROM subcontract_progress_claims c
JOIN ap ON ap.id = c.project_id AND ap.status <> 'cancelled'
JOIN project_subcontracts s ON s.id = c.subcontract_id AND s.organization_id = @org_id::uuid
LEFT JOIN paid ON paid.progress_claim_id = c.id
WHERE c.organization_id = @org_id::uuid AND c.status = 'certified'
  AND c.net_payable - COALESCE(paid.total, 0) > 0
GROUP BY s.currency
ORDER BY s.currency;

-- name: DashboardClaimsCertifiedUnpaidTop :many
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
),
paid AS (
    SELECT pm.progress_claim_id, sum(pm.amount) AS total
    FROM subcontract_payments pm
    WHERE pm.organization_id = @org_id::uuid AND pm.voided_at IS NULL AND pm.progress_claim_id IS NOT NULL
    GROUP BY pm.progress_claim_id
)
SELECT c.id, c.project_id, c.subcontract_id, c.claim_number, ap.name AS project_name,
       s.currency::text AS currency,
       (c.net_payable - COALESCE(paid.total, 0))::numeric(18,2) AS unpaid,
       (COALESCE(c.certified_at, c.updated_at) AT TIME ZONE 'Europe/Istanbul')::date AS since_date
FROM subcontract_progress_claims c
JOIN ap ON ap.id = c.project_id AND ap.status <> 'cancelled'
JOIN project_subcontracts s ON s.id = c.subcontract_id AND s.organization_id = @org_id::uuid
LEFT JOIN paid ON paid.progress_claim_id = c.id
WHERE c.organization_id = @org_id::uuid AND c.status = 'certified'
  AND c.net_payable - COALESCE(paid.total, 0) > 0
ORDER BY COALESCE(c.certified_at, c.updated_at) ASC, c.id
LIMIT 3;

-- name: DashboardSubcontractCOsSubmittedTotals :many
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT s.currency::text AS currency, count(*)::int AS cnt,
       COALESCE(sum(co.amount), 0)::numeric(18,2) AS amount,
       min((COALESCE(co.requested_at, co.created_at) AT TIME ZONE 'Europe/Istanbul')::date)::date AS oldest
FROM subcontract_change_orders co
JOIN ap ON ap.id = co.project_id AND ap.status <> 'cancelled'
JOIN project_subcontracts s ON s.id = co.subcontract_id AND s.organization_id = @org_id::uuid
WHERE co.organization_id = @org_id::uuid AND co.status = 'submitted'
GROUP BY s.currency
ORDER BY s.currency;

-- name: DashboardSubcontractCOsSubmittedTop :many
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT co.id, co.project_id, co.subcontract_id, co.number, co.title, ap.name AS project_name,
       s.currency::text AS currency, co.amount,
       (COALESCE(co.requested_at, co.created_at) AT TIME ZONE 'Europe/Istanbul')::date AS since_date
FROM subcontract_change_orders co
JOIN ap ON ap.id = co.project_id AND ap.status <> 'cancelled'
JOIN project_subcontracts s ON s.id = co.subcontract_id AND s.organization_id = @org_id::uuid
WHERE co.organization_id = @org_id::uuid AND co.status = 'submitted'
ORDER BY COALESCE(co.requested_at, co.created_at) ASC, co.id
LIMIT 3;

-- ============================================================ cost_control

-- name: DashboardBudgetCounts :one
-- Açık projelerin bütçe durumu (projects.budget.read); proje başına tek
-- bütçe (UNIQUE project_id), satır yoksa "bütçesiz".
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT
    (count(*) FILTER (WHERE b.id IS NULL))::int AS no_budget,
    (count(*) FILTER (WHERE b.status = 'draft'))::int AS draft,
    (count(*) FILTER (WHERE b.status = 'baselined'))::int AS baselined,
    count(*)::int AS open_projects
FROM ap
LEFT JOIN project_budgets b ON b.project_id = ap.id AND b.organization_id = @org_id::uuid
WHERE ap.status IN ('planned', 'active', 'paused');

-- name: DashboardActiveProjectsWithoutBaselineTop :many
-- İlk 3 proje + toplam sayı (pencere sayımı LIMIT'ten önce hesaplanır).
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT ap.id, ap.project_no, ap.name, (count(*) OVER ())::int AS total_count
FROM ap
WHERE ap.status = 'active'
  AND NOT EXISTS (SELECT 1 FROM project_budgets b
                  WHERE b.project_id = ap.id AND b.organization_id = @org_id::uuid AND b.status = 'baselined')
ORDER BY ap.name ASC, ap.id
LIMIT 3;

-- name: DashboardPendingAdjustmentsTotals :many
-- Onay bekleyen (draft) bütçe revizyonları, bütçenin para biriminde.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT b.currency::text AS currency, count(*)::int AS cnt,
       COALESCE(sum(a.amount), 0)::numeric(18,2) AS amount,
       min((a.created_at AT TIME ZONE 'Europe/Istanbul')::date)::date AS oldest
FROM project_budget_adjustments a
JOIN ap ON ap.id = a.project_id AND ap.status IN ('planned', 'active', 'paused')
JOIN project_budgets b ON b.id = a.budget_id AND b.organization_id = @org_id::uuid
WHERE a.organization_id = @org_id::uuid AND a.status = 'draft'
GROUP BY b.currency
ORDER BY b.currency;

-- name: DashboardPendingAdjustmentsTop :many
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT a.id, a.project_id, a.reason, ap.name AS project_name, b.currency::text AS currency, a.amount,
       (a.created_at AT TIME ZONE 'Europe/Istanbul')::date AS since_date
FROM project_budget_adjustments a
JOIN ap ON ap.id = a.project_id AND ap.status IN ('planned', 'active', 'paused')
JOIN project_budgets b ON b.id = a.budget_id AND b.organization_id = @org_id::uuid
WHERE a.organization_id = @org_id::uuid AND a.status = 'draft'
ORDER BY a.created_at ASC, a.id
LIMIT 3;

-- name: DashboardCommittedActive :many
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT cm.currency::text AS currency, sum(cm.committed_amount)::numeric(18,2) AS amount
FROM project_commitments cm
JOIN ap ON ap.id = cm.project_id AND ap.status IN ('planned', 'active', 'paused')
WHERE cm.organization_id = @org_id::uuid AND cm.status = 'active'
GROUP BY cm.currency
ORDER BY cm.currency;

-- ============================================================ contracts

-- name: DashboardContractCounts :one
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT
    (count(*) FILTER (WHERE pc.status = 'draft'))::int AS draft,
    (count(*) FILTER (WHERE pc.status = 'active'))::int AS active,
    (count(*) FILTER (WHERE pc.status = 'completed'))::int AS completed,
    (count(*) FILTER (WHERE pc.status = 'cancelled'))::int AS cancelled,
    (count(*) FILTER (WHERE pc.status = 'terminated'))::int AS terminated,
    (count(*) FILTER (WHERE pc.status = 'active'
                        AND pc.planned_completion_date < @today::date))::int AS past_planned_completion
FROM project_contracts pc
JOIN ap ON ap.id = pc.project_id
WHERE pc.organization_id = @org_id::uuid;

-- name: DashboardContractsAttention :many
-- İptal dışı projelerde: taslakta bekleyen sözleşmeler (kind 'draft',
-- oluşturulma günü) ve planlanan bitişi geçmiş aktif sözleşmeler (kind
-- 'past', planlanan bitiş günü).
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT (CASE WHEN pc.status = 'draft' THEN 'draft' ELSE 'past' END)::text AS kind,
       pc.id, pc.project_id, ap.project_no, ap.name AS project_name,
       (CASE WHEN pc.status = 'draft' THEN (pc.created_at AT TIME ZONE 'Europe/Istanbul')::date
             ELSE pc.planned_completion_date END)::date AS ref_date
FROM project_contracts pc
JOIN ap ON ap.id = pc.project_id AND ap.status <> 'cancelled'
WHERE pc.organization_id = @org_id::uuid
  AND (pc.status = 'draft' OR (pc.status = 'active' AND pc.planned_completion_date < @today::date))
ORDER BY 6 ASC, pc.id;

-- ============================================================ tasks

-- name: DashboardLinkedEmployee :many
-- /tasks/mine ile AYNI çözümleme (GetEmployeeByUserID): giriş yapan
-- kullanıcıya bağlı personel -- yalnızca kimlik seçilir (maaş/yevmiye
-- ASLA).
SELECT e.id FROM employees e
WHERE e.user_id = @user_id::uuid AND e.organization_id = @org_id::uuid
LIMIT 1;

-- Görev sayaçları/listeleri: AÇIK görev yalnızca AÇIK projede (planlı/
-- aktif/beklemede) sayılır -- tamamlanmış/iptal projenin unutulmuş
-- görevleri sonsuza dek "gecikmiş" görünmesin. /tasks/mine ve /tasks/team
-- 'open' modu (project_operations.sql ListMyTasks/ListTeamTasks) AYNI
-- kuralı uygular; ikisi ayrışırsa ana sayfa ile Görevler farklı sayı
-- gösterir. completed_7d tamamlanmış projeyi de sayar (iş gerçekten
-- yapıldı); yalnızca iptal edilen proje hiç sayılmaz.
-- name: DashboardMyTaskCounts :one
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT
    (count(*) FILTER (WHERE t.status IN ('todo', 'in_progress')))::int AS open_count,
    (count(*) FILTER (WHERE t.status IN ('todo', 'in_progress') AND t.due_date < @today::date))::int AS overdue,
    (count(*) FILTER (WHERE t.status IN ('todo', 'in_progress') AND t.due_date = @today::date))::int AS due_today,
    (min(t.due_date) FILTER (WHERE t.status IN ('todo', 'in_progress') AND t.due_date < @today::date))::date AS overdue_oldest
FROM project_tasks t
JOIN ap ON ap.id = t.project_id AND ap.status NOT IN ('completed', 'cancelled')
WHERE t.organization_id = @org_id::uuid AND t.assigned_employee_id = @employee_id::uuid;

-- name: DashboardMyTasks :many
-- Bana atanmış açık görevler. mode:
--   'items'   -> ilk 5: gecikmişler önce, sonra vade (boş vadeler en son);
--   'overdue' -> vadesi geçenler, en eski önce;
--   'range'   -> vadesi due_from .. due_to arasında olanlar.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT t.id, t.project_id, t.title, ap.name AS project_name, t.due_date, t.priority, t.status
FROM project_tasks t
JOIN ap ON ap.id = t.project_id AND ap.status NOT IN ('completed', 'cancelled')
WHERE t.organization_id = @org_id::uuid AND t.assigned_employee_id = @employee_id::uuid
  AND t.status IN ('todo', 'in_progress')
  AND (@mode::text = 'items'
       OR (@mode::text = 'overdue' AND t.due_date < @today::date)
       OR (@mode::text = 'range' AND t.due_date BETWEEN @due_from::date AND @due_to::date))
ORDER BY (CASE WHEN t.due_date < @today::date THEN 0 ELSE 1 END), t.due_date ASC NULLS LAST, t.created_at ASC, t.id
LIMIT @row_limit::int;

-- name: DashboardTeamTaskCounts :one
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT
    (count(*) FILTER (WHERE t.status IN ('todo', 'in_progress') AND ap.status <> 'completed'))::int AS open_count,
    (count(*) FILTER (WHERE t.status IN ('todo', 'in_progress') AND ap.status <> 'completed' AND t.due_date < @today::date))::int AS overdue,
    (count(*) FILTER (WHERE t.status IN ('todo', 'in_progress') AND ap.status <> 'completed' AND t.due_date = @today::date))::int AS due_today,
    (count(*) FILTER (WHERE t.status IN ('todo', 'in_progress') AND ap.status <> 'completed' AND t.assigned_employee_id IS NULL))::int AS unassigned,
    (count(*) FILTER (WHERE t.status = 'completed' AND t.completed_at >= @d7_start_ts::timestamptz))::int AS completed_7d,
    (min(t.due_date) FILTER (WHERE t.status IN ('todo', 'in_progress') AND ap.status <> 'completed' AND t.due_date < @today::date))::date AS overdue_oldest,
    (min((t.created_at AT TIME ZONE 'Europe/Istanbul')::date)
        FILTER (WHERE t.status IN ('todo', 'in_progress') AND ap.status <> 'completed' AND t.assigned_employee_id IS NULL))::date AS unassigned_oldest
FROM project_tasks t
JOIN ap ON ap.id = t.project_id AND ap.status <> 'cancelled'
WHERE t.organization_id = @org_id::uuid;

-- name: DashboardTeamTasksTop :many
-- Ekip görevleri: mode 'overdue' (gecikmiş, en eski vade önce) ya da
-- 'unassigned' (atanmamış açık görevler, vade sırası).
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT t.id, t.project_id, t.title, ap.name AS project_name, t.due_date
FROM project_tasks t
JOIN ap ON ap.id = t.project_id AND ap.status NOT IN ('completed', 'cancelled')
WHERE t.organization_id = @org_id::uuid AND t.status IN ('todo', 'in_progress')
  AND ((@mode::text = 'overdue' AND t.due_date < @today::date)
       OR (@mode::text = 'unassigned' AND t.assigned_employee_id IS NULL))
ORDER BY t.due_date ASC NULLS LAST, t.created_at ASC, t.id
LIMIT 3;

-- ============================================================ operations

-- name: DashboardOperationsCounts :one
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT
    (SELECT count(DISTINCT m.employee_id) FROM project_members m
      JOIN ap ON ap.id = m.project_id AND ap.status = 'active'
      WHERE m.organization_id = @org_id::uuid
        AND (m.start_date IS NULL OR m.start_date <= @today::date)
        AND (m.end_date IS NULL OR m.end_date >= @today::date))::int AS active_crew,
    (SELECT count(*) FROM project_schedule_items si
      JOIN ap ON ap.id = si.project_id AND ap.status <> 'cancelled'
      WHERE si.organization_id = @org_id::uuid AND si.status IN ('planned', 'active')
        AND si.end_date BETWEEN @today::date AND @plus6::date)::int AS milestones_due_7d,
    (SELECT count(*) FROM project_schedule_items si
      JOIN ap ON ap.id = si.project_id AND ap.status <> 'cancelled'
      WHERE si.organization_id = @org_id::uuid AND si.status IN ('planned', 'active')
        AND si.end_date < @today::date)::int AS milestones_overdue,
    (SELECT min(si.end_date) FROM project_schedule_items si
      JOIN ap ON ap.id = si.project_id AND ap.status <> 'cancelled'
      WHERE si.organization_id = @org_id::uuid AND si.status IN ('planned', 'active')
        AND si.end_date < @today::date)::date AS milestones_overdue_oldest,
    (SELECT count(*) FROM project_photos ph
      JOIN ap ON ap.id = ph.project_id
      WHERE ph.organization_id = @org_id::uuid AND ph.deleted_at IS NULL
        AND ph.created_at >= @d7_start_ts::timestamptz)::int AS photos_7d;

-- name: DashboardMilestones :many
-- İş programı kalemleri (planned/active): mode 'overdue' (bitişi geçmiş)
-- ya da 'range' (bitişi due_from .. due_to arasında).
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT si.id, si.project_id, si.name, ap.name AS project_name, si.end_date
FROM project_schedule_items si
JOIN ap ON ap.id = si.project_id AND ap.status <> 'cancelled'
WHERE si.organization_id = @org_id::uuid AND si.status IN ('planned', 'active')
  AND ((@mode::text = 'overdue' AND si.end_date < @today::date)
       OR (@mode::text = 'range' AND si.end_date BETWEEN @due_from::date AND @due_to::date))
ORDER BY si.end_date ASC, si.sort_order ASC, si.id
LIMIT @row_limit::int;

-- ============================================================ attendance

-- name: DashboardAttendanceToday :one
-- Firma geneli (proje ekseni yok): aktif (arşivlenmemiş) personelin bugünkü
-- kayıtları; girilmedi = kaydı olmayan aktif personel. Ay toplamı, ayın
-- günlerindeki bütün kayıtların çalışma saati.
SELECT
    (count(*) FILTER (WHERE e.is_active))::int AS active_employees,
    (count(a.id) FILTER (WHERE e.is_active AND a.status = @status_present::text))::int AS present,
    (count(a.id) FILTER (WHERE e.is_active AND a.status = @status_half_day::text))::int AS half_day,
    (count(a.id) FILTER (WHERE e.is_active AND a.status = @status_absent::text))::int AS absent,
    (count(a.id) FILTER (WHERE e.is_active AND a.status = @status_on_leave::text))::int AS on_leave,
    (count(*) FILTER (WHERE e.is_active AND a.id IS NULL))::int AS not_recorded,
    (SELECT COALESCE(sum(l.work_hours), 0) FROM attendance_logs l
      WHERE l.organization_id = @org_id::uuid
        AND l.date >= @month_start::date AND l.date < @next_month_start::date)::numeric(12,2) AS month_work_hours
FROM employees e
LEFT JOIN attendance_logs a ON a.employee_id = e.id AND a.organization_id = e.organization_id
                           AND a.date = @today::date
WHERE e.organization_id = @org_id::uuid AND e.archived_at IS NULL;

-- ============================================================ registries (org)

-- name: DashboardEmployeeCounts :one
-- Maaş ve yevmiye ASLA seçilmez.
SELECT
    (count(*) FILTER (WHERE e.is_active))::int AS active,
    (count(*) FILTER (WHERE NOT e.is_active))::int AS inactive,
    (count(*) FILTER (WHERE e.user_id IS NOT NULL))::int AS with_user_account,
    (count(*) FILTER (WHERE e.start_date >= @month_start::date AND e.start_date < @next_month_start::date))::int AS new_this_month
FROM employees e
WHERE e.organization_id = @org_id::uuid AND e.archived_at IS NULL;

-- name: DashboardCustomerCounts :one
-- Müşteri sayıları firma geneli; "aktif projesi olan" ise üyelik kapsamlı.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT
    (SELECT count(*) FROM customers c
      WHERE c.organization_id = @org_id::uuid AND c.is_active)::int AS active,
    (SELECT count(*) FROM customers c
      WHERE c.organization_id = @org_id::uuid
        AND c.created_at >= @month_start_ts::timestamptz AND c.created_at < @next_month_start_ts::timestamptz)::int AS new_this_month,
    (SELECT count(DISTINCT ap.customer_id) FROM ap
      WHERE ap.status = 'active' AND ap.customer_id IS NOT NULL)::int AS with_active_projects;

-- name: DashboardProductCounts :one
-- Toplam, GET /products'ın (arama boşken) toplamıyla aynı; kaynak NULL =
-- elle eklenen. Kâr oranı / tedarikçi fiyatı ASLA seçilmez.
SELECT
    count(*)::int AS total,
    (count(*) FILTER (WHERE COALESCE(pr.source, 'manual') = 'manual'))::int AS manual,
    (count(*) FILTER (WHERE pr.source = 'ulas'))::int AS ulas,
    (count(*) FILTER (WHERE pr.source = 'demirprofil'))::int AS demirprofil
FROM products pr
WHERE pr.organization_id = @org_id::uuid;

-- name: DashboardPriceSources :many
SELECT s.source, s.last_synced_at, s.last_status, s.auto_sync
FROM organization_price_sources s
WHERE s.organization_id = @org_id::uuid
ORDER BY s.source;

-- name: DashboardCalcCounts :one
SELECT
    (SELECT count(*) FROM calc_groups g WHERE g.organization_id = @org_id::uuid AND g.is_active)::int AS groups,
    (SELECT count(*) FROM calc_categories c WHERE c.organization_id = @org_id::uuid AND c.is_active)::int AS categories;

-- name: DashboardCalcUsedInOffers :one
-- Son 30 günde oluşturulan aktif tekliflerin GÜNCEL revizyonlarında metraj
-- kategorisine bağlı kalem sayısı (offers.read ile).
SELECT count(*)::int AS used
FROM offer_revision_items i
JOIN offers o ON o.current_revision_id = i.revision_id
WHERE o.organization_id = @org_id::uuid AND o.is_passive = false
  AND o.created_at >= @d30_start_ts::timestamptz
  AND i.calc_category_id IS NOT NULL;

-- name: DashboardCalcRecipeUnlinked :one
SELECT count(*)::int AS unlinked
FROM calc_recipe_items ri
WHERE ri.organization_id = @org_id::uuid AND ri.is_active AND ri.product_id IS NULL;

-- name: DashboardSupplierCounts :one
SELECT
    (count(*) FILTER (WHERE s.is_active))::int AS active,
    (count(*) FILTER (WHERE NOT s.is_active))::int AS inactive
FROM suppliers s
WHERE s.organization_id = @org_id::uuid;

-- name: DashboardSuppliersOrderedThisMonth :one
-- Satın Alma kartının approved_this_month'u ile AYNI sipariş kümesi: iptal
-- dışı projeler, sonradan iptal edilmemiş siparişler (iptal approved_at'i
-- silmez) -- iki kart "bu ay verilen siparişler" için çelişmesin.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT count(DISTINCT po.supplier_id)::int AS suppliers
FROM purchase_orders po
JOIN ap ON ap.id = po.project_id AND ap.status <> 'cancelled'
WHERE po.organization_id = @org_id::uuid AND po.status <> 'cancelled'
  AND po.approved_at >= @month_start_ts::timestamptz AND po.approved_at < @next_month_start_ts::timestamptz;

-- name: DashboardCostCodeCounts :one
SELECT
    (count(*) FILTER (WHERE cc.is_active))::int AS active,
    (count(*) FILTER (WHERE NOT cc.is_active))::int AS inactive
FROM organization_cost_codes cc
WHERE cc.organization_id = @org_id::uuid;

-- name: DashboardExpensesWithoutCostCode :one
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT count(*)::int AS expenses
FROM project_expenses e
JOIN ap ON ap.id = e.project_id
WHERE e.organization_id = @org_id::uuid AND e.voided_at IS NULL AND e.cost_code_id IS NULL
  AND e.expense_date >= @month_start::date AND e.expense_date < @next_month_start::date;

-- ============================================================ users

-- name: DashboardUserCounts :one
-- Silinmiş (deleted_at) kullanıcılar sayılmaz. "Projesi olmayan":
-- üyelik kısıtlı bir rolde olup hiçbir project_users satırı olmayan aktif
-- kullanıcılar -- hiçbir projeyi göremezler.
SELECT
    (count(*) FILTER (WHERE u.is_active))::int AS active,
    (count(*) FILTER (WHERE NOT u.is_active))::int AS inactive,
    (count(*) FILTER (WHERE u.is_active AND u.last_login_at IS NULL))::int AS never_logged_in,
    (count(*) FILTER (WHERE u.is_active AND r.code NOT IN ('owner', 'admin', 'legacy_user')
                        AND NOT EXISTS (SELECT 1 FROM project_users pu
                                        WHERE pu.user_id = u.id AND pu.organization_id = @org_id::uuid)))::int
        AS restricted_without_project,
    (count(*) FILTER (WHERE u.is_active AND NOT EXISTS (
                        SELECT 1 FROM employees e
                        WHERE e.user_id = u.id AND e.organization_id = @org_id::uuid)))::int AS without_employee_link
FROM users u
LEFT JOIN organization_roles r ON r.id = u.organization_role_id
WHERE u.organization_id = @org_id::uuid AND u.deleted_at IS NULL;

-- name: DashboardUsersByRole :many
SELECT r.code, r.name, count(*)::int AS cnt
FROM users u
JOIN organization_roles r ON r.id = u.organization_role_id
WHERE u.organization_id = @org_id::uuid AND u.deleted_at IS NULL AND u.is_active
GROUP BY r.code, r.name
ORDER BY (CASE r.code WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 WHEN 'project_manager' THEN 2
                      WHEN 'finance' THEN 3 WHEN 'field' THEN 4 WHEN 'legacy_user' THEN 5 ELSE 6 END),
         r.name;

-- name: DashboardUsersWithOverrides :one
SELECT count(DISTINCT o.user_id)::int AS users
FROM user_permission_overrides o
JOIN users u ON u.id = o.user_id
WHERE o.organization_id = @org_id::uuid AND u.organization_id = @org_id::uuid
  AND u.deleted_at IS NULL AND u.is_active;

-- name: DashboardUsersWithoutProjectTop :many
SELECT u.id, u.full_name, r.name AS role_name
FROM users u
JOIN organization_roles r ON r.id = u.organization_role_id
WHERE u.organization_id = @org_id::uuid AND u.deleted_at IS NULL AND u.is_active
  AND r.code NOT IN ('owner', 'admin', 'legacy_user')
  AND NOT EXISTS (SELECT 1 FROM project_users pu
                  WHERE pu.user_id = u.id AND pu.organization_id = @org_id::uuid)
ORDER BY u.full_name ASC, u.id
LIMIT 3;

-- ============================================================ activity

-- name: DashboardProjectActivity :many
-- Yalnızca izin haritasından geçen olay tipleri (fail-closed), üyelik
-- kapsamlı. metadata (tutarlar) ASLA seçilmez.
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT ev.id, ev.event_type, ev.project_id, ap.project_no, ap.name AS project_name,
       COALESCE(u.full_name, '')::text AS user_name, ev.created_at
FROM project_events ev
JOIN ap ON ap.id = ev.project_id
LEFT JOIN users u ON u.id = ev.user_id
WHERE ev.organization_id = @org_id::uuid
  AND ev.event_type = ANY (@allowed_types::text[])
ORDER BY ev.created_at DESC, ev.id
LIMIT 10;

-- name: DashboardOfferActivity :many
-- Teklif olayları, customer_viewed HARİÇ (görüntülenmeler aşağıda teklif
-- başına tekilleştirilir). "event_type <> 'customer_viewed'" koşulu kısmi
-- indeksin (idx_offer_events_org_created_no_views, 0047) kullanılabilmesi
-- için sorguda AYNEN yazılıdır: tarama created_at sırasıyla ilk 10 satırda
-- durur ve görüntülenme satırlarının üzerinden hiç geçmez.
SELECT e.id, e.event_type, e.offer_id, o.offer_no,
       COALESCE(u.full_name, '')::text AS user_name, e.created_at
FROM offer_events e
JOIN offers o ON o.id = e.offer_id AND o.organization_id = @org_id::uuid
LEFT JOIN users u ON u.id = e.user_id
WHERE e.organization_id = @org_id::uuid AND o.is_passive = false
  AND e.event_type <> 'customer_viewed'
  AND e.event_type = ANY (@allowed_types::text[])
ORDER BY e.created_at DESC, e.id
LIMIT 10;

-- name: DashboardOfferLatestViews :many
-- Müşteri görüntülemeleri teklif BAŞINA tekilleştirilir: her paylaşım
-- linki açılışı (sayfa yenileme, bağlantı önizleme botları) ayrı bir
-- customer_viewed yazar; Son hareketler'de bir teklif yalnızca EN SON
-- görüntülenmesiyle yer alır, tekrarlar diğer olayları listeden itmez.
-- Teklif başına tek indeks araması (idx_offer_events_offer_id) --
-- maliyet görüntülenme sayısından bağımsızdır.
SELECT v.id, v.offer_id, o.offer_no, v.created_at
FROM offers o
CROSS JOIN LATERAL (
    SELECT e.id, e.offer_id, e.created_at
    FROM offer_events e
    WHERE e.offer_id = o.id AND e.organization_id = @org_id::uuid
      AND e.event_type = 'customer_viewed'
    ORDER BY e.created_at DESC, e.id
    LIMIT 1
) v
WHERE o.organization_id = @org_id::uuid AND o.is_passive = false
ORDER BY v.created_at DESC, v.id
LIMIT 10;

-- ============================================================ project options

-- name: DashboardProjectOptions :many
-- Hızlı işlem proje seçicisi: açık projeler, üyelik kapsamlı, para alanı
-- YOK (GET /projects tutar sızdırdığı için kullanılmaz).
WITH ap AS (
    SELECT p.* FROM projects p
    WHERE p.organization_id = @org_id::uuid
      AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu
           WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)
SELECT ap.id, ap.project_no, ap.name, ap.customer_name, ap.currency, ap.status
FROM ap
WHERE ap.status IN ('planned', 'active', 'paused')
  AND (@search::text = ''
       OR ap.name ILIKE '%' || @search::text || '%'
       OR ap.project_no ILIKE '%' || @search::text || '%')
ORDER BY ap.name ASC, ap.id
LIMIT 50;
