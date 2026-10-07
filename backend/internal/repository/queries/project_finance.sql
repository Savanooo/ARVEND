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

-- name: CreateInvoiceCollection :one
-- Satış faturası "ödendi" yapılınca oluşturulan, faturaya BAĞLI tahsilat
-- (bkz. migration 0050). Fatura başına tek geçerli bağlı tahsilatı kısmi
-- UNIQUE indeks zorlar.
INSERT INTO project_collections (
    organization_id, project_id, amount, currency, received_date,
    payment_method, description, reference_no, created_by, invoice_id
) VALUES (
    sqlc.arg(organization_id), sqlc.arg(project_id), sqlc.arg(amount), sqlc.arg(currency), sqlc.arg(received_date),
    '', sqlc.arg(description), sqlc.arg(reference_no), sqlc.narg(created_by), sqlc.arg(invoice_id)
)
RETURNING *;

-- name: GetActiveInvoiceCollection :one
SELECT * FROM project_collections
WHERE invoice_id = $1 AND organization_id = $2 AND voided_at IS NULL;

-- name: VoidInvoiceCollections :many
-- Fatura "ödendi"den çıkınca bağlı tahsilat(lar) iptal edilir (silinmez,
-- VoidCollection ile aynı iz).
UPDATE project_collections
SET voided_at = now(), voided_by = sqlc.narg(voided_by), void_reason = sqlc.arg(void_reason)
WHERE invoice_id = sqlc.arg(invoice_id) AND organization_id = sqlc.arg(organization_id) AND voided_at IS NULL
RETURNING id, amount;

-- ============ Masraflar ============

-- name: CreateExpense :one
-- change_order_id OPSİYONELDİR: bir masrafı bir ek işe etiketler. Bu
-- SADECE proje toplamının filtrelenmiş bir görünümü içindir (bkz.
-- project_change_orders.sql ListChangeOrders notu) -- masraf, NULL
-- olsun ya da olmasın, proje toplamına yalnızca BİR KEZ girer.
-- cost_code_id/budget_line_id de OPSİYONELDİR (Cost Control sprint'i,
-- migration 0035) -- ikisi de NULL bırakılabilir (bkz. o migration'ın
-- geriye dönük uyumluluk notu); servis katmanı budget_line_id verilmişse
-- cost_code_id'yi o kalemden DOĞRULAR/TÜRETİR (bkz. ExpenseService notu).
-- approval_status (migration 0060): kim girerse girsin masraf 'pending'
-- başlar; tek istisna geçmiş veriyi aktaran araç (bkz.
-- ExpenseInput.PreApproved). vat_rate (migration 0065) NULL olabilir
-- ("belirtilmedi"); vat_amount ondan üretilir.
INSERT INTO project_expenses (
    organization_id, project_id, category, description, amount, currency,
    expense_date, supplier_name, invoice_no, notes, idempotency_key, created_by, change_order_id,
    cost_code_id, budget_line_id, approval_status, vat_rate
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17)
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

-- name: ListMyExpenses :many
-- "Masraflarım" (GET /expenses/mine, migration 0066): kişinin KENDİ girdiği
-- masraflar, projeler arası, en yeni giriş önce. Finans okuma izni olmayan
-- (sahadaki) kişi başkasının masrafını ve hiçbir toplamı görmez -- tek
-- süzgeç created_by'dır, satırlar istemciye para toplamı olarak dönmez.
-- restrict_to_user_id: ListMyTasks ile AYNI proje erişimi kuralı (NULL =
-- owner/admin/legacy_user, tüm projeler) -- üyelikten çıkarılan kişi o
-- projedeki masraflarını da artık görmez, tıpkı proje ekranı gibi.
-- project_id opsiyonel: proje ekranındaki "Masraflarım" süzgeci. İptal
-- edilen (geri çekilen) masraflar da döner: kişi neyin iptal edildiğini
-- görebilmeli.
SELECT e.*, p.name AS project_name, p.project_no, p.status AS project_status
FROM project_expenses e
INNER JOIN projects p ON p.id = e.project_id AND p.organization_id = e.organization_id
WHERE e.organization_id = sqlc.arg(organization_id)::uuid
  AND e.created_by = sqlc.arg(created_by)::uuid
  AND (sqlc.narg(project_id)::uuid IS NULL OR e.project_id = sqlc.narg(project_id)::uuid)
  AND (
    sqlc.narg(restrict_to_user_id)::uuid IS NULL
    OR EXISTS (
      SELECT 1 FROM project_users pu
      WHERE pu.project_id = e.project_id
        AND pu.user_id = sqlc.narg(restrict_to_user_id)::uuid
    )
  )
