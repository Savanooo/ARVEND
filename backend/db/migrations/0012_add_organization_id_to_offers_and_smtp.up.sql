ALTER TABLE offers ADD COLUMN organization_id uuid REFERENCES organizations(id);
UPDATE offers SET organization_id = '00000000-0000-0000-0000-000000000001';
ALTER TABLE offers ALTER COLUMN organization_id SET NOT NULL;
CREATE INDEX idx_offers_organization_id ON offers (organization_id);

-- smtp_settings artık her organizasyonun kendi ayarını tanımladığı bir
-- tablo -- tekil (id=1) satır yerine organization_id birincil anahtar olur.
ALTER TABLE smtp_settings ADD COLUMN organization_id uuid;
UPDATE smtp_settings SET organization_id = '00000000-0000-0000-0000-000000000001' WHERE id = 1;
ALTER TABLE smtp_settings DROP CONSTRAINT smtp_settings_pkey;
ALTER TABLE smtp_settings ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE smtp_settings ADD CONSTRAINT smtp_settings_pkey PRIMARY KEY (organization_id);
ALTER TABLE smtp_settings ADD CONSTRAINT smtp_settings_organization_id_fkey
    FOREIGN KEY (organization_id) REFERENCES organizations(id);
ALTER TABLE smtp_settings DROP COLUMN id;
