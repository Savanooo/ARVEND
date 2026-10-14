-- Geri almak proje dışı taşeron ödemelerini SİLER ve projedeki taşeronların
-- kart bağını kaldırır. Göç sırasında açılan kartlar tedarikçi kataloğunda
-- kalır (başka kayıtlar onlara bağlanmış olabilir).
DROP TABLE IF EXISTS subcontractor_direct_payments;
DROP INDEX IF EXISTS idx_subcontractors_supplier;
ALTER TABLE project_subcontractors DROP COLUMN IF EXISTS supplier_id;
ALTER TABLE suppliers DROP COLUMN IF EXISTS is_subcontractor;