ORDER BY e.created_at DESC, e.id DESC
LIMIT sqlc.arg(row_limit)::int;

-- name: UpdateExpense :one
-- project_id EKLENDİ (bkz. GetPaymentPlanItem notu). cost_code_id/
-- budget_line_id, Cost Control sprint'i (migration 0035) -- opsiyonel.
-- Düzenlenen masraf YENİDEN onay bekler (migration 0060): onaylanmış bir
-- tutar onaysız değiştirilip toplamlarda kalamaz. Önceki karar temizlenir
-- (izi project_events'te).
-- PUT satırı BÜTÜNÜYLE yeniden yazar: vat_rate (migration 0065) NULL
-- gelirse "belirtilmedi" olur, change_order_id boş gelirse bağ kalkar --
-- istemci değiştirmediği alanları aynen geri gönderir.
UPDATE project_expenses
SET category = $3, description = $4, amount = $5, expense_date = $6,
    supplier_name = $7, invoice_no = $8, notes = $9, cost_code_id = $11, budget_line_id = $12,
    vat_rate = $13, change_order_id = $14,
    approval_status = 'pending', decided_by = NULL, decided_at = NULL, decision_note = ''
WHERE id = $1 AND organization_id = $2 AND voided_at IS NULL AND project_id = $10
RETURNING *;

-- name: DecideExpense :one
-- Onay/ret: yalnızca iptal edilmemiş ve ONAY BEKLEYEN masraf -- eşzamanlı
-- iki karardan yalnızca biri satır döndürür (ApproveBudgetAdjustment ile
-- aynı ilke). Satır dönmezse servis nedenini GetExpense ile ayırır.
UPDATE project_expenses
SET approval_status = sqlc.arg(approval_status), decided_by = sqlc.narg(decided_by),
    decided_at = now(), decision_note = sqlc.arg(decision_note)
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id) AND project_id = sqlc.arg(project_id)
  AND voided_at IS NULL AND approval_status = 'pending'
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
-- change_order_id OPSİYONELDİR (bkz. CreateExpense notu). cost_code_id
-- de OPSİYONELDİR (Cost Control sprint'i, migration 0035) -- taşeron
-- sözleşmesi bir cost code'a etiketlenirse Cost Control'ün "committed
-- cost" kırılımına (project_commitments İLE BİRLİKTE, bkz.
-- docs/cost-control.md) dahil olur.
INSERT INTO project_subcontractors (
    organization_id, project_id, name, company_name, phone, email, work_description,
    contract_amount, currency, start_date, end_date, status, notes, created_by, change_order_id,
    cost_code_id, profit_percent
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17)
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
-- project_id EKLENDİ (bkz. GetSubcontractor notu). cost_code_id, Cost
-- Control sprint'i (migration 0035) -- opsiyonel. profit_percent NULL
-- gelirse mevcut değer KORUNUR: alanı bilmeyen eski istemciler (kâr payı
-- öncesi web/mobil) düzenleme yaparken onu silmesin.
UPDATE project_subcontractors
SET name = $3, company_name = $4, phone = $5, email = $6, work_description = $7,
    contract_amount = $8, start_date = $9, end_date = $10, status = $11, notes = $12, cost_code_id = $14,
    profit_percent = COALESCE($15::numeric(6,2), profit_percent)
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
--
-- Sprint 5 follow-up: "taşerona GERÇEKTEN ödenen" artık İKİ AYRI kaynaktan
-- TOPLANIR -- legacy project_subcontractor_payments (subpay/subremaining,
-- YUKARIDAKİ notta anlatılan orijinal mekanizma) VE yeni Sprint 5
-- subcontract_payments (newsubpay/newsubremaining). Bu iki kaynak FİZİKSEL
-- OLARAK AYRI tablolara, AYRI sözleşme kayıtlarına (project_subcontractors
-- vs project_subcontracts) bağlıdır -- bir proje HER İKİSİNİ de kullansa
-- bile aynı ödeme iki kez sayılamaz, saf toplama güvenlidir (bkz.
-- docs/subcontracts.md, migration 0039 gerekçesi). new_sc_value, draft/
-- cancelled sözleşmeleri HARİÇ TUTAR -- taslağın henüz hiçbir taahhüdü/
-- ödemesi anlamlı değildir (GetSubcontractCurrentValue İLE AYNI ilke).
-- name: GetProjectFinancialSummary :one
WITH proj AS (
    SELECT pr.contract_amount, pr.currency, pr.source_revision_id FROM projects pr
    WHERE pr.id = $1 AND pr.organization_id = $2
),
base_vat AS (
    -- Ana sözleşmenin KDV'si, projenin açıldığı teklif revizyonundan
    -- (contract_amount = o revizyonun KDV DAHİL genel toplamı). Tekliften
    -- açılmamış (içe aktarılmış) projede KDV bilinmez: known = false.
    SELECT COALESCE(r.vat_amount, 0)::numeric(18,2) AS total, (r.id IS NOT NULL) AS known
    FROM proj LEFT JOIN offer_revisions r ON r.id = proj.source_revision_id
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
    -- Yalnızca ONAYLI masraflar (migration 0060): onay bekleyen/reddedilen
    -- kayıt gerçekleşen maliyete ve kâra girmez.
    -- vat_total: bu masrafların İÇİNDEKİ KDV (migration 0065; oranı
    -- belirtilmemiş masrafta NULL -> sayılmaz, tutarın tamamı maliyettir).
    -- coded_vat_total: yalnızca maliyet koduna/bütçe kalemine bağlı olanlar
    -- -- Maliyet Kontrolü'nün EAC'si yalnızca onları içerir (bkz.
    -- cost_control.sql actual_by_line/unbudgeted_actual).
    SELECT COALESCE(sum(amount), 0)::numeric(18,2) AS total,
        COALESCE(sum(vat_amount), 0)::numeric(18,2) AS vat_total,
        COALESCE(sum(vat_amount) FILTER (WHERE cost_code_id IS NOT NULL OR budget_line_id IS NOT NULL), 0)::numeric(18,2)
            AS coded_vat_total
    FROM project_expenses WHERE project_id = $1 AND voided_at IS NULL AND approval_status = 'approved'
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
certified_by_sc AS (
    -- Sözleşme başına sertifikalı tutar: SOV kalemi başına en son
    -- sertifikalı kümülatifin toplamı (tanım subcontracts.sql
    -- GetSubcontractCertifiedToDate İLE BİREBİR AYNI).
    SELECT lc.subcontract_id, sum(lc.cumulative)::numeric(18,2) AS total
    FROM (
        SELECT DISTINCT ON (cl.subcontract_item_id) cl.subcontract_id, cl.cumulative
        FROM (
            SELECT pc.subcontract_id, pci.subcontract_item_id, pc.id AS claim_id, pc.certified_at,
                (max(pci.previous_progress_amount) + sum(pci.current_progress_amount))::numeric(18,2) AS cumulative
            FROM subcontract_progress_claim_items pci
            JOIN subcontract_progress_claims pc ON pc.id = pci.progress_claim_id
            WHERE pc.project_id = $1 AND pc.organization_id = $2 AND pc.status = 'certified'
            GROUP BY pc.subcontract_id, pci.subcontract_item_id, pc.id, pc.certified_at
        ) cl
        ORDER BY cl.subcontract_item_id, cl.certified_at DESC, cl.claim_id DESC
    ) lc
    GROUP BY lc.subcontract_id
),
new_sc_value AS (
    -- Sprint 5 sözleşmelerinin TAAHHÜT tabanı, proje İÇİNDEKİ TÜM
    -- sözleşmeler için TEK sorguda: güncel değer (GetSubcontractCurrentValue
    -- İLE AYNI formül: original + onaylı ekler - onaylı eksiltmeler).
    -- FESHEDİLMİŞ sözleşmede ise yalnızca sertifikalı tutar -- fesih kalan
    -- (yapılmamış) işi serbest bırakır; Cost Control'ün fesih taahhüdü
    -- (GetSubcontractTerminationTargets) İLE AYNI. Aksi halde Finans
    -- sekmesi serbest bırakılan kısmı hâlâ "kalan taahhüt" sayıyordu.
    SELECT sc.id,
        (CASE WHEN sc.status = 'terminated' THEN COALESCE(cert.total, 0)
              ELSE sc.original_amount + COALESCE(coe.approved_additions, 0) - COALESCE(coe.approved_deductions, 0)
         END)::numeric(18,2) AS current_value
    FROM project_subcontracts sc
    LEFT JOIN certified_by_sc cert ON cert.subcontract_id = sc.id
    LEFT JOIN (
        SELECT subcontract_id,
            COALESCE(sum(amount) FILTER (WHERE change_type = 'addition' AND status = 'approved'), 0)::numeric(18,2)
                AS approved_additions,
            COALESCE(sum(amount) FILTER (WHERE change_type = 'deduction' AND status = 'approved'), 0)::numeric(18,2)
                AS approved_deductions
        FROM subcontract_change_orders WHERE project_id = $1 AND organization_id = $2
        GROUP BY subcontract_id
    ) coe ON coe.subcontract_id = sc.id
    WHERE sc.project_id = $1 AND sc.organization_id = $2 AND sc.status NOT IN ('draft', 'cancelled')
),
newsubpay AS (
    SELECT COALESCE(sum(amount), 0)::numeric(18,2) AS total
    FROM subcontract_payments WHERE project_id = $1 AND organization_id = $2 AND voided_at IS NULL
),
newsubremaining AS (
    -- subremaining İLE AYNI ilke: kalan taahhüt sözleşme BAŞINA hesaplanır
    -- ve negatife düşürülmez (fazla ödenmiş bir sözleşme diğerlerinin
    -- kalan taahhüdünü azaltmamalı).
    SELECT COALESCE(sum(GREATEST(v.current_value - COALESCE(p.paid, 0), 0)), 0)::numeric(18,2) AS total
    FROM new_sc_value v
    LEFT JOIN (
        SELECT subcontract_id, sum(amount) AS paid
        FROM subcontract_payments WHERE project_id = $1 AND organization_id = $2 AND voided_at IS NULL
        GROUP BY subcontract_id
    ) p ON p.subcontract_id = v.id
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
            AS pending_deductions,
        COALESCE(sum(vat_amount) FILTER (WHERE change_type = 'addition' AND status = 'approved'), 0)::numeric(18,2)
            AS approved_vat_additions,
        COALESCE(sum(vat_amount) FILTER (WHERE change_type = 'deduction' AND status = 'approved'), 0)::numeric(18,2)
            AS approved_vat_deductions
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
    -- Güncel proje bedelinin içindeki KDV (ana sözleşme + onaylı ek işler -
    -- eksiltmeler). KDV hariç bedel ve kâr Go'da bundan türetilir
    -- (ProjectService.FinancialSummary).
    (base_vat.total + co_effect.approved_vat_additions - co_effect.approved_vat_deductions)::numeric(18,2)
        AS contract_vat_amount,
    base_vat.known::boolean AS contract_vat_known,
    (current_value.total + co_effect.pending_additions - co_effect.pending_deductions)::numeric(18,2)
        AS potential_contract_value,
    planned.total AS planned_collections,
    coll.total    AS collected_amount,
    (current_value.total - coll.total)::numeric(18,2) AS remaining_receivable,
    expense_total.total     AS total_expenses,
    -- Onaylı masrafların içindeki KDV; KDV hariç maliyetler Go'da bundan
    -- türetilir (ProjectService.applyNetFigures/applyForecast).
    expense_total.vat_total       AS expense_vat_total,
    expense_total.coded_vat_total AS coded_expense_vat_total,
    subcommit.total    AS total_subcontractor_commitment,
    subpay.total       AS subcontractor_paid,
    subremaining.total AS subcontractor_remaining,
    newsubpay.total       AS new_subcontract_paid,
    newsubremaining.total AS new_subcontract_remaining,
    inv.issued_total   AS issued_invoice_total,
    inv.paid_total     AS paid_invoice_total,
    (expense_total.total + subpay.total + newsubpay.total)::numeric(18,2) AS realized_cost,
    (expense_total.total + subpay.total + newsubpay.total + subremaining.total + newsubremaining.total)::numeric(18,2)
        AS committed_cost,
    (current_value.total - (expense_total.total + subpay.total + newsubpay.total))::numeric(18,2) AS realized_gross_profit,
    (current_value.total - (expense_total.total + subpay.total + newsubpay.total + subremaining.total + newsubremaining.total))::numeric(18,2)
        AS estimated_gross_profit,
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
              round((current_value.total - (expense_total.total + subpay.total + newsubpay.total)) * 100 / current_value.total, 2)))
         ELSE 0 END::numeric(10,2) AS realized_margin_percent,
    CASE WHEN current_value.total > 0
         THEN GREATEST(-99999999.99, LEAST(99999999.99,
              round((current_value.total - (expense_total.total + subpay.total + newsubpay.total + subremaining.total + newsubremaining.total)) * 100 / current_value.total, 2)))
         ELSE 0 END::numeric(10,2) AS estimated_margin_percent
