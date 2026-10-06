-- name: CreateSalaryPayment :one
INSERT INTO salary_payments (organization_id, employee_id, period, payment_type, amount, paid_date, description, created_by)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
RETURNING *;

-- name: ListSalaryPaymentsByPeriod :many
SELECT p.*, e.full_name AS employee_name
FROM salary_payments p
JOIN employees e ON e.id = p.employee_id
WHERE p.organization_id = $1
  AND p.period = $2
ORDER BY p.paid_date DESC, p.created_at DESC;

-- name: DeleteSalaryPayment :execrows
DELETE FROM salary_payments WHERE id = $1 AND organization_id = $2;

-- PayrollSummaryByPeriod: ayın ödeme tablosu, personel başına bir satır.
-- Çalışılan gün puantajdan gelir: 'geldi' = 1, 'yarım gün' = 0.5,
-- 'gelmedi'/'izinli' = 0. Hesaplanan maaş / devir / kalan burada değil,
-- domain.PayrollSummaryRow.Calculate'te (BYZ'nin calculate_salary kuralı);
-- sorgu yalnızca o ayın ham toplamlarını verir. Devir zinciri için önceki
-- aylar PayrollHistoryBefore'dan, o ayda geçerli ücret
-- ListEmployeeWageHistoryByOrganization'dan gelir.
--
-- salary_paid: işin KARŞILIĞI olan ödemeler (maaş, avans, mesai) -- kalandan
-- bunlar düşülür. Prim ve diğer (yol, yemek...) maaşın ÜSTÜNE verilir;
-- kalandan düşülselerdi verilen bir prim, fazla ödeme sayılıp sonraki ayın
-- maaşından "devir" olarak kesilirdi.
--
-- Satırda olanlar: aktif personel + (pasif/arşivli de olsa) o ay puantajı
-- ya da ödemesi bulunan herkes -- işten ayrılanın son maaşı kaybolmasın.
-- İşe girişi (start_date) bu aydan SONRA olan aktif personel, o ay verisi
-- yoksa listelenmez: aylık maaşlı biri işe girmeden önceki aylarda tam maaş
-- "kalan" gösteriyordu.
-- name: PayrollSummaryByPeriod :many
WITH att AS (
    SELECT employee_id,
           SUM(CASE status WHEN 'geldi' THEN 1 WHEN 'yarım gün' THEN 0.5 ELSE 0 END)::numeric(8,1) AS worked_days,
           SUM(work_hours)::numeric(10,2) AS work_hours
    FROM attendance_logs
    WHERE organization_id = @organization_id
      AND date_trunc('month', date) = to_date(@period::text, 'YYYY-MM')
    GROUP BY employee_id
), pay AS (
    SELECT employee_id,
           SUM(amount)::numeric(18,2) AS paid_total,
           COALESCE(SUM(amount) FILTER (WHERE payment_type IN ('maaş', 'avans', 'mesai')), 0)::numeric(18,2) AS salary_paid,
           COUNT(*)::int AS payment_count
    FROM salary_payments
    WHERE organization_id = @organization_id
      AND period = @period::text
    GROUP BY employee_id
)
SELECT e.id AS employee_id,
       e.full_name,
       e.position,
       e.salary,
       e.daily_wage,
       e.start_date,
       e.is_active,
       COALESCE(att.worked_days, 0)::numeric(8,1)       AS worked_days,
       COALESCE(att.work_hours, 0)::numeric(10,2)       AS work_hours,
       COALESCE(pay.paid_total, 0)::numeric(18,2)       AS paid_total,
       COALESCE(pay.salary_paid, 0)::numeric(18,2)      AS salary_paid,
       COALESCE(pay.payment_count, 0)::int              AS payment_count
FROM employees e
LEFT JOIN att ON att.employee_id = e.id
LEFT JOIN pay ON pay.employee_id = e.id
WHERE e.organization_id = @organization_id
  AND ((e.is_active AND (e.start_date IS NULL
                         OR e.start_date < (to_date(@period::text, 'YYYY-MM') + interval '1 month')::date))
       OR att.employee_id IS NOT NULL OR pay.employee_id IS NOT NULL)
ORDER BY e.full_name;

-- PayrollHistoryBefore: devir zinciri için @period'dan ÖNCEKİ ayların
-- personel x ay ham toplamları (çalışılan gün + maaş/avans/mesai ödemesi).
-- Yalnızca o aydan önce en az bir maaş/avans/mesai ödemesi olan personel
-- ve onların İLK böyle ödemesinin ayından itibaren: fazla ödeme ancak bir
-- ödemeyle doğar, ondan önceki aylar zincire bir şey katmaz.
-- name: PayrollHistoryBefore :many
WITH first_pay AS (
    SELECT employee_id, MIN(period) AS first_period
    FROM salary_payments
    WHERE organization_id = @organization_id::uuid
      AND period < @period::text
      AND payment_type IN ('maaş', 'avans', 'mesai')
    GROUP BY employee_id
), att AS (
    SELECT a.employee_id,
           to_char(a.date, 'YYYY-MM') AS period,
           SUM(CASE a.status WHEN 'geldi' THEN 1 WHEN 'yarım gün' THEN 0.5 ELSE 0 END)::numeric(8,1) AS worked_days
    FROM attendance_logs a
    JOIN first_pay f ON f.employee_id = a.employee_id
    WHERE a.organization_id = @organization_id::uuid
      AND a.date >= to_date(f.first_period, 'YYYY-MM')
      AND a.date < to_date(@period::text, 'YYYY-MM')
    GROUP BY a.employee_id, to_char(a.date, 'YYYY-MM')
), pay AS (
    SELECT employee_id, period, SUM(amount)::numeric(18,2) AS salary_paid
    FROM salary_payments
    WHERE organization_id = @organization_id::uuid
      AND period < @period::text
      AND payment_type IN ('maaş', 'avans', 'mesai')
    GROUP BY employee_id, period
)
SELECT COALESCE(att.employee_id, pay.employee_id)::uuid AS employee_id,
       COALESCE(att.period, pay.period)::text           AS period,
       COALESCE(att.worked_days, 0)::numeric(8,1)       AS worked_days,
       COALESCE(pay.salary_paid, 0)::numeric(18,2)      AS salary_paid
FROM att
FULL OUTER JOIN pay ON pay.employee_id = att.employee_id AND pay.period = att.period
ORDER BY 1, 2;
