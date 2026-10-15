-- Siparişten teslim alma (2026-10, yol haritası adım 1; bkz.
-- docs/procurement.md §12, docs/maliyet-tanimlari.md).
--
-- Onaylı bir siparişin kalemleri parça parça teslim alınır: her teslim
-- (irsaliye) kalem başına KABUL ve RED miktarı taşır. Bekleyen = sipariş -
-- kabul - red (reddedilenin yerine yenisi gelirse yeniden kabul edilebilir:
-- kabul tavanı sipariş - önceki kabuller). Teslim fişleri değişmez; yanlışsa
-- gerekçeyle iptal edilir (sipariş onaylı kaldıkça).
--
-- Teslim alma şimdilik MİKTAR kontrolüdür: maliyet yazmaz. Malın maliyeti
-- siparişe bağlanan masraftan (fatura) gelir; "teslim alınmış, maliyeti
-- girilmemiş" tutar ayrıca görünür (project_cost_basis.received_not_costed).
-- Depoya teslimde stok girişi otomatik yapılmaz (stok sarfının proje
-- maliyeti olup olmayacağı ürün sahibinin kararını bekliyor).

INSERT INTO permissions (code, description, category) VALUES
    ('projects.procurement.receive', 'Siparişten mal kabulü (teslim alma) kaydı ve iptali', 'Finans')
ON CONFLICT (code) DO NOTHING;

-- Mevcut firmalar: sipariş yönetebilen sistem rolleri teslim de alır
-- (Sahip/Yönetici, Finans, Proje Yöneticisi, Eski Sistem). Saha rolüne
-- varsayılan verilmez; Roller ekranından (siparişi görme ile birlikte)
-- verilebilir.
INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, 'projects.procurement.receive'
FROM organization_roles orole
WHERE orole.is_system AND orole.code IN ('owner', 'admin', 'finance', 'project_manager', 'legacy_user')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

-- Yeni firmalar: seed fonksiyonu (0072 gövdesi + teslim alma izni).
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
        'projects.procurement.read', 'projects.procurement.manage', 'projects.procurement.receive',
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
        'projects.procurement.read', 'projects.procurement.manage', 'projects.procurement.receive',
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
        'projects.procurement.receive',
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

CREATE TABLE purchase_receipts (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id    uuid NOT NULL REFERENCES organizations(id),
    project_id         uuid NOT NULL REFERENCES projects(id),
    purchase_order_id  uuid NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE,
    -- Siparişin kaçıncı teslimi (sipariş satırı kilitliyken verilir).
    sequence_no        int NOT NULL CHECK (sequence_no > 0),
    received_date      date NOT NULL,
    delivery_note_no   varchar(60) NOT NULL DEFAULT '',
    destination        varchar(10) NOT NULL CHECK (destination IN ('site', 'warehouse')),
    warehouse_id       uuid REFERENCES inventory_warehouses(id),
    notes              text NOT NULL DEFAULT '',
    idempotency_key    varchar(100),
    created_by         uuid REFERENCES users(id),
    created_at         timestamptz NOT NULL DEFAULT now(),
    voided_at          timestamptz,
    voided_by          uuid REFERENCES users(id),
    void_reason        varchar(500) NOT NULL DEFAULT '',
    CHECK ((destination = 'warehouse') = (warehouse_id IS NOT NULL)),
    UNIQUE (purchase_order_id, sequence_no)
);
CREATE INDEX idx_purchase_receipts_project ON purchase_receipts (project_id);
CREATE UNIQUE INDEX uq_purchase_receipts_idempotency ON purchase_receipts (organization_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE TABLE purchase_receipt_items (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id         uuid NOT NULL REFERENCES organizations(id),
    project_id              uuid NOT NULL REFERENCES projects(id),
    receipt_id              uuid NOT NULL REFERENCES purchase_receipts(id) ON DELETE CASCADE,
    purchase_order_id       uuid NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE,
    purchase_order_item_id  uuid NOT NULL REFERENCES purchase_order_items(id) ON DELETE CASCADE,
    accepted_quantity       numeric(12, 2) NOT NULL DEFAULT 0 CHECK (accepted_quantity >= 0),
    rejected_quantity       numeric(12, 2) NOT NULL DEFAULT 0 CHECK (rejected_quantity >= 0),
    rejection_reason        varchar(300) NOT NULL DEFAULT '',
    CHECK (accepted_quantity > 0 OR rejected_quantity > 0),
    UNIQUE (receipt_id, purchase_order_item_id)
);
CREATE INDEX idx_purchase_receipt_items_po_item ON purchase_receipt_items (purchase_order_item_id);
CREATE INDEX idx_purchase_receipt_items_po ON purchase_receipt_items (purchase_order_id);

-- Masrafı (alış faturasını) siparişe bağlama: "teslim alınmış, maliyeti
-- girilmemiş" tutar bundan düşer. Sipariş uygulamada silinmez (iptal
-- edilir); yalnızca temizlik araçları siler -- bağ o zaman düşer.
ALTER TABLE project_expenses
    ADD COLUMN purchase_order_id uuid REFERENCES purchase_orders(id) ON DELETE SET NULL;
CREATE INDEX idx_project_expenses_purchase_order ON project_expenses (purchase_order_id)
    WHERE purchase_order_id IS NOT NULL;

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
-- Siparişten teslim alınan (kabul edilen) malın KDV dahil değeri ile o
-- siparişe bağlanmış onaylı masraflar (fatura): aradaki fark "teslim
-- alınmış, maliyeti girilmemiş" -- maliyete girmez, kaybolmasın diye
-- ayrıca gösterilir. Yalnızca onaylı/kapatılmış sipariş.
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
