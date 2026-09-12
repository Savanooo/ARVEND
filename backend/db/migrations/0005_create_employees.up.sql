CREATE TABLE employees (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name    varchar(150) NOT NULL,
    phone        varchar(40) NOT NULL DEFAULT '',
    position     varchar(100) NOT NULL DEFAULT '',
    -- Bazı personel aylık maaşlı, bazısı günlük yevmiyeli -- BYZ'deki
    -- gibi ikisi de tutuluyor; maaş hesabı daily_wage doluysa ondan,
    -- değilse salary'den yapılır (bu iş kuralı Maaş modülünde uygulanacak).
    salary       numeric(12, 2),
    daily_wage   numeric(12, 2),
    start_date   date,
    is_active    boolean NOT NULL DEFAULT true,
    description  text NOT NULL DEFAULT '',
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    -- Hard-delete yok: mesai/atama kayıtları personelin geçmişine referans
    -- verir. Silme isteği pasifleştirme + bu alanın doldurulmasıdır.
    archived_at  timestamptz
);

CREATE INDEX idx_employees_is_active ON employees (is_active);

CREATE TRIGGER employees_set_updated_at
    BEFORE UPDATE ON employees
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
