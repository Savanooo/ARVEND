-- Teklif numarası artık firma+yıl bazlı bağımsız sayaç (her firma kendi
-- TKF-YIL-0001'inden başlar) -- önceki global (yalnızca yıl bazlı) sayaç
-- birden fazla firma arasında paylaşılıyordu, SaaS'a uygun değildi.
ALTER TABLE offer_counters ADD COLUMN organization_id uuid REFERENCES organizations(id);
UPDATE offer_counters SET organization_id = '00000000-0000-0000-0000-000000000001';
ALTER TABLE offer_counters ALTER COLUMN organization_id SET NOT NULL;

ALTER TABLE offer_counters DROP CONSTRAINT offer_counters_pkey;
ALTER TABLE offer_counters ADD PRIMARY KEY (organization_id, year);
