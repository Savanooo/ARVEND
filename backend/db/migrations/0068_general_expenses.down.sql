-- Geri almak genel (projesiz) masrafları SİLER: project_id yeniden zorunlu
-- olur ve projesiz satır kalamaz.
DROP INDEX IF EXISTS idx_expenses_general;
DROP INDEX IF EXISTS idx_general_expenses_idempotency;
ALTER TABLE project_expenses DROP CONSTRAINT IF EXISTS project_expenses_general_no_project_links;
DELETE FROM project_expenses WHERE project_id IS NULL;
ALTER TABLE project_expenses ALTER COLUMN project_id SET NOT NULL;
