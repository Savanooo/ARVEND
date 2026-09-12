CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE users (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    username       varchar(50) NOT NULL UNIQUE,
    password_hash  varchar(255) NOT NULL,
    full_name      varchar(150) NOT NULL,
    role           varchar(20) NOT NULL DEFAULT 'kullanici'
                   CHECK (role IN ('admin', 'kullanici')),
    is_active      boolean NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    last_login_at  timestamptz
);

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_set_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
