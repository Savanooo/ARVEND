-- Satın almalar proje maliyetine girer (2026-10; bkz. docs/maliyet-tanimlari.md
-- "Satın almalar", docs/procurement.md §13).
--
-- Ürün sahibi: "Satın almalar maliyet eklemiyor" -- satın alma talebi
-- ONAYLANINCA maliyete girsin; onaylarken "proje maliyetine eklensin mi?"
-- diye sorulsun (depo/stok ya da genel kullanım için "Hayır"). Önceden
-- maliyet yalnızca siparişe bağlanan onaylı faturadan (masraf) geliyordu;
-- onaylı talep ve onaylı sipariş kâra hiç yansımıyordu.
--
-- Satın almanın maliyete katkısı (yalnızca include_in_project_cost = true):
--   onaylı talep, sayılan siparişi yok  -> talebin tahmini tutarı
--                                          (onayda girilen cost_estimate, yoksa kalemlerin toplamı)
--   talebin onaylı/kapatılmış siparişi  -> siparişler talebin YERİNE geçer (ikisi birden asla)
--   sipariş                              -> max(sipariş tutarı, siparişe bağlı onaylı faturalar)
--   kısa kapatılmış sipariş              -> sipariş tutarı yerine teslim alınan (kabul) değer
--   siparişe bağlı onaylı faturalar     -> ayrıca masraf olarak SAYILMAZ (satın almanın içindedir)
-- include_in_project_cost = false olan satın alma ve faturaları maliyete hiç
-- girmez; kaybolmasın diye purchase_excluded'da ayrıca görünür.
--
-- Tutarlar masraflarla aynı esasta KDV DAHİLDİR: sipariş toplamı (total) ve
-- içindeki KDV (tax) bilinir; talep tahmininin KDV'si bilinmez (KDV oranı
-- girilmemiş masraf gibi tamamı maliyettir, KDV hariç karşılığı da aynıdır).
--
-- Mevcut kayıtlar: ürün sahibi kararıyla mevcut onaylı talep ve siparişler
-- "maliyete eklensin" (true) sayılır -- projelerin kârı onaylı satın almaları
-- kadar düşer.

ALTER TABLE purchase_requests
    ADD COLUMN include_in_project_cost boolean NOT NULL DEFAULT true,
    -- Onaylayanın girdiği tahmini tutar: kalemlerde fiyat yokken ya da eksikken
    -- maliyete bu girer. NULL = kalemlerin toplamı (estimated_total).
    ADD COLUMN cost_estimate numeric(18, 2) CHECK (cost_estimate >= 0);

ALTER TABLE purchase_orders
    -- Siparişin talebi: talepten açılan sipariş talebin YERİNE maliyete girer.
    -- Talepten bağımsız sipariş (NULL) kendi kuralıyla girer.
    ADD COLUMN purchase_request_id uuid REFERENCES purchase_requests(id) ON DELETE SET NULL,
    -- Talepten açılan sipariş talebin kararını devralır, sonradan değiştirilebilir.
    ADD COLUMN include_in_project_cost boolean NOT NULL DEFAULT true;

CREATE INDEX idx_purchase_orders_purchase_request ON purchase_orders (purchase_request_id)
    WHERE purchase_request_id IS NOT NULL;

-- Mevcut siparişlerin talebi kaynak RFQ'dan (PR -> RFQ -> teklif -> sipariş
-- zinciri). updated_at bu teknik eşlemeyle değişmesin.
ALTER TABLE purchase_orders DISABLE TRIGGER purchase_orders_set_updated_at;
UPDATE purchase_orders po
SET purchase_request_id = r.purchase_request_id
FROM rfqs r
WHERE r.id = po.source_rfq_id AND r.purchase_request_id IS NOT NULL
  AND r.project_id = po.project_id;
ALTER TABLE purchase_orders ENABLE TRIGGER purchase_orders_set_updated_at;

