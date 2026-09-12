ALTER TABLE smtp_settings ADD COLUMN id smallint DEFAULT 1;
UPDATE smtp_settings SET id = 1;
ALTER TABLE smtp_settings DROP CONSTRAINT smtp_settings_organization_id_fkey;
ALTER TABLE smtp_settings DROP CONSTRAINT smtp_settings_pkey;
ALTER TABLE smtp_settings ALTER COLUMN id SET NOT NULL;
ALTER TABLE smtp_settings ADD CONSTRAINT smtp_settings_pkey PRIMARY KEY (id);
ALTER TABLE smtp_settings ADD CONSTRAINT smtp_settings_id_check CHECK (id = 1);
ALTER TABLE smtp_settings DROP COLUMN organization_id;

DROP INDEX IF EXISTS idx_offers_organization_id;
ALTER TABLE offers DROP COLUMN organization_id;
