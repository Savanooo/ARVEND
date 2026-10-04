-- Maaş ve mesai ödemeleri (BYZ'deki salary_payments'ın karşılığı).
--
-- Mesai sayfası yalnızca puantaj tutuyordu; personele ay ay ne ödendiği
-- (maaş, avans, fazla mesai, prim) hiçbir yerde yoktu. Bu tablo ödemenin
-- KENDİSİDİR -- "planlanan/ödenmedi" durumu yoktur: BYZ'de 56 kaydın 56'sı
-- da ödenmişti (is_paid=true), kayıt zaten ödeme anında giriliyordu. Bir
-- satır = yapılmış bir ödeme.
--
-- Aynı personele aynı ay için BİRDEN ÇOK ödeme olabilir (avans + kalan):
-- BYZ verisinde 15 personel/ay çiftinde birden fazla ödeme var. Bu yüzden
-- (employee_id, period) üzerinde UNIQUE YOKTUR.
--
-- period, ödemenin ait olduğu ay ('YYYY-MM'); paid_date ödemenin yapıldığı
-- gün. İkisi ayrı: Eylül maaşı Ekim'in 5'inde ödenebilir.

CREATE TABLE salary_payments (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    -- Personel silinmez, arşivlenir (employees.archived_at); ödeme geçmişi
    -- para kaydıdır, personelle birlikte sessizce gitmemeli -> CASCADE YOK.
    employee_id     uuid NOT NULL REFERENCES employees(id),
    period          varchar(7) NOT NULL
                    CONSTRAINT salary_payments_period_check
                    CHECK (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
    payment_type    varchar(20) NOT NULL DEFAULT 'maaş'
                    CONSTRAINT salary_payments_payment_type_check
                    CHECK (payment_type IN ('maaş', 'avans', 'mesai', 'prim', 'diğer')),
    amount          numeric(18,2) NOT NULL
                    CONSTRAINT salary_payments_amount_check CHECK (amount > 0),
    paid_date       date NOT NULL DEFAULT CURRENT_DATE,
    description     text NOT NULL DEFAULT '',
    created_by      uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_salary_payments_org_period ON salary_payments (organization_id, period);
CREATE INDEX idx_salary_payments_employee ON salary_payments (employee_id);

CREATE TRIGGER salary_payments_set_updated_at
    BEFORE UPDATE ON salary_payments
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Tenant sınırı veritabanında da: ödeme yalnızca AYNI organizasyonun
-- personeline yazılabilir. Servis katmanı da kontrol ediyor (bkz.
-- SalaryPaymentService.Create), ama bu tabloya servisi atlayarak yazan bir
-- yol da var: BYZ aktarım aracı (cmd/migrate-byz-personel). Faz 1 denetimindeki
-- cross-tenant FK sızıntısıyla AYNI sınıf hata burada DB'de kapanır.
CREATE OR REPLACE FUNCTION salary_payments_check_employee_org() RETURNS trigger AS $$
DECLARE
    emp_org uuid;
BEGIN
    SELECT organization_id INTO emp_org FROM employees WHERE id = NEW.employee_id;
    IF emp_org IS NULL OR emp_org <> NEW.organization_id THEN
        RAISE EXCEPTION 'Maaş ödemesi yalnızca AYNI organizasyonun personeline kaydedilebilir';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_salary_payments_check_employee_org
    BEFORE INSERT OR UPDATE ON salary_payments
    FOR EACH ROW EXECUTE FUNCTION salary_payments_check_employee_org();

-- ---------------------------------------------------------------------------
-- İzinler. Maaş tutarı hassastır: bugün personel maaşları da yalnızca
-- yönetici ekranında görünüyor. Bu yüzden attendance.* değil, AYRI bir ikili
-- (taşeron ödemeleriyle aynı desen: onay durumu yok, yalnızca read/manage).
--
-- Rol matrisi: YALNIZCA owner/admin. seed_system_roles_for_org owner/admin'e
-- zaten "SELECT code FROM permissions" ile TÜM izinleri verdiği için yeni
-- firmalar bunları kendiliğinden alır -- fonksiyonu yeniden tanımlamaya gerek
-- YOK. Diğer rollere (Finans dahil -- o rol proje bazlı) varsayılan olarak
-- verilmez; gerekirse Roller ekranından ya da kişiye özel izinle eklenir.
-- ---------------------------------------------------------------------------
INSERT INTO permissions (code, description, category) VALUES
    ('payroll.read',   'Maaş ve mesai ödemelerini görüntüleme', 'Personel'),
    ('payroll.manage', 'Maaş ve mesai ödemesi kaydetme/silme',  'Personel');

-- Mevcut firmaların owner/admin rollerine BACKFILL (0039 ile aynı gerekçe:
-- seed fonksiyonu yalnızca YENİ firmalarda çalışır).
INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code IN ('owner', 'admin')
  AND p.code IN ('payroll.read', 'payroll.manage')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;
