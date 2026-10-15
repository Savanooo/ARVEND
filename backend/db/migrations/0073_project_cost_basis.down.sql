DROP VIEW IF EXISTS project_cost_basis;
DROP VIEW IF EXISTS subcontract_cost_basis;
ALTER TABLE subcontractor_direct_payments DROP COLUMN IF EXISTS payment_kind;
ALTER TABLE project_subcontractor_payments
    DROP COLUMN IF EXISTS offset_by,
    DROP COLUMN IF EXISTS offset_at,
    DROP COLUMN IF EXISTS payment_kind;
