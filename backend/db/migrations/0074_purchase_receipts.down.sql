DROP VIEW IF EXISTS project_cost_basis;
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

DROP INDEX IF EXISTS idx_project_expenses_purchase_order;
ALTER TABLE project_expenses DROP COLUMN IF EXISTS purchase_order_id;
DROP TABLE IF EXISTS purchase_receipt_items;
DROP TABLE IF EXISTS purchase_receipts;

CREATE OR REPLACE FUNCTION seed_system_roles_for_org(org_id uuid) RETURNS void AS $$
DECLARE
    r_owner uuid;
    r_admin uuid;
    r_legacy uuid;
    r_pm uuid;
    r_finance uuid;
    r_field uuid;
BEGIN
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'owner', 'Sahip (Owner)', 'Firmadaki tüm izinlere sahiptir; son sahip kaldırılamaz.', true)
    RETURNING id INTO r_owner;
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'admin', 'Yönetici', 'Firmadaki tüm izinlere sahiptir.', true)
    RETURNING id INTO r_admin;
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'legacy_user', 'Kullanıcı (Eski Sistem)', 'Migration öncesi "kullanıcı" rolünün izin karşılığı -- yeni kullanıcılara atanmaz.', true)
    RETURNING id INTO r_legacy;
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'project_manager', 'Proje Yöneticisi', 'Yalnızca atandığı projelerde operasyonel yönetim yapar.', true)
    RETURNING id INTO r_pm;
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'finance', 'Finans', 'Yalnızca atandığı projelerin finansal verilerini yönetir.', true)
    RETURNING id INTO r_finance;
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'field', 'Saha', 'Yalnızca atandığı projelerde saha operasyonu (görev/dosya/fotoğraf) yapar.', true)
    RETURNING id INTO r_field;

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_owner, code FROM permissions;
    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_admin, code FROM permissions;

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_legacy, code FROM permissions WHERE code IN (
        'projects.expenses.create',
        'projects.read', 'projects.create', 'projects.update',
        'projects.finance.read', 'projects.finance.manage',
        'projects.tasks.read', 'projects.tasks.create', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'projects.access.read',
        'offers.read', 'offers.create', 'offers.update', 'offers.approve', 'offers.delete',
        'calculations.read', 'products.read',
        'customers.read', 'customers.manage',
        'employees.read',
        'attendance.read', 'attendance.manage',
        'projects.budget.read', 'projects.budget.manage',
        'projects.cost_control.read', 'projects.cost_control.manage',
        'organization.cost_codes.read',
        'projects.contracts.read', 'projects.contracts.manage',
        'organization.suppliers.read',
        'projects.procurement.read', 'projects.procurement.manage',
        'projects.subcontracts.read', 'projects.subcontracts.manage',
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage',
        'projects.subcontract_payments.read',
        'inventory.read', 'inventory.manage',
        'notifications.read'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_pm, code FROM permissions WHERE code IN (
        'projects.expenses.create',
        'projects.read', 'projects.update',
        'projects.tasks.read', 'projects.tasks.create', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'projects.access.read',
        'calculations.read', 'products.read', 'customers.read',
        'projects.budget.read', 'projects.cost_control.read',
        'organization.cost_codes.read',
        'projects.contracts.read', 'projects.contracts.manage',
        'organization.suppliers.read',
        'projects.procurement.read', 'projects.procurement.manage',
        'projects.subcontracts.read', 'projects.subcontracts.manage',
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage',
        'projects.subcontract_payments.read',
        'inventory.read', 'inventory.manage',
        'notifications.read'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_finance, code FROM permissions WHERE code IN (
        'projects.expenses.create',
        'projects.read', 'projects.finance.read', 'projects.finance.manage',
        'projects.budget.read', 'projects.budget.manage', 'projects.budget.approve',
        'projects.cost_control.read', 'projects.cost_control.manage',
        'organization.cost_codes.read', 'organization.cost_codes.manage',
        'projects.contracts.read', 'projects.contracts.manage', 'projects.contracts.lifecycle',
        'organization.suppliers.read', 'organization.suppliers.manage',
        'projects.procurement.read', 'projects.procurement.manage', 'projects.procurement.approve',
        'projects.subcontracts.read', 'projects.subcontracts.manage', 'projects.subcontracts.approve',
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage', 'projects.subcontract_claims.certify',
        'projects.subcontract_payments.read', 'projects.subcontract_payments.manage',
        'offers.internal_pricing.read', 'offers.internal_pricing.manage',
        'inventory.read', 'inventory.manage',
        'notifications.read'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_field, code FROM permissions WHERE code IN (
        'projects.expenses.create',
        'projects.read',
        'projects.tasks.read', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'attendance.read',
        'inventory.read',
        'notifications.read'
    );
END;
$$ LANGUAGE plpgsql;

DELETE FROM role_permissions WHERE permission_code = 'projects.procurement.receive';
DELETE FROM user_permission_overrides WHERE permission_code = 'projects.procurement.receive';
DELETE FROM permissions WHERE code = 'projects.procurement.receive';