-- Sipariş KALEMİ başına maliyet tabanı (KDV hariç net + KDV payı). Maliyet
-- Kontrolü satırları bunu maliyet koduna/bütçe kalemine dağıtır.
--   kısa kapatılmış (kapatılmış ve iptal edilmemiş teslimi olan) sipariş:
--     net = round(kabul edilen miktar x birim fiyat, 2) -- kapanışta taahhüdün
--     indiği tutar (releaseUnreceivedCommitments) ve sipariş listesindeki kabul
--     değeriyle aynı yuvarlama
--   diğerleri: net = kalem tutarı (line_total)
-- KDV kalem başına yuvarlanır; yuvarlama farkı ilk kaleme yazılır ki kalemlerin
-- KDV toplamı siparişin KDV'sine (tax ya da kabul edilen değerin KDV'si) birebir
-- eşit olsun -- kalemlerin toplamı = siparişin tutarı.
CREATE VIEW purchase_order_item_cost AS
WITH acc AS (
    SELECT ri.purchase_order_item_id, sum(ri.accepted_quantity) AS accepted
    FROM purchase_receipt_items ri
    JOIN purchase_receipts r ON r.id = ri.receipt_id
    WHERE r.voided_at IS NULL
    GROUP BY ri.purchase_order_item_id
),
rcv AS (
    SELECT DISTINCT purchase_order_id FROM purchase_receipts WHERE voided_at IS NULL
),
it AS (
    SELECT poi.id AS purchase_order_item_id, poi.purchase_order_id, poi.organization_id, poi.project_id,
           poi.cost_code_id, poi.budget_line_id, poi.sort_order, po.tax_rate, po.tax,
           (po.status = 'closed' AND rcv.purchase_order_id IS NOT NULL) AS short_closed,
           CASE WHEN po.status = 'closed' AND rcv.purchase_order_id IS NOT NULL
                THEN round(COALESCE(acc.accepted, 0) * poi.unit_price, 2)
                ELSE poi.line_total END AS net
    FROM purchase_order_items poi
    JOIN purchase_orders po ON po.id = poi.purchase_order_id
    LEFT JOIN acc ON acc.purchase_order_item_id = poi.id
    LEFT JOIN rcv ON rcv.purchase_order_id = po.id
),
v AS (
    SELECT it.*,
           round(it.net * it.tax_rate / 100, 2) AS raw_vat,
           sum(round(it.net * it.tax_rate / 100, 2)) OVER w AS raw_vat_sum,
           sum(it.net) OVER w AS order_net,
           row_number() OVER (PARTITION BY it.project_id, it.purchase_order_id
                              ORDER BY it.sort_order, it.purchase_order_item_id) AS rn
    FROM it
    WINDOW w AS (PARTITION BY it.project_id, it.purchase_order_id)
)
SELECT purchase_order_item_id, purchase_order_id, organization_id, project_id, cost_code_id, budget_line_id,
       short_closed,
       net::numeric(18,2) AS net,
       (raw_vat + CASE WHEN rn = 1
                       THEN (CASE WHEN short_closed THEN round(order_net * tax_rate / 100, 2) ELSE tax END) - raw_vat_sum
                       ELSE 0 END)::numeric(18,2) AS vat
FROM v;

