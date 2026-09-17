-- ARVEND V2 — Sprint 5 follow-up: Taşeron Ödemeleri (Subcontract Payments).
--
-- migration 0038'in "Payment DEĞİLDİR" notuna (subcontract_progress_claims
-- başlığı) bilinçli olarak bıraktığı boşluğu doldurur: sertifikalı bir
-- hakediş (progress claim) bir YÜKÜMLÜLÜKTÜR, GERÇEK nakit çıkışı DEĞİLDİR.
-- Bu migration o gerçek nakit çıkışını kaydeden AYRI bir varlık ekler.
--
-- KRİTİK — yine migration 0024'ten kalma "project_subcontractor_payments"
-- İLE KARIŞTIRILMAMALI. O tablo LEGACY "project_subcontractors" sistemine
-- bağlıdır ve bu migration ONA DOKUNMAZ. Bu tablo ("subcontract_payments",
-- ÖNEKSİZ, subcontract_items/subcontract_change_orders/
-- subcontract_progress_claims İLE AYNI isimlendirme deseninde) YALNIZCA
-- YENİ "project_subcontracts" (Sprint 5) sözleşmelerine bağlanır. İkisi
-- FİZİKSEL OLARAK AYRI tablolardır, aynı ödeme iki kez sayılamaz (bkz.
-- docs/subcontracts.md).
--
-- Sertifikasyon (certified) ile ödeme (payment) BİRBİRİNDEN BAĞIMSIZDIR:
-- bir hakediş hiç ödenmeden sertifika edilebilir (net_payable bir
-- YÜKÜMLÜLÜK), bir ödeme de hiçbir hakedişe bağlı olmadan yapılabilir
-- (avans/mobilizasyon ödemesi — sözleşmenin advance_amount'u zaten bunu
-- öngörüyor). Bu yüzden progress_claim_id OPSİYONELDİR — Collection'ın
-- payment_plan_item_id İLE AYNI ilke (bkz. migration 0024).
CREATE TABLE subcontract_payments (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id    uuid NOT NULL REFERENCES organizations(id),
    project_id         uuid NOT NULL REFERENCES projects(id),
    subcontract_id     uuid NOT NULL REFERENCES project_subcontracts(id),
    progress_claim_id  uuid REFERENCES subcontract_progress_claims(id),
    amount             numeric(18, 2) NOT NULL CHECK (amount > 0),
    currency           varchar(3) NOT NULL,
    paid_date          date NOT NULL,
    payment_method     varchar(50) NOT NULL DEFAULT '',
    reference_no       varchar(100) NOT NULL DEFAULT '',
    description        varchar(500) NOT NULL DEFAULT '',
    idempotency_key    varchar(64),
    created_by         uuid REFERENCES users(id),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    voided_at          timestamptz,
    voided_by          uuid REFERENCES users(id),
    void_reason        varchar(500) NOT NULL DEFAULT ''
);

CREATE INDEX idx_subcontract_payments_subcontract ON subcontract_payments (subcontract_id);
CREATE INDEX idx_subcontract_payments_project ON subcontract_payments (project_id);
CREATE INDEX idx_subcontract_payments_claim ON subcontract_payments (progress_claim_id);

-- İdempotency anahtarı TAŞERON bazında benzersizdir (PROJE bazında DEĞİL) --
-- migration 0026'nın legacy tabloda düzelttiği HATANIN AYNISINI baştan
-- önlemek için (aynı projede farklı bir taşerona aynı anahtarla girilen
-- ödeme bu taşeronun kaydı sanılıp sessizce kaybolmasın).
CREATE UNIQUE INDEX idx_subcontract_payments_idempotency
    ON subcontract_payments (subcontract_id, idempotency_key) WHERE idempotency_key IS NOT NULL;

CREATE TRIGGER subcontract_payments_set_updated_at BEFORE UPDATE ON subcontract_payments
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- subcontract_progress_claims_check_consistency İLE AYNI desen + opsiyonel
-- progress_claim_id için subcontract_progress_claim_items_check_consistency
-- İLE AYNI çapraz-sözleşme koruması.
CREATE FUNCTION subcontract_payments_check_consistency() RETURNS trigger AS $$
DECLARE
    sc_project uuid;
    claim_subcontract uuid;
