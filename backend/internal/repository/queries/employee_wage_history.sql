-- Ücret geçmişi (migration 0056). Maaş hesabı her ayı o ayda geçerli
-- ücretle yapar (bkz. domain.WageForPeriod).

-- name: UpsertEmployeeWage :exec
-- Aynı gün ikinci değişiklik öncekinin yerine geçer.
INSERT INTO employee_wage_history (organization_id, employee_id, salary, daily_wage, effective_from, created_by)
VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (employee_id, effective_from) DO UPDATE
SET salary = EXCLUDED.salary,
    daily_wage = EXCLUDED.daily_wage,
    created_by = EXCLUDED.created_by,
    created_at = now();

-- name: InsertEmployeeWageIfNone :exec
-- Geçmişi hiç olmayan personel (ör. migration'dan sonra servisi atlayarak
-- eklenmiş) için başlangıç satırı: ilk ücret değişikliğinden ÖNCE eski
-- ücret kaydedilmezse, değişiklik geçmiş ayların tamamına yayılırdı.
-- İleri tarihli işe giriş bugüne çekilir: geçmişte ileri tarihli bir satır
-- kalırsa bugünkü değişiklik o aydan itibaren ESKİ ücrete yenik düşerdi.
INSERT INTO employee_wage_history (organization_id, employee_id, salary, daily_wage, effective_from)
SELECT e.organization_id, e.id, e.salary, e.daily_wage,
       LEAST(COALESCE(e.start_date, DATE '2000-01-01'), sqlc.arg(today)::date)
FROM employees e
WHERE e.id = sqlc.arg(id) AND e.organization_id = sqlc.arg(organization_id)
  AND NOT EXISTS (SELECT 1 FROM employee_wage_history h WHERE h.employee_id = e.id)
ON CONFLICT (employee_id, effective_from) DO NOTHING;

-- name: ListEmployeeWageHistoryByOrganization :many
SELECT employee_id, salary, daily_wage, effective_from
FROM employee_wage_history
WHERE organization_id = $1
ORDER BY employee_id, effective_from;

-- name: ListEmployeeWageHistory :many
SELECT * FROM employee_wage_history
WHERE employee_id = $1 AND organization_id = $2
ORDER BY effective_from;