FROM proj, base_vat, coll, planned, expense_total, subpay, subcommit, subremaining, newsubpay, newsubremaining, inv, co_effect, current_value;

-- ============ Proje Olayları (audit) ============

-- name: CreateProjectEvent :one
INSERT INTO project_events (organization_id, project_id, event_type, user_id, metadata)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: ListProjectEvents :many
SELECT * FROM project_events
WHERE project_id = $1 AND organization_id = $2
ORDER BY created_at ASC;

-- name: LockSubcontractorForPayment :one
-- Ödeme girişinde taşeron satırı KİLİTLENİR ve sözleşme bedeli ile geçerli
-- (iptal edilmemiş) ödeme toplamı okunur: toplam ödeme sözleşme bedelini
-- aşamaz (sahada 2026-10: 1.000 TL'lik sözleşmeye 21.000 TL ödeme
-- girilebilmişti). Kilit, aynı anda girilen iki ödemenin sınırı birlikte
-- delmesini önler.
SELECT s.contract_amount,
       COALESCE((SELECT sum(p.amount) FROM project_subcontractor_payments p
                 WHERE p.subcontractor_id = s.id AND p.voided_at IS NULL), 0)::numeric(18,2) AS paid_amount
FROM project_subcontractors s
WHERE s.id = $1 AND s.organization_id = $2 AND s.project_id = $3
FOR UPDATE OF s;
