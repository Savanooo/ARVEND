-- Günlük şantiye raporu (2026-10, ürün sahibinin seçimi): saha şefi her gün
-- projenin raporunu telefondan doldurur -- hava, kendi ekibinden ve
-- taşeronlardan kaç kişi çalıştı, yapılan işler, sorunlar, gelen malzeme,
-- notlar. O gün tamamlanan görevler ve çekilen fotoğraflar rapora
-- kendiliğinden eklenir (ayrı tablo yok, tarihle okunur). "Gönder" raporu
-- yöneticilere bildirir; PDF olarak paylaşılır.
--
-- Proje başına günde tek rapor. İzinler mevcut operasyon izinleridir:
-- okuma projects.operations.read, yazma/gönderme projects.operations.manage.
CREATE TABLE project_daily_reports (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    project_id       uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    report_date      date NOT NULL,
    weather          varchar(20) NOT NULL DEFAULT ''
                     CHECK (weather IN ('', 'sunny', 'cloudy', 'rainy', 'snowy', 'windy')),
    temperature_c    smallint CHECK (temperature_c BETWEEN -50 AND 60),
    own_workers      integer NOT NULL DEFAULT 0 CHECK (own_workers BETWEEN 0 AND 10000),
    work_done        text NOT NULL DEFAULT '',
    issues           text NOT NULL DEFAULT '',
    materials        text NOT NULL DEFAULT '',
    notes            text NOT NULL DEFAULT '',
    status           varchar(20) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'submitted')),
    submitted_at     timestamptz,
    submitted_by     uuid REFERENCES users(id) ON DELETE SET NULL,
    created_by       uuid REFERENCES users(id) ON DELETE SET NULL,
    updated_by       uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project_id, report_date)
);

CREATE INDEX idx_daily_reports_org_date ON project_daily_reports (organization_id, report_date);

CREATE TRIGGER project_daily_reports_set_updated_at BEFORE UPDATE ON project_daily_reports
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Sahadaki taşeronlar: Taşeronlar kartı (migration 0069) + o gün kaç kişi.
-- Taşeronun sayfası "sahada çalıştığı günleri" buradan okur.
CREATE TABLE project_daily_report_subcontractors (
    report_id        uuid NOT NULL REFERENCES project_daily_reports(id) ON DELETE CASCADE,
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    supplier_id      uuid NOT NULL REFERENCES suppliers(id),
    workers          integer NOT NULL DEFAULT 0 CHECK (workers BETWEEN 0 AND 10000),
    work_note        varchar(300) NOT NULL DEFAULT '',
    PRIMARY KEY (report_id, supplier_id)
);

CREATE INDEX idx_daily_report_subs_supplier ON project_daily_report_subcontractors (supplier_id);
