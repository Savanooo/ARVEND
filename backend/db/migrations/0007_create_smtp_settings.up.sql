CREATE TABLE smtp_settings (
    id                smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    host              varchar(255) NOT NULL DEFAULT '',
    port              int NOT NULL DEFAULT 587,
    username          varchar(255) NOT NULL DEFAULT '',
    password_enc      text NOT NULL DEFAULT '',
    from_email        varchar(255) NOT NULL DEFAULT '',
    from_name         varchar(150) NOT NULL DEFAULT '',
    use_tls           boolean NOT NULL DEFAULT true,
    updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER smtp_settings_set_updated_at BEFORE UPDATE ON smtp_settings
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
