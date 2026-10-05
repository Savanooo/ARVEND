-- Sahada 2026-10: "plan vb. kişiye direkt bildirim gitsin", "bir resim
-- vb. yüklediğimde yöneticilere bildirim gitsin".
--
-- 1) Planlama aşamasına sorumlu personel. Görevdeki gibi: personel FK'si
--    (silinirse boşalır) + adın ANLIK kopyası (personel adı sonradan
--    değişse/silinse de planda o günkü sorumlu okunur).
ALTER TABLE project_schedule_items
    ADD COLUMN assigned_employee_id uuid REFERENCES employees(id) ON DELETE SET NULL,
    ADD COLUMN assigned_name        varchar(200) NOT NULL DEFAULT '';

CREATE INDEX idx_schedule_items_assignee ON project_schedule_items (assigned_employee_id)
    WHERE assigned_employee_id IS NOT NULL;

-- 2) Bildirim gruplama. Sahadan art arda 10 fotoğraf yüklenince yöneticiye
--    10 ayrı bildirim değil, "10 yeni fotoğraf" diyen TEK bildirim düşer:
--    aynı kişiye, aynı projede, aynı türde, henüz okunmamış ve yakın
--    zamanlı bir bildirim varsa o güncellenir (sayaç artar, öne çıkar).
ALTER TABLE notifications
    ADD COLUMN group_count int NOT NULL DEFAULT 1 CHECK (group_count >= 1);