BEGIN
    SELECT project_id INTO sc_project FROM project_subcontracts WHERE id = NEW.subcontract_id;
    IF sc_project IS NULL OR sc_project <> NEW.project_id THEN
        RAISE EXCEPTION 'Ödeme, taşeron sözleşmesinin KENDİ projesine ait olmalı';
    END IF;
    IF NEW.progress_claim_id IS NOT NULL THEN
        SELECT subcontract_id INTO claim_subcontract FROM subcontract_progress_claims WHERE id = NEW.progress_claim_id;
        IF claim_subcontract IS NULL OR claim_subcontract <> NEW.subcontract_id THEN
            RAISE EXCEPTION 'Ödemenin bağlı olduğu hakediş, AYNI taşeron sözleşmesine ait olmalı';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_subcontract_payments_check_consistency
    BEFORE INSERT OR UPDATE ON subcontract_payments
    FOR EACH ROW EXECUTE FUNCTION subcontract_payments_check_consistency();

-- ---------------------------------------------------------------------------
-- İzin kayıt defteri genişletmesi — subcontracts.*/subcontract_claims.*
-- İLE AYNI desen, ama AYRI bir üçlü DEĞİL: bir ödemenin onay durumu YOKTUR
-- (create+void, Collection İLE AYNI), bu yüzden yalnızca read/manage.
-- ---------------------------------------------------------------------------
INSERT INTO permissions (code, description, category) VALUES
    ('projects.subcontract_payments.read',   'Taşeron ödemelerini görüntüleme', 'Finans'),
    ('projects.subcontract_payments.manage', 'Taşeron ödemesi kaydetme/iptal etme', 'Finans');

-- ---------------------------------------------------------------------------
-- seed_system_roles_for_org GÜNCELLENİR (CREATE OR REPLACE) — owner/admin
-- bloğu DEĞİŞMEDİ. Rol matrisi (subcontracts.* İLE AYNI ilke, ama manage
-- daha DAR tutulur):
--
--   finance: read+manage (nakit hareketinin "doğal sahibi" — legacy
--     projects.finance.manage'i zaten elinde tutuyor).
--   legacy_user / project_manager: YALNIZCA read — nakit kaydı, taslak
--     düzenlemekten (subcontracts.manage) FARKLI bir güven sınıfıdır;
--     subcontracts.approve/subcontract_claims.certify İLE AYNI gerekçeyle
--     bu iki role manage VERİLMEZ.
--   field: HİÇBİRİ — dört sprintlik emsalle AYNI.
-- ---------------------------------------------------------------------------
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
        'projects.subcontract_payments.read'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_pm, code FROM permissions WHERE code IN (
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
        'projects.subcontract_payments.read'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_finance, code FROM permissions WHERE code IN (
        'projects.read', 'projects.finance.read', 'projects.finance.manage',
        'projects.budget.read', 'projects.budget.manage',
        'projects.cost_control.read', 'projects.cost_control.manage',
        'organization.cost_codes.read', 'organization.cost_codes.manage',
        'projects.contracts.read', 'projects.contracts.manage', 'projects.contracts.lifecycle',
        'organization.suppliers.read', 'organization.suppliers.manage',
        'projects.procurement.read', 'projects.procurement.manage', 'projects.procurement.approve',
        'projects.subcontracts.read', 'projects.subcontracts.manage', 'projects.subcontracts.approve',
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage', 'projects.subcontract_claims.certify',
        'projects.subcontract_payments.read', 'projects.subcontract_payments.manage'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_field, code FROM permissions WHERE code IN (
        'projects.read',
        'projects.tasks.read', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'attendance.read'
    );
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- MEVCUT organizasyonların ZATEN seed edilmiş rollerine yeni izinleri
-- BACKFILL et (migration 0035/.../0038 İLE AYNI gerekçe).
-- ---------------------------------------------------------------------------
INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code IN ('owner', 'admin')
  AND p.code IN ('projects.subcontract_payments.read', 'projects.subcontract_payments.manage')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code IN ('legacy_user', 'project_manager')
  AND p.code = 'projects.subcontract_payments.read'
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code = 'finance'
  AND p.code IN ('projects.subcontract_payments.read', 'projects.subcontract_payments.manage')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

-- field: yeni izin YOK, kasıtlı olarak hiçbir INSERT yapılmaz.
