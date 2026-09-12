ALTER TABLE products ADD COLUMN organization_id uuid REFERENCES organizations(id);
UPDATE products SET organization_id = '00000000-0000-0000-0000-000000000001';
ALTER TABLE products ALTER COLUMN organization_id SET NOT NULL;
CREATE INDEX idx_products_organization_id ON products (organization_id);

ALTER TABLE employees ADD COLUMN organization_id uuid REFERENCES organizations(id);
UPDATE employees SET organization_id = '00000000-0000-0000-0000-000000000001';
ALTER TABLE employees ALTER COLUMN organization_id SET NOT NULL;
CREATE INDEX idx_employees_organization_id ON employees (organization_id);

-- attendance_logs, employees'e FK ile bağlı (join ile de scope edilebilirdi)
-- ama savunma katmanı + basit indeksleme için doğrudan kolon tercih edildi.
ALTER TABLE attendance_logs ADD COLUMN organization_id uuid REFERENCES organizations(id);
UPDATE attendance_logs SET organization_id = '00000000-0000-0000-0000-000000000001';
ALTER TABLE attendance_logs ALTER COLUMN organization_id SET NOT NULL;
CREATE INDEX idx_attendance_logs_organization_id ON attendance_logs (organization_id);
