-- Masraf fişi / belgesi (2026-10, kullanıcı geri bildirimi: "masraf girme
-- yerine resim ve dosya ekleme gibi bir yer olsun"). Şimdiye kadar masrafın
-- tek belgesi invoice_no metniydi; onaylayıcı fişi görmeden karar veriyordu.
-- Bir masrafa birden fazla fotoğraf (fiş, fatura) ya da PDF eklenir; projeli
-- ve genel (projesiz, migration 0068) masrafta aynı tablo.
--
-- Kurallar serviste (expense_attachments.go): ekleyip silmek masrafı girenin
-- (onay bekleyen / reddedilen masrafında) ve projects.finance.manage'in işi;
-- onaylanmış ya da iptal edilmiş masrafın belgeleri SALT OKUNUR -- onaylayıcı
-- neyi görüp onayladıysa o kalır. Silme kalıcıdır (satır + depodaki dosya):
-- karar öncesi bir taslak düzeltmesidir, iz gerekmez.
--
-- (expense_id, organization_id) birlikte masrafa bağlanır: başka firmanın
-- masrafına belge bağlanamaz (servisin organization_id'li sorgularına ek,
-- veritabanı düzeyinde ikinci savunma hattı). Masraf satırı silinirse (yalnızca
-- cmd/purge-project) belge satırı da gider; depodaki dosyayı o araç siler
-- (ListProjectObjectKeys).
ALTER TABLE project_expenses
    ADD CONSTRAINT project_expenses_id_org_key UNIQUE (id, organization_id);

CREATE TABLE expense_attachments (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    expense_id      uuid NOT NULL,
    object_key      varchar(500) NOT NULL UNIQUE,
    original_name   varchar(255) NOT NULL,
    mime_type       varchar(100) NOT NULL,
    size_bytes      bigint NOT NULL CHECK (size_bytes > 0),
    sha256          char(64) NOT NULL,
    uploaded_by     uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (expense_id, organization_id)
        REFERENCES project_expenses (id, organization_id) ON DELETE CASCADE,
    -- Aynı fiş aynı masrafa iki kez eklenmez: zayıf bağlantıda yanıtı
    -- kaybolan yüklemenin yeniden denenmesi mevcut kaydı döner.
    UNIQUE (expense_id, sha256)
);

CREATE INDEX idx_expense_attachments_expense ON expense_attachments (expense_id, created_at);
CREATE INDEX idx_expense_attachments_org ON expense_attachments (organization_id);
