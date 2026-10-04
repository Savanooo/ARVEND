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
-- 'gelmedi'/'izinli' = 0. Kalan borç HESAPLANMAZ -- aylık maaş mı yevmiye mi
-- esas alınacağı firmadan firmaya değişiyor (BYZ verisinde her personelin
-- ikisi de dolu); yanlış bir "kalan" rakamı göstermektense ham sayılar verilir.
-- Satırda olanlar: aktif personel + (pasif/arşivli de olsa) o ay puantajı
-- ya da ödemesi bulunan herkes -- işten ayrılanın son maaşı kaybolmasın.
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
       e.is_active,
       COALESCE(att.worked_days, 0)::numeric(8,1)  AS worked_days,
       COALESCE(att.work_hours, 0)::numeric(10,2)  AS work_hours,
       COALESCE(pay.paid_total, 0)::numeric(18,2)  AS paid_total,
       COALESCE(pay.payment_count, 0)::int         AS payment_count
FROM employees e
LEFT JOIN att ON att.employee_id = e.id
LEFT JOIN pay ON pay.employee_id = e.id
WHERE e.organization_id = @organization_id
  AND (e.is_active OR att.employee_id IS NOT NULL OR pay.employee_id IS NOT NULL)
ORDER BY e.full_name;
