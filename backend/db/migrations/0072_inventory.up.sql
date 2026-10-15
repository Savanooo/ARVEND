-- Stok Takibi (2026-10, ürün sahibinin seçimi): projelerden BAĞIMSIZ, ayrı
-- bir menü (Diğer > Stok Takibi). Depolar, malzeme kartları, parti/SKT,
-- giriş / çıkış / depolar arası aktarım / fire / sayım fişleri.
--
-- Kurallar (araştırma notu, 2026-10-15):
--   * Çıkışta proje isteğe bağlıdır ve YALNIZCA bilgidir ("şu malzeme şu
--     projeye gitti"): projenin maliyetine YAZILMAZ -- masraflar bugünkü
--     gibi kalır, aynı malzeme iki kez sayılmaz.
--   * Fiş kaydedildikten sonra değişmez; yanlış fiş "iptal" fişiyle (ters
--     hareket) düzeltilir. Bakiye eksiye düşemez (CHECK).
--   * Maliyet hareketli ağırlıklı ortalama (VUK'ta kabul gören yöntem),
--     KDV hariç, kart başına firma geneli (depolar arası aktarım maliyeti
--     değiştirmez).
--   * SKT yasal olarak gıda terimidir; inşaat malzemesinde üretici raf
--     ömrü beyan eder. Tek "son kullanma tarihi" + malzemeye göre davranış:
--     'block' (çimento gibi -- SKT geçen parti çıkamaz, yalnızca fire) ya da
--     'warn' (köpük, silikon, boya -- uyarır).
--   * İzinler rol sistemindedir (Roller ekranından verilir):
--       inventory.read   görüntüleme
--       inventory.manage malzeme kartı, giriş, çıkış, aktarım
--       inventory.adjust fire, sayım, fiş iptali, depo yönetimi

INSERT INTO permissions (code, description, category) VALUES
    ('inventory.read', 'Stok takibini görüntüleme (malzemeler, depolar, hareketler)', 'Stok'),
    ('inventory.manage', 'Stok girişi, çıkışı, depolar arası aktarım ve malzeme kartları', 'Stok'),
    ('inventory.adjust', 'Fire, sayım düzeltmesi, fiş iptali ve depo yönetimi', 'Stok')
ON CONFLICT (code) DO NOTHING;

-- Mevcut firmalar: Sahip/Yönetici hepsini; Finans, Proje Yöneticisi ve Eski
-- Sistem görme + işlem; Saha yalnızca görme.
INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN (VALUES ('inventory.read'), ('inventory.manage'), ('inventory.adjust')) AS p(code)
WHERE orole.is_system AND orole.code IN ('owner', 'admin')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN (VALUES ('inventory.read'), ('inventory.manage')) AS p(code)
WHERE orole.is_system AND orole.code IN ('finance', 'project_manager', 'legacy_user')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, 'inventory.read'
FROM organization_roles orole
WHERE orole.is_system AND orole.code = 'field'
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

-- Yeni firmalar: seed fonksiyonu (0066 gövdesi + stok izinleri).
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

-- Depolar. İlk açılışta servis "Merkez Depo"yu kendisi açar.
CREATE TABLE inventory_warehouses (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    name             varchar(120) NOT NULL CHECK (btrim(name) <> ''),
    address          varchar(300) NOT NULL DEFAULT '',
    notes            varchar(500) NOT NULL DEFAULT '',
    is_active        boolean NOT NULL DEFAULT true,
    created_by       uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX inventory_warehouses_org_name ON inventory_warehouses (organization_id, lower(name));
CREATE TRIGGER inventory_warehouses_set_updated_at BEFORE UPDATE ON inventory_warehouses
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Malzeme kartları. Ürünler kataloğu (satış fiyat listesi, gece senkronla
-- güncellenir, silinebilir) stok kartı DEĞİLDİR; kart ürüne isteğe bağlı
-- bağlanır (ürün silinirse bağ düşer).
CREATE TABLE inventory_items (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id    uuid NOT NULL REFERENCES organizations(id),
    code               varchar(40) NOT NULL CHECK (btrim(code) <> ''),
    name               varchar(200) NOT NULL CHECK (btrim(name) <> ''),
    barcode            varchar(64) NOT NULL DEFAULT '',
    unit               varchar(20) NOT NULL DEFAULT 'adet' CHECK (btrim(unit) <> ''),
    category           varchar(100) NOT NULL DEFAULT '',
    product_id         uuid REFERENCES products(id) ON DELETE SET NULL,
    min_stock          numeric(14, 3) CHECK (min_stock >= 0),
    track_expiry       boolean NOT NULL DEFAULT false,
    shelf_life_months  integer CHECK (shelf_life_months BETWEEN 1 AND 120),
    expiry_policy      varchar(10) NOT NULL DEFAULT 'warn' CHECK (expiry_policy IN ('warn', 'block')),
    expiry_alert_days  integer NOT NULL DEFAULT 30 CHECK (expiry_alert_days BETWEEN 0 AND 365),
    avg_unit_cost      numeric(18, 4) NOT NULL DEFAULT 0 CHECK (avg_unit_cost >= 0),
    notes              varchar(1000) NOT NULL DEFAULT '',
    is_active          boolean NOT NULL DEFAULT true,
    created_by         uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX inventory_items_org_code ON inventory_items (organization_id, lower(code));
CREATE UNIQUE INDEX inventory_items_org_barcode ON inventory_items (organization_id, barcode) WHERE barcode <> '';
CREATE INDEX idx_inventory_items_org_name ON inventory_items (organization_id, lower(name));
CREATE TRIGGER inventory_items_set_updated_at BEFORE UPDATE ON inventory_items
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Partiler: parti no ve/veya son kullanma tarihi. SKT takipli malzemede
-- her girişin bir partisi vardır; diğerlerinde yalnızca parti no girilirse
-- (ör. inşaat demirinin İDİS etiket no'su).
CREATE TABLE inventory_lots (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    item_id          uuid NOT NULL REFERENCES inventory_items(id),
    lot_no           varchar(60) NOT NULL DEFAULT '',
    expiry_date      date,
    production_date  date,
    created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX inventory_lots_identity
    ON inventory_lots (item_id, lot_no, COALESCE(expiry_date, 'infinity'::date));

-- Bakiye: depo + malzeme + parti başına miktar. Hareketlerden türetilir
-- (aynı transaction'da güncellenir); eksiye düşemez.
CREATE TABLE inventory_balances (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    warehouse_id     uuid NOT NULL REFERENCES inventory_warehouses(id),
    item_id          uuid NOT NULL REFERENCES inventory_items(id),
    lot_id           uuid REFERENCES inventory_lots(id),
    quantity         numeric(14, 3) NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX inventory_balances_key
    ON inventory_balances (warehouse_id, item_id, COALESCE(lot_id, '00000000-0000-0000-0000-000000000000'::uuid));
CREATE INDEX idx_inventory_balances_item ON inventory_balances (item_id);

-- Fiş numarası: STK-<yıl>-<sıra>, firma ve yıl başına.
CREATE TABLE inventory_document_counters (
    organization_id uuid NOT NULL REFERENCES organizations(id),
    year            int NOT NULL,
    seq             int NOT NULL DEFAULT 0,
    PRIMARY KEY (organization_id, year)
);

-- Fişler. Kaydedilen fiş değişmez; iptal, ters hareketli bir 'reversal'
-- fişi açar ve aslını 'reversed' yapar.
CREATE TABLE inventory_documents (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id       uuid NOT NULL REFERENCES organizations(id),
    doc_no                varchar(30) NOT NULL,
    doc_type              varchar(20) NOT NULL
                          CHECK (doc_type IN ('receipt', 'issue', 'transfer', 'waste', 'count', 'reversal')),
    doc_date              date NOT NULL,
    warehouse_id          uuid NOT NULL REFERENCES inventory_warehouses(id),
    target_warehouse_id   uuid REFERENCES inventory_warehouses(id),
    -- Çıkışın gittiği proje: YALNIZCA bilgi, maliyete yazılmaz.
    project_id            uuid REFERENCES projects(id) ON DELETE SET NULL,
    supplier_id           uuid REFERENCES suppliers(id) ON DELETE SET NULL,
    -- Girişte kimden, çıkışta kime (serbest metin).
    counterparty          varchar(200) NOT NULL DEFAULT '',
    -- Girişte tedarikçinin irsaliye no'su (bizim fişimiz irsaliye yerine geçmez).
    reference_no          varchar(60) NOT NULL DEFAULT '',
    reason                varchar(20) NOT NULL DEFAULT ''
                          CHECK (reason IN ('', 'damaged', 'expired', 'cutting', 'lost', 'other')),
    note                  varchar(1000) NOT NULL DEFAULT '',
    attachment_key        varchar(400) NOT NULL DEFAULT '',
    attachment_mime       varchar(100) NOT NULL DEFAULT '',
    attachment_name       varchar(255) NOT NULL DEFAULT '',
    status                varchar(20) NOT NULL DEFAULT 'posted' CHECK (status IN ('posted', 'reversed')),
    reversal_of_id        uuid REFERENCES inventory_documents(id),
    reversed_at           timestamptz,
    reversed_by           uuid REFERENCES users(id) ON DELETE SET NULL,
    reverse_reason        varchar(500) NOT NULL DEFAULT '',
    idempotency_key       varchar(100),
    created_by            uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at            timestamptz NOT NULL DEFAULT now(),
    UNIQUE (organization_id, doc_no),
    CHECK (doc_type <> 'transfer' OR (target_warehouse_id IS NOT NULL AND target_warehouse_id <> warehouse_id)),
    CHECK (doc_type <> 'reversal' OR reversal_of_id IS NOT NULL)
);
CREATE UNIQUE INDEX inventory_documents_idempotency
    ON inventory_documents (organization_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE UNIQUE INDEX inventory_documents_one_reversal
    ON inventory_documents (reversal_of_id) WHERE reversal_of_id IS NOT NULL;
CREATE INDEX idx_inventory_documents_org_date ON inventory_documents (organization_id, doc_date DESC, created_at DESC);
CREATE INDEX idx_inventory_documents_project ON inventory_documents (project_id) WHERE project_id IS NOT NULL;

-- Hareket satırları (defter): işaretli miktar (+ giriş, − çıkış), satırın
-- birim maliyeti (KDV hariç). Güncellenmez, silinmez.
CREATE TABLE inventory_movements (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    document_id      uuid NOT NULL REFERENCES inventory_documents(id),
    line_no          integer NOT NULL,
    warehouse_id     uuid NOT NULL REFERENCES inventory_warehouses(id),
    item_id          uuid NOT NULL REFERENCES inventory_items(id),
    lot_id           uuid REFERENCES inventory_lots(id),
    quantity         numeric(14, 3) NOT NULL CHECK (quantity <> 0),
    unit_cost        numeric(18, 4) NOT NULL DEFAULT 0 CHECK (unit_cost >= 0),
    created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_inventory_movements_document ON inventory_movements (document_id, line_no);
CREATE INDEX idx_inventory_movements_item ON inventory_movements (item_id, created_at DESC);