-- Sipariş başına satın alma maliyeti. counted: onaylı ya da kapatılmış ve proje
-- para biriminde (sipariş hep projenin para birimiyle açılır; döviz çevirisi
-- uydurulmaz). cost_* "maliyete eklenseydi" tutarıdır; maliyete girip girmediği
-- include_in_project_cost'tadır. invoice_led: bağlı onaylı faturalar sipariş
-- tutarını AŞTI -- satın alma artık faturaların kendisidir (fiyat artışı
-- maliyeti yükseltir; kısmi fatura sipariş tutarının altına düşürmez).
CREATE VIEW purchase_order_cost_basis AS
WITH base AS (
    SELECT purchase_order_id, sum(net) AS net, sum(vat) AS vat
    FROM purchase_order_item_cost
    GROUP BY purchase_order_id
),
inv AS (
    SELECT e.purchase_order_id, sum(e.amount) AS amount, COALESCE(sum(e.vat_amount), 0) AS vat
    FROM project_expenses e
    JOIN purchase_orders po ON po.id = e.purchase_order_id AND po.project_id = e.project_id
    WHERE e.voided_at IS NULL AND e.approval_status = 'approved'
    GROUP BY e.purchase_order_id
),
each AS (
    SELECT po.id, po.organization_id, po.project_id, po.purchase_request_id, po.status,
           po.include_in_project_cost,
           (po.status IN ('approved', 'closed') AND po.currency = p.currency) AS counted,
           COALESCE(b.net, 0) + COALESCE(b.vat, 0) AS order_amount,
           COALESCE(b.vat, 0) AS order_vat,
           COALESCE(i.amount, 0) AS invoiced_amount,
           COALESCE(i.vat, 0) AS invoiced_vat
    FROM purchase_orders po
    JOIN projects p ON p.id = po.project_id
    LEFT JOIN base b ON b.purchase_order_id = po.id
    LEFT JOIN inv i ON i.purchase_order_id = po.id
)
SELECT id AS purchase_order_id, organization_id, project_id, purchase_request_id, status,
       include_in_project_cost, counted,
       order_amount::numeric(18,2) AS order_amount,
       order_vat::numeric(18,2) AS order_vat,
       invoiced_amount::numeric(18,2) AS invoiced_amount,
       invoiced_vat::numeric(18,2) AS invoiced_vat,
       (invoiced_amount > order_amount) AS invoice_led,
       GREATEST(order_amount, invoiced_amount)::numeric(18,2) AS cost_amount,
       (CASE WHEN invoiced_amount > order_amount THEN invoiced_vat ELSE order_vat END)::numeric(18,2) AS cost_vat
FROM each;

-- Talep başına satın alma maliyeti. has_order: talebin sayılan (onaylı ya da
-- kapatılmış) siparişi var -- o zaman talebin tahmini düşer, siparişler
-- (kendi kararlarıyla) sayılır; siparişlerin hepsi iptal edilirse talep
-- onaylı kaldıkça tahmine geri dönülür. estimate_amount "maliyete
-- eklenseydi" tutarıdır (yalnızca onaylı ve siparişsiz talepte);
-- project_cost talebin bugün maliyete giren toplamıdır (tahmin ya da
-- siparişleri) -- talep ekranındaki "Maliyete eklendi: X".
CREATE VIEW purchase_request_cost_basis AS
WITH ord AS (
    SELECT purchase_request_id,
           bool_or(counted) AS has_order,
           COALESCE(sum(cost_amount) FILTER (WHERE counted), 0) AS orders_amount,
           COALESCE(sum(cost_amount) FILTER (WHERE counted AND include_in_project_cost), 0) AS orders_cost
    FROM purchase_order_cost_basis
    WHERE purchase_request_id IS NOT NULL
    GROUP BY purchase_request_id
),
priced AS (
    SELECT purchase_request_id,
           count(*) FILTER (WHERE estimated_unit_cost IS NULL AND estimated_total = 0) AS unpriced_items
    FROM purchase_request_items
    GROUP BY purchase_request_id
),
each AS (
    SELECT pr.id, pr.organization_id, pr.project_id, pr.status, pr.include_in_project_cost, pr.cost_estimate,
           COALESCE(pr.cost_estimate, pr.estimated_total) AS estimate,
           COALESCE(o.has_order, false) AS has_order,
           COALESCE(o.orders_amount, 0) AS orders_amount,
           COALESCE(o.orders_cost, 0) AS orders_cost,
           COALESCE(pc.unpriced_items, 0) AS unpriced_items
    FROM purchase_requests pr
    LEFT JOIN ord o ON o.purchase_request_id = pr.id
    LEFT JOIN priced pc ON pc.purchase_request_id = pr.id
)
SELECT id AS purchase_request_id, organization_id, project_id, status, include_in_project_cost,
       estimate::numeric(18,2) AS estimate,
       has_order,
       orders_amount::numeric(18,2) AS orders_amount,
       unpriced_items::int AS unpriced_items,
       (CASE WHEN status = 'approved' AND NOT has_order THEN estimate ELSE 0 END)::numeric(18,2) AS estimate_amount,
       ((CASE WHEN status = 'approved' AND NOT has_order AND include_in_project_cost THEN estimate ELSE 0 END)
        + orders_cost)::numeric(18,2) AS project_cost
