-- Göreve "bilgi ver" (sahada 2026-10: "kişi görevi görsün, görev hakkında
-- bilgi versin, yöneticiye bildirim gitsin").
--
-- Görevde yalnızca durum vardı (yapılacak/devam/tamam); atanan kişinin
-- "şu kadarı bitti, malzeme eksik" diyebileceği bir yer yoktu. Her satır
-- bir nottur; isteğe bağlı olarak bir durum değişikliğini de taşır
-- (status_from -> status_to). Yazan kişinin adı ANLIK kopyadır (personel
-- adı sonradan değişse de eski not o anki adla kalır -- audit log ile aynı
-- ilke). Silme/düzenleme ucu yoktur: görev geçmişi bir iz kaydıdır.
CREATE TABLE project_task_updates (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    project_id      uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    task_id         uuid NOT NULL REFERENCES project_tasks(id) ON DELETE CASCADE,
    user_id         uuid REFERENCES users(id) ON DELETE SET NULL,
    author_name     varchar(200) NOT NULL DEFAULT '',
    body            text NOT NULL DEFAULT '' CHECK (char_length(body) <= 2000),
    status_from     varchar(20),
    status_to       varchar(20) CHECK (status_to IS NULL OR status_to IN ('todo', 'in_progress', 'completed', 'cancelled')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    -- Boş not olmaz: ya metin ya durum değişikliği.
    CONSTRAINT project_task_updates_not_empty CHECK (body <> '' OR status_to IS NOT NULL)
);

CREATE INDEX idx_task_updates_task ON project_task_updates (task_id, created_at);
