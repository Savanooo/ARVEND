-- Kişiye özel izin satırları da permissions'a FK taşır (migration 0044) --
-- önce onlar, sonra rol izinleri, en son izin kodlarının kendisi.
DELETE FROM user_permission_overrides WHERE permission_code IN ('payroll.read', 'payroll.manage');
DELETE FROM role_permissions WHERE permission_code IN ('payroll.read', 'payroll.manage');
DELETE FROM permissions WHERE code IN ('payroll.read', 'payroll.manage');

DROP TRIGGER IF EXISTS trg_salary_payments_check_employee_org ON salary_payments;
DROP FUNCTION IF EXISTS salary_payments_check_employee_org();
DROP TRIGGER IF EXISTS salary_payments_set_updated_at ON salary_payments;
DROP TABLE IF EXISTS salary_payments;
