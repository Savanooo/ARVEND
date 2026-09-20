DROP TRIGGER IF EXISTS trg_employees_check_user_link_consistency ON employees;
DROP FUNCTION IF EXISTS employees_check_user_link_consistency();
DROP INDEX IF EXISTS idx_employees_user_id;
ALTER TABLE employees DROP COLUMN IF EXISTS user_id;
