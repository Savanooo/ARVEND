-- Öneri / görüş (sahada 2026-10: "çalışan öneri girsin, bizim admine
-- düşsün"). Firmaların kullanıcılarından platform ekibine (Super Admin):
-- firma yöneticisi değil, ARVEND'i geliştirenler okur.
--
-- Yazanın adı ANLIK kopyadır (personel adı değişse de kayıt o günkü adla
-- kalır); kullanıcı silinirse satır durur, user_id boşalır.
CREATE TABLE feedback_messages (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    user_id         uuid REFERENCES users(id) ON DELETE SET NULL,
    user_name       varchar(200) NOT NULL DEFAULT '',
    category        varchar(20) NOT NULL DEFAULT 'oneri'
                    CHECK (category IN ('oneri', 'hata', 'sikayet', 'diger')),
    body            text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 2000),
    app_version     varchar(40) NOT NULL DEFAULT '',
    read_at         timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_feedback_messages_created ON feedback_messages (created_at DESC);
CREATE INDEX idx_feedback_messages_unread ON feedback_messages (created_at) WHERE read_at IS NULL;
