ALTER TABLE users ADD COLUMN organization_id uuid REFERENCES organizations(id);
UPDATE users SET organization_id = '00000000-0000-0000-0000-000000000001';
ALTER TABLE users ALTER COLUMN organization_id SET NOT NULL;

CREATE INDEX idx_users_organization_id ON users (organization_id);
