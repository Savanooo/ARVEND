DROP INDEX IF EXISTS idx_notifications_push_pending;
ALTER TABLE notifications DROP COLUMN IF EXISTS pushed_at;
DROP TABLE IF EXISTS push_devices;
