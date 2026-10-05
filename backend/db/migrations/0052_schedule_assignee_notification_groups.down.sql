ALTER TABLE notifications DROP COLUMN IF EXISTS group_count;
DROP INDEX IF EXISTS idx_schedule_items_assignee;
ALTER TABLE project_schedule_items
    DROP COLUMN IF EXISTS assigned_name,
    DROP COLUMN IF EXISTS assigned_employee_id;
