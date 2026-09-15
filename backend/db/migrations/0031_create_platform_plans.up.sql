-- Minimal SaaS plan modeli. Faz10 subscription/billing engine (Stripe/Iyzico
-- vb.) HENÜZ YOK ve bu migration onu simüle etmiyor -- yalnızca "bu firma
-- hangi plan etiketine sahip" bilgisini saklar. max_users/max_projects
-- BUGÜN HİÇBİR YERDE ENFORCE EDİLMİYOR (ayrı bir feature-gate fazına
-- bırakıldı, bkz. AZ. SON RAPOR) -- yalnızca ileride kullanılmak üzere
-- saklanıyor.
CREATE TABLE platform_plans (
    code       varchar(30) PRIMARY KEY,
    name       varchar(100) NOT NULL,
    is_active  boolean NOT NULL DEFAULT true,
    max_users     int,
    max_projects  int,
    sort_order    int NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER platform_plans_set_updated_at BEFORE UPDATE ON platform_plans
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

INSERT INTO platform_plans (code, name, sort_order) VALUES
    ('trial',    'Deneme',      0),
    ('starter',  'Başlangıç',   1),
    ('pro',      'Pro',         2),
    ('business', 'Kurumsal',    3);

ALTER TABLE organizations ADD COLUMN plan_code varchar(30) NOT NULL DEFAULT 'trial'
    REFERENCES platform_plans(code);

-- Mevcut "Arvend Yapı" gerçek, çalışan bir müşteridir -- deneme değil.
UPDATE organizations SET plan_code = 'business'
WHERE id = '00000000-0000-0000-0000-000000000001';
