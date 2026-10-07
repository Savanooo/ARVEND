-- Ücret geçmişi (maaş / yevmiye, yürürlük tarihiyle).
--
-- Maaş tablosu her ayı personelin GÜNCEL ücretiyle hesaplıyordu: ekimde
-- yapılan bir zam, tamamı ödenmiş eylülü "4.000 TL bekliyor" gösteriyor;
-- bir indirim sahte fazla ödeme (ve devir) üretiyor; geçmiş ayların PDF
-- dökümü yeni ücretle yeniden basılıyordu. Artık her ücret değişikliği bir
-- satır olarak saklanır ve her ay O AYDA geçerli ücretle hesaplanır
-- (bkz. domain.WageForPeriod: ayın son günü itibarıyla yürürlükteki satır).
--
-- employees.salary/daily_wage KALIR: güncel ücret oradan okunmaya devam
-- eder (personel listesi, formlar); bu tablo yalnızca geçmişi tutar.

CREATE TABLE employee_wage_history (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    -- Personel hard-delete edilmez (arşivlenir); geçmiş personelin bir
    -- parçasıdır, personel satırı bir gün silinirse onunla gider.
    employee_id     uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    -- employees ile aynı model: ikisi de dolu olabilir (yevmiye esastır),
    -- ikisi de boş olabilir (ücret tanımsız).
    salary          numeric(18, 2),
    daily_wage      numeric(18, 2),
    effective_from  date NOT NULL,
    created_by      uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    -- Aynı gün iki değişiklik: sonuncusu geçerli (servis upsert eder).
    CONSTRAINT employee_wage_history_one_per_day UNIQUE (employee_id, effective_from)
);

CREATE INDEX idx_employee_wage_history_org ON employee_wage_history (organization_id, employee_id, effective_from);

-- Tenant sınırı veritabanında da (salary_payments ile aynı gerekçe: BYZ
-- aktarım aracı gibi servisi atlayan yazıcılar var).
CREATE OR REPLACE FUNCTION employee_wage_history_check_employee_org() RETURNS trigger AS $$
DECLARE
    emp_org uuid;
BEGIN
    SELECT organization_id INTO emp_org FROM employees WHERE id = NEW.employee_id;
    IF emp_org IS NULL OR emp_org <> NEW.organization_id THEN
        RAISE EXCEPTION 'Ücret geçmişi yalnızca AYNI organizasyonun personeline kaydedilebilir';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_employee_wage_history_check_employee_org
    BEFORE INSERT OR UPDATE ON employee_wage_history
    FOR EACH ROW EXECUTE FUNCTION employee_wage_history_check_employee_org();

-- Backfill: her personel için bugünkü ücret, işe girişinden (yoksa çok
-- eski bir tarihten) itibaren geçerli tek satır. Geçmişte gerçekte ne
-- ödendiği bilinmiyor; bugüne kadarki davranış da tam olarak buydu (her ay
-- güncel ücret), yani bu satır mevcut hiçbir rakamı değiştirmez -- yalnızca
-- BUNDAN SONRAKİ değişiklikler geçmişi bozmaz. İleri tarihli işe giriş
-- bugüne çekilir (ileri tarihli bir satır, bugün yapılacak bir değişikliği
-- o aydan itibaren ezerdi).
INSERT INTO employee_wage_history (organization_id, employee_id, salary, daily_wage, effective_from)
SELECT organization_id, id, salary, daily_wage,
       LEAST(COALESCE(start_date, DATE '2000-01-01'), (now() AT TIME ZONE 'Europe/Istanbul')::date)
FROM employees
ON CONFLICT (employee_id, effective_from) DO NOTHING;
