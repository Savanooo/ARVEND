-- Telefona bildirim (FCM). Sahada 2026-10: "telefona neden bildirim
-- düşmüyor", "duyuru atayım müşterilerim görsün".
--
-- push_devices: bir telefonun Firebase kaydı (token) -> o an oturum açmış
-- kullanıcı. Token benzersizdir: aynı telefonda başka biri oturum açınca
-- satır o kişiye geçer (eski kullanıcıya bildirim gitmez). Çıkışta silinir;
-- Firebase "artık geçersiz" derse gönderici siler.
CREATE TABLE push_devices (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token           text NOT NULL UNIQUE CHECK (char_length(token) BETWEEN 20 AND 4096),
    platform        varchar(20) NOT NULL DEFAULT 'android' CHECK (platform IN ('android', 'ios')),
    app_version     varchar(40) NOT NULL DEFAULT '',
    created_at      timestamptz NOT NULL DEFAULT now(),
    last_seen_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_push_devices_user ON push_devices (user_id);

-- notifications.pushed_at: telefona gönderildi (ya da gönderilmeyecek)
-- işareti. Gönderici NULL olanları sırayla alır; gruplanan bildirim
-- büyüyünce (BumpGroupedNotification) yeniden NULL olur ve telefondaki
-- aynı bildirimin yerine yenisi düşer.
--
-- Mevcut bildirimler gönderilmiş sayılır: push açıldığı gün geçmişteki her
-- bildirim telefona yağmasın.
ALTER TABLE notifications ADD COLUMN pushed_at timestamptz;
UPDATE notifications SET pushed_at = created_at;

CREATE INDEX idx_notifications_push_pending ON notifications (created_at) WHERE pushed_at IS NULL;
