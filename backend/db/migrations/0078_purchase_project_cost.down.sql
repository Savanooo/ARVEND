DROP VIEW IF EXISTS project_cost_basis;
DROP VIEW IF EXISTS project_cost_lines;
DROP VIEW IF EXISTS purchase_request_cost_basis;
DROP VIEW IF EXISTS purchase_order_cost_basis;
DROP VIEW IF EXISTS purchase_order_item_cost;

-- 0074'teki tanım (satın almalar maliyete girmez).
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
),
po_accepted AS (
    SELECT ri.purchase_order_id, sum(round(ri.accepted_quantity * poi.unit_price, 2)) AS net
    FROM purchase_receipt_items ri
    JOIN purchase_receipts r ON r.id = ri.receipt_id
    JOIN purchase_order_items poi ON poi.id = ri.purchase_order_item_id
    WHERE r.voided_at IS NULL
    GROUP BY ri.purchase_order_id
),
po_costed AS (
    SELECT e.purchase_order_id, sum(e.amount) AS total
    FROM project_expenses e
    WHERE e.purchase_order_id IS NOT NULL AND e.voided_at IS NULL AND e.approval_status = 'approved'
    GROUP BY e.purchase_order_id
),
po AS (
    SELECT po.project_id,
           sum(GREATEST(a.net + round(a.net * po.tax_rate / 100, 2) - COALESCE(c.total, 0), 0)) AS received_not_costed
    FROM purchase_orders po
    JOIN po_accepted a ON a.purchase_order_id = po.id
    LEFT JOIN po_costed c ON c.purchase_order_id = po.id
    WHERE po.status IN ('approved', 'closed')
    GROUP BY po.project_id
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
       (COALESCE(exp.pending, 0) + COALESCE(sc.pending, 0))::numeric(18,2) AS pending_cost,
       COALESCE(po.received_not_costed, 0)::numeric(18,2) AS received_not_costed
FROM projects p
LEFT JOIN exp ON exp.project_id = p.id
LEFT JOIN simple ON simple.project_id = p.id
LEFT JOIN sc ON sc.project_id = p.id
LEFT JOIN po ON po.project_id = p.id;

DROP INDEX IF EXISTS idx_purchase_orders_purchase_request;
ALTER TABLE purchase_orders
    DROP COLUMN IF EXISTS include_in_project_cost,
    DROP COLUMN IF EXISTS purchase_request_id;
ALTER TABLE purchase_requests
    DROP COLUMN IF EXISTS cost_estimate,
    DROP COLUMN IF EXISTS include_in_project_cost;
