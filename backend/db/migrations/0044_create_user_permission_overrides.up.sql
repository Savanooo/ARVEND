-- Kişiye özel yetki ayarları: bir kullanıcının etkin izin kümesi =
-- (organizasyon rolünün izinleri ∪ grant) − revoke. Rol başlangıç noktası
-- olarak kalır; bu tablo yalnızca o kişi için rolden FARKLI olan kodları
-- tutar. Sahip (owner) rolü bu ayarlardan etkilenmez (bkz.
-- GetUserPermissions) -- firmanın kendini kilitlemesini önler.
CREATE TABLE user_permission_overrides (
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    organization_id uuid        NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    permission_code varchar(60) NOT NULL REFERENCES permissions(code),
    effect          varchar(10) NOT NULL CHECK (effect IN ('grant', 'revoke')),
    created_by      uuid        REFERENCES users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, permission_code)
);

CREATE INDEX idx_user_permission_overrides_org ON user_permission_overrides (organization_id);
