-- Proje silme (2026-10, ürün sahibinin kararı): teklifteki gibi -- Sahip ve
-- Yönetici (projects.delete) projeyi direkt siler; projeyi düzenleyebilen
-- diğerleri silme talebi açar, yetkili onaylar ya da reddeder. İçinde para
-- hareketi (masraf, tahsilat, taşeron ödemesi, fatura) ya da satın alma /
-- taşeron sözleşmesi kaydı olan proje silinmez -- İptal durumuna alınır
-- (kural serviste: ProjectService.checkProjectDeletable).
--
-- projects.delete yalnızca Sahip ve Yönetici sistem rollerine verilir
-- (seed fonksiyonu bu ikisine zaten TÜM izinleri verir); özel roller Roller
-- & Yetkiler ekranından eklenebilir. Eski Sistem (legacy_user) ALMAZ.
INSERT INTO permissions (code, description, category) VALUES
    ('projects.delete', 'Projeyi silme (yalnızca para hareketi olmayan proje)', 'Projeler')
ON CONFLICT (code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, 'projects.delete'
FROM organization_roles orole
WHERE orole.is_system AND orole.code IN ('owner', 'admin')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

-- Silme talebi: offer_delete_requests ile aynı biçim. Onaylanan talep
-- projeyle birlikte gider (ON DELETE CASCADE).
CREATE TABLE project_delete_requests (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    project_id       uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    requested_by     uuid REFERENCES users(id) ON DELETE SET NULL,
    reason           varchar(500) NOT NULL DEFAULT '',
    status           varchar(20) NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'rejected', 'withdrawn')),
    decided_by       uuid REFERENCES users(id) ON DELETE SET NULL,
    decided_at       timestamptz,
    decision_note    varchar(500) NOT NULL DEFAULT '',
    created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX project_delete_requests_one_pending
    ON project_delete_requests (project_id) WHERE status = 'pending';
CREATE INDEX idx_project_delete_requests_org_pending
    ON project_delete_requests (organization_id, created_at) WHERE status = 'pending';
