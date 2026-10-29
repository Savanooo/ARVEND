-- Belge satırları gider; depodaki dosyalar (expenses/...) diskte kalır ve
-- hiçbir uçtan okunamaz (okuma her zaman bu tablodan geçer).
DROP TABLE IF EXISTS expense_attachments;

ALTER TABLE project_expenses DROP CONSTRAINT IF EXISTS project_expenses_id_org_key;
