CREATE TABLE attendance_logs (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    date        date NOT NULL,
    check_in    varchar(5) NOT NULL DEFAULT '',
    check_out   varchar(5) NOT NULL DEFAULT '',
    work_hours  numeric(5, 2) NOT NULL DEFAULT 0,
    status      varchar(20) NOT NULL DEFAULT 'geldi'
                CHECK (status IN ('geldi', 'yarım gün', 'gelmedi', 'izinli')),
    note        varchar(300) NOT NULL DEFAULT '',
    created_at  timestamptz NOT NULL DEFAULT now(),
    -- Aynı personelin aynı güne iki kaydı olamaz (çift yevmiye riski) --
    -- BYZ'de bu uygulama seviyesinde kontrol ediliyordu, burada DB
    -- seviyesinde de garanti altına alınıyor.
    UNIQUE (employee_id, date)
);

CREATE INDEX idx_attendance_logs_employee_date ON attendance_logs (employee_id, date);
