-- Faz 7: proje operasyon modülleri (ekip, planlama, görev, dosya, fotoğraf, not).

-- project_members, mevcut employees kayıtlarını projeye bağlar.
-- employee_name/role atama ANINDAKİ anlık görüntüdür: personel kartı
-- sonradan değişse (ad düzeltmesi, görev değişikliği) bile projenin
-- geçmiş ekip kaydı ne yazdığını korur.
CREATE TABLE project_members (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    employee_id     uuid NOT NULL REFERENCES employees(id),
    employee_name   varchar(200) NOT NULL,
    role_title      varchar(120) NOT NULL DEFAULT '',
    start_date      date,
    end_date        date,
    notes           text NOT NULL DEFAULT '',
    created_by      uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Aynı çalışan aynı projede AYNI ANDA birden fazla aktif atama alamaz;
-- ekipten çıkarılmış (end_date dolu) geçmiş kayıtlar sınıra takılmaz,
-- böylece kişi ayrılıp geri dönebilir ve her iki dönem de iz olarak kalır.
CREATE UNIQUE INDEX idx_project_members_active_unique
    ON project_members (project_id, employee_id)
    WHERE end_date IS NULL;

CREATE INDEX idx_project_members_project ON project_members (project_id);
CREATE INDEX idx_project_members_org ON project_members (organization_id);

CREATE TRIGGER project_members_set_updated_at BEFORE UPDATE ON project_members
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- project_schedule_items, aşama bazlı planlamadır. Gantt kütüphanesi bu
-- fazda kurulmuyor ama veri modeli (başlangıç/bitiş/sıra) ileride Gantt
-- görünümüne doğrudan beslenebilecek şekilde tutuluyor.
CREATE TABLE project_schedule_items (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name            varchar(200) NOT NULL,
    description     text NOT NULL DEFAULT '',
    start_date      date,
    end_date        date,
    status          varchar(20) NOT NULL DEFAULT 'planned'
                    CHECK (status IN ('planned', 'active', 'completed', 'cancelled')),
    sort_order      int NOT NULL DEFAULT 0,
    created_by      uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_schedule_items_project ON project_schedule_items (project_id, sort_order);
CREATE INDEX idx_schedule_items_org ON project_schedule_items (organization_id);

CREATE TRIGGER schedule_items_set_updated_at BEFORE UPDATE ON project_schedule_items
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE project_tasks (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id      uuid NOT NULL REFERENCES organizations(id),
    project_id           uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    schedule_item_id     uuid REFERENCES project_schedule_items(id) ON DELETE SET NULL,
    title                varchar(200) NOT NULL,
    description          text NOT NULL DEFAULT '',
    assigned_employee_id uuid REFERENCES employees(id) ON DELETE SET NULL,
    assigned_name        varchar(200) NOT NULL DEFAULT '',
    priority             varchar(10) NOT NULL DEFAULT 'normal'
                         CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
    status               varchar(20) NOT NULL DEFAULT 'todo'
                         CHECK (status IN ('todo', 'in_progress', 'completed', 'cancelled')),
    due_date             date,
    completed_at         timestamptz,
    created_by           uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    -- completed_at yalnızca ve her zaman "completed" durumunda dolu olur;
    -- durum ile tarih birbirinden kopamaz.
    CONSTRAINT project_tasks_completed_at_matches_status
        CHECK ((status = 'completed') = (completed_at IS NOT NULL))
);

CREATE INDEX idx_project_tasks_project ON project_tasks (project_id);
CREATE INDEX idx_project_tasks_org ON project_tasks (organization_id);
CREATE INDEX idx_project_tasks_schedule ON project_tasks (schedule_item_id);
CREATE INDEX idx_project_tasks_assignee ON project_tasks (assigned_employee_id);

CREATE TRIGGER project_tasks_set_updated_at BEFORE UPDATE ON project_tasks
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- project_files.object_key, depolama katmanındaki nesnenin anahtarıdır ve
-- TAMAMEN SUNUCU tarafından üretilir (org/proje uuid'leri + yeni bir uuid).
-- Kullanıcının gönderdiği dosya adı yalnızca original_name'de, görüntüleme
-- amacıyla saklanır; hiçbir zaman dosya sistemi yoluna dönüştürülmez --
-- path traversal bu yüzden filtrelenen değil, YAPISAL OLARAK imkansız bir
-- durumdur. mime_type da istemcinin beyanı değil, içerikten tespit edilen
-- değerdir.
CREATE TABLE project_files (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    original_name   varchar(255) NOT NULL,
    object_key      varchar(500) NOT NULL UNIQUE,
    mime_type       varchar(150) NOT NULL,
    size_bytes      bigint NOT NULL CHECK (size_bytes > 0),
    sha256          char(64) NOT NULL,
    category        varchar(20) NOT NULL DEFAULT 'other'
                    CHECK (category IN ('contract', 'drawing', 'invoice', 'report', 'other')),
    description     varchar(500) NOT NULL DEFAULT '',
    uploaded_by     uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,
    deleted_by      uuid REFERENCES users(id) ON DELETE SET NULL
);

-- Aynı içerik (sha256) aynı projeye iki kez yüklenmez; silinmiş kayıtlar
-- sınıra takılmaz, böylece silinen bir belge yeniden yüklenebilir.
CREATE UNIQUE INDEX idx_project_files_sha_unique
    ON project_files (project_id, sha256)
    WHERE deleted_at IS NULL;

CREATE INDEX idx_project_files_project ON project_files (project_id);
CREATE INDEX idx_project_files_org ON project_files (organization_id);

CREATE TABLE project_photos (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    original_name   varchar(255) NOT NULL,
    object_key      varchar(500) NOT NULL UNIQUE,
    mime_type       varchar(150) NOT NULL,
    size_bytes      bigint NOT NULL CHECK (size_bytes > 0),
    sha256          char(64) NOT NULL,
    stage           varchar(20) NOT NULL DEFAULT 'progress'
                    CHECK (stage IN ('before', 'progress', 'after')),
    description     varchar(500) NOT NULL DEFAULT '',
    taken_at        timestamptz,
    uploaded_by     uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,
    deleted_by      uuid REFERENCES users(id) ON DELETE SET NULL
);

CREATE UNIQUE INDEX idx_project_photos_sha_unique
    ON project_photos (project_id, sha256)
    WHERE deleted_at IS NULL;

CREATE INDEX idx_project_photos_project ON project_photos (project_id, stage);
CREATE INDEX idx_project_photos_org ON project_photos (organization_id);

-- Tek bir projects.notes alanı yerine tarihli kayıtlar: kimin ne zaman ne
-- yazdığı korunur.
CREATE TABLE project_notes (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    project_id      uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    content         text NOT NULL,
    created_by      uuid REFERENCES users(id) ON DELETE SET NULL,
    created_by_name varchar(200) NOT NULL DEFAULT '',
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_project_notes_project ON project_notes (project_id, created_at DESC);
CREATE INDEX idx_project_notes_org ON project_notes (organization_id);

CREATE TRIGGER project_notes_set_updated_at BEFORE UPDATE ON project_notes
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
