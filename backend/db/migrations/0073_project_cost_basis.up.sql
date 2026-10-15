-- Maliyet tanımları (2026-10, yol haritası adım 0; bkz. docs/maliyet-tanimlari.md).
-- Proje kârlılığı, proje listesi ve Ana Sayfa "gerçekleşen maliyeti" AYRI
-- AYRI ve NAKİT olarak topluyordu: sözleşmeli taşeronun onaylanmış ama
-- ödenmemiş hakedişi maliyette eksik kalıyor, iş yapılmadan verilen avans
-- maliyet sayılıyordu. Artık tanım tek yerde, bu görünümde:
--
--   gerçekleşen maliyet = onaylı masraflar
--                       + basit taşeronun İŞ KARŞILIĞI ödemeleri (avans hariç)
--                       + sözleşmeli taşeronun gerçekleşen işi
--   ödenen              = onaylı masraflar + bütün taşeron ödemeleri (avans dahil)
--   açık avans          = mahsup edilmemiş avanslar (maliyet DEĞİL, ayrıca izlenir)
--   taşerona ödenecek   = onaylı hakedişlerin net ödenecek tutarı - iş ödemeleri
--   teminatta tutulan   = onaylı hakedişlerden yapılan teminat kesintisi
--   onay bekleyen       = onay bekleyen masraflar ve onaya sunulmuş hakedişler (ayrı)
--
-- Sözleşmeli taşeronda gerçekleşen iş = onaylı hakedişin brüt iş tutarı.
-- Hakedişe bağlanmadan yapılan ödeme, sözleşmedeki avans tutarına kadar
-- AVANS sayılır (tasarım gereği, bkz. CreateSubcontractPayment); avans
-- tutarını aşan bağlantısız ödeme iş ödemesi sayılır ve gerçekleşen iş,
-- ödenen iş tutarından az gösterilmez:
--   gerçekleşen = max(onaylı hakediş, hakedişe bağlı ödeme + avansı aşan bağlantısız ödeme)
--
-- Geçmiş kayıtlar sessizce yeniden sınıflandırılmaz: mevcut basit taşeron
-- ödemeleri "iş" olarak kalır (eskisi gibi maliyettir); avans yalnızca
-- bundan sonra seçilerek girilir ve "İşe say" (mahsup) ile maliyete geçer.

ALTER TABLE project_subcontractor_payments
    ADD COLUMN payment_kind varchar(10) NOT NULL DEFAULT 'work' CHECK (payment_kind IN ('work', 'advance')),
    ADD COLUMN offset_at timestamptz,
    ADD COLUMN offset_by uuid REFERENCES users(id) ON DELETE SET NULL;

-- Proje dışı (karta) ödeme: genel ödeme ya da avans -- yalnızca bilgi,
-- proje maliyetine girmez.
ALTER TABLE subcontractor_direct_payments
    ADD COLUMN payment_kind varchar(10) NOT NULL DEFAULT 'general' CHECK (payment_kind IN ('general', 'advance'));

