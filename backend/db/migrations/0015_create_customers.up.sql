CREATE TABLE customers (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    name             varchar(200) NOT NULL,
    phone            varchar(40) NOT NULL DEFAULT '',
    email            varchar(120) NOT NULL DEFAULT '',
    address          varchar(500) NOT NULL DEFAULT '',
    tax_office       varchar(100) NOT NULL DEFAULT '',
    tax_number       varchar(50) NOT NULL DEFAULT '',
    notes            text NOT NULL DEFAULT '',
    is_active        boolean NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_customers_organization_id ON customers (organization_id);

CREATE TRIGGER customers_set_updated_at BEFORE UPDATE ON customers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