FROM each;

-- Proje maliyetine giren HER satır (masraf ya da satın alma), maliyet
-- koduyla/bütçe kalemiyle. Finans özeti, proje listesi ve Ana Sayfa toplamı
-- (project_cost_basis), Maliyet Kontrolü satır satır bunu okur: aynı
-- harcama iki yerde iki kez sayılamaz.
--   expense          onaylı, iptal edilmemiş masraf; sayılan bir siparişe
--                    bağlı olan HARİÇ (satın almanın içinde ya da maliyet dışı)
--   purchase_invoice faturaları sipariş tutarını aşan siparişin faturaları
--   purchase_order   sipariş kalemleri (faturalar sipariş tutarını aşmadıkça)
--   purchase_request onaylı, siparişi olmayan talebin kalemleri; onayda
--                    tahmini tutar girildiyse tek satır -- kalemlerin hepsi
--                    aynı maliyet koduna/bütçe kalemine bağlıysa oraya, değilse
--                    kodsuz (Maliyet Kontrolü'nde görünmez, finans özetinde
--                    sayılır)
CREATE VIEW project_cost_lines AS
SELECT e.organization_id, e.project_id, 'expense'::varchar(20) AS source, e.id AS source_id,
       e.purchase_order_id, NULL::uuid AS purchase_request_id,
       e.cost_code_id, e.budget_line_id, e.amount, e.vat_amount AS vat
FROM project_expenses e
LEFT JOIN purchase_order_cost_basis po
       ON po.purchase_order_id = e.purchase_order_id AND po.project_id = e.project_id AND po.counted
WHERE e.voided_at IS NULL AND e.approval_status = 'approved' AND e.project_id IS NOT NULL
  AND po.purchase_order_id IS NULL
UNION ALL
SELECT e.organization_id, e.project_id, 'purchase_invoice'::varchar(20), e.id,
       e.purchase_order_id, po.purchase_request_id,
       e.cost_code_id, e.budget_line_id, e.amount, e.vat_amount
FROM project_expenses e
JOIN purchase_order_cost_basis po
  ON po.purchase_order_id = e.purchase_order_id AND po.project_id = e.project_id
 AND po.counted AND po.include_in_project_cost AND po.invoice_led
WHERE e.voided_at IS NULL AND e.approval_status = 'approved'
UNION ALL
SELECT i.organization_id, i.project_id, 'purchase_order'::varchar(20), i.purchase_order_item_id,
       i.purchase_order_id, po.purchase_request_id,
       i.cost_code_id, i.budget_line_id, (i.net + i.vat)::numeric(18,2), i.vat
FROM purchase_order_item_cost i
JOIN purchase_order_cost_basis po ON po.purchase_order_id = i.purchase_order_id
WHERE po.counted AND po.include_in_project_cost AND NOT po.invoice_led
UNION ALL
SELECT it.organization_id, it.project_id, 'purchase_request'::varchar(20), it.id,
       NULL::uuid, it.purchase_request_id,
       it.cost_code_id, it.budget_line_id, it.estimated_total, 0::numeric(18,2)
FROM purchase_request_items it
JOIN purchase_requests pr ON pr.id = it.purchase_request_id
JOIN purchase_request_cost_basis b ON b.purchase_request_id = pr.id
WHERE pr.include_in_project_cost AND b.estimate_amount > 0 AND pr.cost_estimate IS NULL
  AND it.estimated_total > 0
UNION ALL
SELECT pr.organization_id, pr.project_id, 'purchase_request'::varchar(20), pr.id,
       NULL::uuid, pr.id,
       cd.cost_code_id, cd.budget_line_id, pr.cost_estimate, 0::numeric(18,2)
FROM purchase_requests pr
JOIN purchase_request_cost_basis b ON b.purchase_request_id = pr.id
LEFT JOIN (
    SELECT purchase_request_id,
           CASE WHEN count(*) = count(cost_code_id) AND count(DISTINCT cost_code_id) = 1
                THEN (array_agg(cost_code_id))[1] END AS cost_code_id,
           CASE WHEN count(*) = count(budget_line_id) AND count(DISTINCT budget_line_id) = 1
                THEN (array_agg(budget_line_id))[1] END AS budget_line_id
    FROM purchase_request_items
    GROUP BY purchase_request_id
) cd ON cd.purchase_request_id = pr.id
WHERE pr.include_in_project_cost AND b.estimate_amount > 0 AND pr.cost_estimate IS NOT NULL;

