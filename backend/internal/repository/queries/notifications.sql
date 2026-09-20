-- name: CreateNotification :one
INSERT INTO notifications (organization_id, user_id, type, title, body, entity_type, entity_id, project_id, action_target)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
RETURNING *;

-- name: ListNotificationsForUser :many
SELECT * FROM notifications
WHERE user_id = $1 AND organization_id = $2
ORDER BY created_at DESC
LIMIT $3 OFFSET $4;

-- name: CountNotificationsForUser :one
SELECT count(*) FROM notifications WHERE user_id = $1 AND organization_id = $2;

-- name: CountUnreadNotifications :one
SELECT count(*) FROM notifications WHERE user_id = $1 AND organization_id = $2 AND read_at IS NULL;

-- name: MarkNotificationRead :execrows
UPDATE notifications SET read_at = now()
WHERE id = $1 AND user_id = $2 AND organization_id = $3 AND read_at IS NULL;

-- name: MarkAllNotificationsRead :execrows
UPDATE notifications SET read_at = now()
WHERE user_id = $1 AND organization_id = $2 AND read_at IS NULL;

-- name: ListUsersWithPermission :many
-- Bir izin kodunu tutan kullanıcıların TERS-arama'sı (permission_code ->
-- []user) -- bu yönde, bu repoda ÖNCEDEN yoktu (bkz. Faz 1 araştırması:
-- tüm mevcut izin sorguları user -> []permission yönünde). Yalnızca aktif
-- kullanıcılar döner. Proje üyeliği kesişimi BURADA yapılmaz -- proje
-- kapsamlı bir izin için çağıran (notification_service.go), bu sonucu
-- ayrıca `ListProjectUsersDetailed`/bypass-rol kümesiyle kesiştirir
-- (N+1 yerine 2 sorgu + Go'da küme kesişimi).
SELECT u.id, u.organization_id, orole.code AS organization_role_code
FROM users u
JOIN organization_roles orole ON orole.id = u.organization_role_id
JOIN role_permissions rp ON rp.organization_role_id = orole.id
WHERE u.organization_id = $1 AND rp.permission_code = $2 AND u.is_active = true;
