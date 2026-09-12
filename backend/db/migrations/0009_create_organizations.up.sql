CREATE TABLE organizations (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name       varchar(200) NOT NULL,
    slug       varchar(100) NOT NULL UNIQUE,
    is_active  boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER organizations_set_updated_at BEFORE UPDATE ON organizations
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Mevcut tek-firmalı veri (Arvend Yapı) için varsayılan organizasyon.
-- Sabit UUID bilinçli: down migration'ın ve ileride "varsayılan org"
-- referans etmenin öngörülebilir olması için.
INSERT INTO organizations (id, name, slug)
VALUES ('00000000-0000-0000-0000-000000000001', 'Arvend Yapı', 'arvend-yapi');