-- Proje başına maliyet tabanı (0074'ün devamı; mevcut kolonlar aynı sırada
-- kalır, yeniler sona eklenir).
--   expense_approved(_vat) bütün onaylı masraflar -- nakit ("ödenen") için
--   expense_cost(_vat)     masraf satırı: satın almaya ait olmayan onaylı masraflar
--   purchase_cost(_vat)    "Satın almalar (onaylı)"
--   purchase_cost_uncoded  maliyet koduna bağlı olmayan satın alma (Maliyet
--                          Kontrolü'nün göremediği; bütçe bazlı tahmine ayrıca eklenir)
--   purchase_excluded      "maliyete eklenmesin" denmiş satın almalar (bilgi)
--   realized_cost          masraf + satın alma + basit taşeron işi + sözleşmeli taşeron işi
--   realized_cost_vat      gerçekleşen maliyetin içindeki bilinen KDV (KDV hariç maliyet bundan)
--   received_not_costed    maliyete eklenen siparişlerde teslim alınmış ama
--                          faturası girilmemiş tutar (maliyetin İÇİNDEDİR, bilgi)
CREATE OR REPLACE VIEW project_cost_basis AS
WITH exp AS (
    SELECT e.project_id,
           sum(e.amount) FILTER (WHERE e.approval_status = 'approved') AS approved,
           sum(e.vat_amount) FILTER (WHERE e.approval_status = 'approved') AS approved_vat,
           sum(e.amount) FILTER (WHERE e.approval_status = 'pending') AS pending
    FROM project_expenses e
    WHERE e.voided_at IS NULL AND e.project_id IS NOT NULL
    GROUP BY e.project_id
),
simple AS (
    SELECT sp.project_id,
           sum(sp.amount) FILTER (WHERE sp.payment_kind = 'work') AS work_paid,
           sum(sp.amount) FILTER (WHERE sp.payment_kind = 'advance') AS advance_open,
           sum(sp.amount) AS paid
    FROM project_subcontractor_payments sp
    WHERE sp.voided_at IS NULL
    GROUP BY sp.project_id
),
sc AS (
    SELECT project_id,
           sum(accrued) AS accrued, sum(paid) AS paid, sum(advance_open) AS advance_open,
           sum(payable) AS payable, sum(retention) AS retention, sum(pending_claims) AS pending
    FROM subcontract_cost_basis
    GROUP BY project_id
),
lines AS (
    SELECT project_id,
           sum(amount) FILTER (WHERE source = 'expense') AS expense_cost,
           sum(vat) FILTER (WHERE source = 'expense') AS expense_cost_vat,
           sum(amount) FILTER (WHERE source <> 'expense') AS purchase_cost,
           sum(vat) FILTER (WHERE source <> 'expense') AS purchase_cost_vat,
           sum(amount) FILTER (WHERE source <> 'expense' AND cost_code_id IS NULL) AS purchase_cost_uncoded
    FROM project_cost_lines
    GROUP BY project_id
),
excluded AS (
    SELECT x.project_id, sum(x.amount) AS amount
    FROM (
        SELECT project_id, cost_amount AS amount FROM purchase_order_cost_basis
        WHERE counted AND NOT include_in_project_cost
        UNION ALL
        SELECT project_id, estimate_amount FROM purchase_request_cost_basis
        WHERE NOT include_in_project_cost
    ) x
    GROUP BY x.project_id
),
-- Teslim alınan (kabul edilen) malın KDV dahil değeri - siparişe bağlı onaylı
-- faturalar, sipariş başına ve sıfırın altına inmeden. Kabul değeri sipariş
-- listesindeki (ListPurchaseOrderReceiptSummaries) ile aynı yuvarlamadır.
po_accepted AS (
    SELECT poi.purchase_order_id,
           sum(round(a.accepted * poi.unit_price, 2)) AS net
    FROM purchase_order_items poi
    JOIN (
        SELECT ri.purchase_order_item_id, sum(ri.accepted_quantity) AS accepted
        FROM purchase_receipt_items ri
        JOIN purchase_receipts r ON r.id = ri.receipt_id
        WHERE r.voided_at IS NULL
        GROUP BY ri.purchase_order_item_id
    ) a ON a.purchase_order_item_id = poi.id
    GROUP BY poi.purchase_order_id
),
po AS (
    SELECT b.project_id,
           sum(GREATEST(a.net + round(a.net * o.tax_rate / 100, 2) - b.invoiced_amount, 0)) AS received_not_costed
    FROM purchase_order_cost_basis b
    JOIN purchase_orders o ON o.id = b.purchase_order_id
    JOIN po_accepted a ON a.purchase_order_id = b.purchase_order_id
    WHERE b.counted AND b.include_in_project_cost
    GROUP BY b.project_id
)
SELECT p.id AS project_id,
       p.organization_id,
       COALESCE(exp.approved, 0)::numeric(18,2) AS expense_approved,
       COALESCE(exp.approved_vat, 0)::numeric(18,2) AS expense_approved_vat,
       COALESCE(exp.pending, 0)::numeric(18,2) AS expense_pending,
       COALESCE(simple.work_paid, 0)::numeric(18,2) AS simple_work_paid,
       COALESCE(simple.advance_open, 0)::numeric(18,2) AS simple_advance_open,
       COALESCE(simple.paid, 0)::numeric(18,2) AS simple_paid,
       COALESCE(sc.accrued, 0)::numeric(18,2) AS subcontract_accrued,
       COALESCE(sc.paid, 0)::numeric(18,2) AS subcontract_paid,
       COALESCE(sc.advance_open, 0)::numeric(18,2) AS subcontract_advance_open,
       COALESCE(sc.payable, 0)::numeric(18,2) AS subcontract_payable,
       COALESCE(sc.retention, 0)::numeric(18,2) AS subcontract_retention,
       COALESCE(sc.pending, 0)::numeric(18,2) AS subcontract_pending_claims,
       (COALESCE(lines.expense_cost, 0) + COALESCE(lines.purchase_cost, 0)
        + COALESCE(simple.work_paid, 0) + COALESCE(sc.accrued, 0))::numeric(18,2)
           AS realized_cost,
       (COALESCE(exp.approved, 0) + COALESCE(simple.paid, 0) + COALESCE(sc.paid, 0))::numeric(18,2)
           AS paid_cost,
       (COALESCE(simple.advance_open, 0) + COALESCE(sc.advance_open, 0))::numeric(18,2) AS advance_open,
       (COALESCE(exp.pending, 0) + COALESCE(sc.pending, 0))::numeric(18,2) AS pending_cost,
       COALESCE(po.received_not_costed, 0)::numeric(18,2) AS received_not_costed,
       COALESCE(lines.expense_cost, 0)::numeric(18,2) AS expense_cost,
       COALESCE(lines.expense_cost_vat, 0)::numeric(18,2) AS expense_cost_vat,
       COALESCE(lines.purchase_cost, 0)::numeric(18,2) AS purchase_cost,
       COALESCE(lines.purchase_cost_vat, 0)::numeric(18,2) AS purchase_cost_vat,
       COALESCE(lines.purchase_cost_uncoded, 0)::numeric(18,2) AS purchase_cost_uncoded,
       COALESCE(excluded.amount, 0)::numeric(18,2) AS purchase_excluded,
       (COALESCE(lines.expense_cost_vat, 0) + COALESCE(lines.purchase_cost_vat, 0))::numeric(18,2)
           AS realized_cost_vat
FROM projects p
LEFT JOIN exp ON exp.project_id = p.id
LEFT JOIN simple ON simple.project_id = p.id
LEFT JOIN sc ON sc.project_id = p.id
LEFT JOIN lines ON lines.project_id = p.id
LEFT JOIN excluded ON excluded.project_id = p.id
LEFT JOIN po ON po.project_id = p.id;