-- Sözleşme (project_subcontracts) BAŞINA: onaylı iş, gerçekleşen, ödenen,
-- açık avans, ödenecek, teminat ve onaya sunulmuş hakediş. Proje toplamı
-- (project_cost_basis) ve finans özetinin kalan taahhüdü bundan okunur.
CREATE VIEW subcontract_cost_basis AS
WITH cert AS (
    -- Onaylı hakediş: SOV kalemi başına en son onaylı kümülatifin toplamı
    -- (GetSubcontractCertifiedToDate ile aynı tanım).
    SELECT lc.subcontract_id, sum(lc.cumulative) AS total
    FROM (
        SELECT DISTINCT ON (cl.subcontract_item_id) cl.subcontract_id, cl.cumulative
        FROM (
            SELECT pc.subcontract_id, pci.subcontract_item_id, pc.id AS claim_id, pc.certified_at,
                   max(pci.previous_progress_amount) + sum(pci.current_progress_amount) AS cumulative
            FROM subcontract_progress_claim_items pci
            JOIN subcontract_progress_claims pc ON pc.id = pci.progress_claim_id
            WHERE pc.status = 'certified'
            GROUP BY pc.subcontract_id, pci.subcontract_item_id, pc.id, pc.certified_at
        ) cl
        ORDER BY cl.subcontract_item_id, cl.certified_at DESC, cl.claim_id DESC
    ) lc
    GROUP BY lc.subcontract_id
),
claims AS (
    SELECT pc.subcontract_id,
           sum(pc.net_payable) FILTER (WHERE pc.status = 'certified') AS net_payable,
           sum(pc.retention_amount) FILTER (WHERE pc.status = 'certified') AS retention,
           sum(pc.advance_recovery_amount) FILTER (WHERE pc.status = 'certified') AS recovered,
           sum(pc.gross_work_amount) FILTER (WHERE pc.status = 'submitted') AS pending
    FROM subcontract_progress_claims pc
    GROUP BY pc.subcontract_id
),
pay AS (
    SELECT p.subcontract_id,
           sum(p.amount) FILTER (WHERE p.progress_claim_id IS NOT NULL) AS linked,
           sum(p.amount) FILTER (WHERE p.progress_claim_id IS NULL) AS unlinked
    FROM subcontract_payments p
    WHERE p.voided_at IS NULL
    GROUP BY p.subcontract_id
),
each AS (
    SELECT sc.id, sc.organization_id, sc.project_id, sc.status,
           COALESCE(cert.total, 0) AS certified,
           COALESCE(claims.net_payable, 0) AS net_payable,
           COALESCE(claims.retention, 0) AS retention,
           COALESCE(claims.recovered, 0) AS recovered,
           COALESCE(claims.pending, 0) AS pending,
           COALESCE(pay.linked, 0) AS linked,
           COALESCE(pay.unlinked, 0) AS unlinked,
           COALESCE(sc.advance_amount, 0) AS advance_limit
    FROM project_subcontracts sc
    LEFT JOIN cert ON cert.subcontract_id = sc.id
    LEFT JOIN claims ON claims.subcontract_id = sc.id
    LEFT JOIN pay ON pay.subcontract_id = sc.id
)
SELECT id AS subcontract_id, organization_id, project_id, status,
       certified::numeric(18,2) AS certified,
       GREATEST(certified, linked + GREATEST(unlinked - advance_limit, 0))::numeric(18,2) AS accrued,
       (linked + unlinked)::numeric(18,2) AS paid,
       GREATEST(LEAST(unlinked, advance_limit) - recovered, 0)::numeric(18,2) AS advance_open,
       -- Avans tutarını aşan bağlantısız ödeme iş ödemesidir, ödenecekten düşülür.
       GREATEST(net_payable - linked - GREATEST(unlinked - advance_limit, 0), 0)::numeric(18,2) AS payable,
       retention::numeric(18,2) AS retention,
       pending::numeric(18,2) AS pending_claims
FROM each;

CREATE VIEW project_cost_basis AS
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
       (COALESCE(exp.approved, 0) + COALESCE(simple.work_paid, 0) + COALESCE(sc.accrued, 0))::numeric(18,2)
           AS realized_cost,
       (COALESCE(exp.approved, 0) + COALESCE(simple.paid, 0) + COALESCE(sc.paid, 0))::numeric(18,2)
           AS paid_cost,
       (COALESCE(simple.advance_open, 0) + COALESCE(sc.advance_open, 0))::numeric(18,2) AS advance_open,
       (COALESCE(exp.pending, 0) + COALESCE(sc.pending, 0))::numeric(18,2) AS pending_cost
FROM projects p
LEFT JOIN exp ON exp.project_id = p.id
LEFT JOIN simple ON simple.project_id = p.id
LEFT JOIN sc ON sc.project_id = p.id;
