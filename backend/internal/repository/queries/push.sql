-- name: UpsertPushDevice :one
-- Aynı token başka bir kullanıcıya geçebilir (telefonda hesap değişti).
INSERT INTO push_devices (organization_id, user_id, token, platform, app_version)
VALUES ($1, $2, $3, $4, $5)
ON CONFLICT (token) DO UPDATE
SET organization_id = EXCLUDED.organization_id,
    user_id         = EXCLUDED.user_id,
    platform        = EXCLUDED.platform,
    app_version     = EXCLUDED.app_version,
    last_seen_at    = now()
RETURNING *;

-- name: DeleteUserPushDevice :execrows
DELETE FROM push_devices WHERE token = $1 AND user_id = $2;

-- name: DeletePushDeviceByToken :execrows
DELETE FROM push_devices WHERE token = $1;

-- name: ListPushTokensForUser :many
SELECT token FROM push_devices WHERE user_id = $1 ORDER BY last_seen_at DESC;

-- name: ClaimPendingPushNotifications :many
-- Gönderilecek bildirimleri alır ve aynı anda işaretler (iki gönderici
-- aynı satırı almasın). En fazla bir kez gönderim: telefona ulaşmadıysa
-- bildirim zilde yine durur.
UPDATE notifications SET pushed_at = now()
WHERE id IN (
    SELECT n.id FROM notifications n
    WHERE n.pushed_at IS NULL AND n.created_at > sqlc.arg(since)::timestamptz
    ORDER BY n.created_at
    LIMIT sqlc.arg(max_rows)::int
    FOR UPDATE SKIP LOCKED
)
RETURNING *;

-- name: SkipStalePushNotifications :execrows
-- Push kapalıyken biriken eski bildirimler telefona sonradan yağmasın.
UPDATE notifications SET pushed_at = now()
WHERE pushed_at IS NULL AND created_at <= sqlc.arg(before)::timestamptz;
