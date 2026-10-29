-- Firma Grubu (migration 0077). Her sorgu organization_id ile kapsanır:
-- grup firmanın kendisidir, başka firmanın mesajına kimlikle bile ulaşılmaz.

-- name: NextChatSeq :one
-- Firmanın sıradaki mesaj numarası. Grup satırının kilidi transaction
-- sonuna kadar tutulur: aynı firmada eşzamanlı iki gönderim sırayla commit
-- edilir, numara sırası = commit sırası (after=seq yoklaması arada commit
-- edilen mesajı atlamaz). Gönderim geri alınırsa sayaç da geri alınır.
INSERT INTO organization_chats (organization_id, last_seq, last_message_at)
VALUES ($1, 1, now())
ON CONFLICT (organization_id) DO UPDATE
SET last_seq = organization_chats.last_seq + 1, last_message_at = now()
RETURNING last_seq;

-- name: GetChatLastSeq :one
-- Firmada şimdiye kadar verilmiş en büyük mesaj numarası (grup yoksa 0).
SELECT COALESCE((SELECT last_seq FROM organization_chats WHERE organization_id = $1), 0)::bigint AS last_seq;

-- name: GetChatAuthor :one
-- Yazma işlemlerinin (gönder/sil) kişi okuması: aynı firmada mı, aktif mi,
-- taşeron hesabı mı, rolü ne (Sahip/Yönetici herkesin mesajını siler) ve
-- bildirimde görünecek adı.
SELECT u.id, u.full_name, u.is_active, (u.deleted_at IS NOT NULL)::boolean AS deleted,
       u.supplier_id, COALESCE(orole.code, '')::text AS role_code
FROM users u
LEFT JOIN organization_roles orole ON orole.id = u.organization_role_id
WHERE u.id = $1 AND u.organization_id = $2;

-- name: GetChatMessageByClientID :one
SELECT sqlc.embed(m), COALESCE(u.full_name, '')::text AS author_name
FROM organization_chat_messages m
LEFT JOIN users u ON u.id = m.author_id
WHERE m.organization_id = $1 AND m.author_id = $2 AND m.client_id = $3;

-- name: CountRecentChatMessagesByAuthor :one
-- Gönderim hızı sınırı: yazarın bu firmada son `window_seconds` içindeki
-- mesajları (silinenler de sayılır -- gönder/sil döngüsü sınırı aşmasın).
SELECT count(*) FROM organization_chat_messages
WHERE organization_id = sqlc.arg(organization_id) AND author_id = sqlc.arg(author_id)
  AND created_at > now() - make_interval(secs => sqlc.arg(window_seconds)::int);

-- name: CreateChatMessage :one
INSERT INTO organization_chat_messages (
    organization_id, seq, author_id, body, client_id, photo_key, photo_mime, photo_size, photo_sha256
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
RETURNING *;

-- name: GetChatMessage :one
SELECT sqlc.embed(m), COALESCE(u.full_name, '')::text AS author_name
FROM organization_chat_messages m
LEFT JOIN users u ON u.id = m.author_id
WHERE m.id = $1 AND m.organization_id = $2;

-- name: ListChatMessagesBefore :many
-- Yeniden eskiye bir sayfa: before = 0 en yeni sayfa, değilse o numaradan
-- eskiler. Silinen mesajlar da döner (yerinde "Mesaj silindi" görünür);
-- metni/fotoğrafı servis boşaltır.
SELECT sqlc.embed(m), COALESCE(u.full_name, '')::text AS author_name
FROM organization_chat_messages m
LEFT JOIN users u ON u.id = m.author_id
WHERE m.organization_id = sqlc.arg(organization_id)
  AND (sqlc.arg(before)::bigint = 0 OR m.seq < sqlc.arg(before)::bigint)
ORDER BY m.seq DESC
LIMIT sqlc.arg(max_rows)::int;

-- name: ListChatMessagesAfter :many
-- Yoklama: `after` numarasından sonraki mesajlar, eskiden yeniye (sayfa
-- dolarsa istemci kalanını en büyük numarayla yeniden ister).
SELECT sqlc.embed(m), COALESCE(u.full_name, '')::text AS author_name
FROM organization_chat_messages m
LEFT JOIN users u ON u.id = m.author_id
WHERE m.organization_id = sqlc.arg(organization_id) AND m.seq > sqlc.arg(after)::bigint
ORDER BY m.seq ASC
LIMIT sqlc.arg(max_rows)::int;

-- name: ListChatMessagesChangedSince :many
-- Yoklamada, istemcinin elindeki aralıkta sonradan silinen mesajlar: silme
-- "Mesaj silindi" olarak diğer telefonlara da düşsün. `since` istemcinin
-- son yoklamasının sunucu zamanıdır.
SELECT sqlc.embed(m), COALESCE(u.full_name, '')::text AS author_name
FROM organization_chat_messages m
LEFT JOIN users u ON u.id = m.author_id
WHERE m.organization_id = sqlc.arg(organization_id) AND m.deleted_at > sqlc.arg(since)::timestamptz
  AND m.seq <= sqlc.arg(max_seq)::bigint
ORDER BY m.seq ASC
LIMIT 200;

-- name: SoftDeleteChatMessage :one
UPDATE organization_chat_messages SET deleted_at = now(), deleted_by = sqlc.arg(deleted_by)
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id) AND deleted_at IS NULL
RETURNING *;

-- name: GetChatMemberState :one
SELECT * FROM organization_chat_members WHERE organization_id = $1 AND user_id = $2;

-- name: MarkChatRead :one
-- Okuma yalnızca ileri gider (eski bir istemcinin geç gelen isteği geri
-- almasın); numara çağıran tarafından firmanın en büyük numarasıyla
-- sınırlanır. Kişi bu firmanın değilse satır açılmaz (ErrNoRows): başka
-- firmanın grubuna durum satırı bağlanamaz.
INSERT INTO organization_chat_members (organization_id, user_id, last_read_seq, last_read_at)
SELECT u.organization_id, u.id, sqlc.arg(last_read_seq)::bigint, now()
FROM users u WHERE u.id = sqlc.arg(user_id) AND u.organization_id = sqlc.arg(organization_id)
ON CONFLICT (organization_id, user_id) DO UPDATE
SET last_read_seq = GREATEST(organization_chat_members.last_read_seq, EXCLUDED.last_read_seq),
    last_read_at  = now(),
    updated_at    = now()
RETURNING *;

-- name: SetChatMuted :one
-- MarkChatRead ile aynı firma kuralı.
INSERT INTO organization_chat_members (organization_id, user_id, muted)
SELECT u.organization_id, u.id, sqlc.arg(muted)::boolean
FROM users u WHERE u.id = sqlc.arg(user_id) AND u.organization_id = sqlc.arg(organization_id)
ON CONFLICT (organization_id, user_id) DO UPDATE
SET muted = EXCLUDED.muted, updated_at = now()
RETURNING *;

-- name: CountUnreadChatMessages :one
-- Rozet sayısı: okunan numaradan sonraki, başkasının yazdığı, silinmemiş
-- mesajlar. Hesabı açılmadan önceki geçmiş sayılmaz (yeni gelen çalışana
-- binlerce "okunmamış" düşmesin; geçmişi yine okuyabilir). 1000'de kesilir
-- -- rozet "99+" der, sayım her açılışta tüm geçmişi taramasın.
SELECT count(*) FROM (
    SELECT 1 FROM organization_chat_messages m
    WHERE m.organization_id = sqlc.arg(organization_id)
      AND m.deleted_at IS NULL
      AND m.author_id IS DISTINCT FROM sqlc.arg(user_id)::uuid
      AND m.seq > COALESCE((SELECT cm.last_read_seq FROM organization_chat_members cm
                            WHERE cm.organization_id = sqlc.arg(organization_id) AND cm.user_id = sqlc.arg(user_id)::uuid), 0)
      AND m.created_at >= (SELECT u.created_at FROM users u WHERE u.id = sqlc.arg(user_id)::uuid)
    LIMIT 1000
) unread;

-- name: ListChatNotificationRecipients :many
-- Yeni mesajın bildirileceği kişiler: firmanın aktif, silinmemiş çalışan
-- hesapları -- yazar, sessize alanlar ve taşeron hesapları (supplier_id)
-- hariç -- ve organization.chat.use izni ETKİN olanlar (kural
-- GetUserPermissions ile aynı: Sahip her zaman; diğerleri rolden gelen izin
-- kişiye özel revoke ile düşer, kişiye özel grant ekler).
SELECT u.id
FROM users u
JOIN organization_roles orole ON orole.id = u.organization_role_id
WHERE u.organization_id = sqlc.arg(organization_id)
  AND u.is_active AND u.deleted_at IS NULL AND u.supplier_id IS NULL
  AND orole.code <> 'subcontractor'
  AND u.id <> sqlc.arg(author_id)::uuid
  AND NOT EXISTS (SELECT 1 FROM organization_chat_members cm
                  WHERE cm.organization_id = u.organization_id AND cm.user_id = u.id AND cm.muted)
  AND (
        orole.code = 'owner'
     OR (EXISTS (SELECT 1 FROM role_permissions rp
                 WHERE rp.organization_role_id = orole.id AND rp.permission_code = sqlc.arg(permission_code)::text)
         AND NOT EXISTS (SELECT 1 FROM user_permission_overrides o
                         WHERE o.user_id = u.id AND o.permission_code = sqlc.arg(permission_code)::text AND o.effect = 'revoke'))
     OR EXISTS (SELECT 1 FROM user_permission_overrides o
                WHERE o.user_id = u.id AND o.permission_code = sqlc.arg(permission_code)::text AND o.effect = 'grant')
  )
ORDER BY u.id;

-- name: UpsertChatNotifications :exec
-- Gruplu bildirim, alıcıların hepsi için TEK ifadede: okunmamış bir Firma
-- Grubu bildirimi olan kişide o satır büyür ("Firma Grubu: 3 yeni mesaj",
-- gövde son mesaj, en üste çıkar, telefona yeniden gider -- aynı etiketle
-- telefondakinin yerine düşer); olmayana yeni satır açılır. Zaman penceresi
-- YOK: kişi okuyana kadar bütün mesajlar tek bildirimde toplanır. Grup
-- kilidi (NextChatSeq) altında çalıştığı için kişi başına iki okunmamış
-- satır oluşmaz.
WITH bumped AS (
    UPDATE notifications n
    SET group_count = n.group_count + 1,
        title       = format(sqlc.arg(grouped_title_format)::text, n.group_count + 1),
        body        = sqlc.arg(grouped_body)::text,
        entity_id   = sqlc.arg(message_id)::uuid,
        created_at  = now(),
        pushed_at   = NULL
    WHERE n.organization_id = sqlc.arg(organization_id)::uuid
      AND n.type = sqlc.arg(type)::text
      AND n.read_at IS NULL
      AND n.user_id = ANY(sqlc.arg(recipient_ids)::uuid[])
    RETURNING n.user_id
)
INSERT INTO notifications (organization_id, user_id, type, title, body, entity_type, entity_id, action_target)
SELECT sqlc.arg(organization_id)::uuid, r.uid, sqlc.arg(type)::text, sqlc.arg(title)::text, sqlc.arg(body)::text,
       sqlc.arg(entity_type)::text, sqlc.arg(message_id)::uuid, sqlc.arg(action_target)::text
FROM unnest(sqlc.arg(recipient_ids)::uuid[]) AS r(uid)
WHERE NOT EXISTS (SELECT 1 FROM bumped b WHERE b.user_id = r.uid);

-- name: MarkChatNotificationsRead :exec
-- Kişi grubu okudu: zildeki Firma Grubu bildirimi de okundu -- ama yalnızca
-- bildirimin gösterdiği son mesaj (entity_id, gruplamada her yeni mesajla
-- güncellenir) okunan numaraya kadarsa. Okuma isteği yoldayken gelen yeni
-- mesajın bildirimi görülmeden kapanmasın.
UPDATE notifications n SET read_at = now()
WHERE n.user_id = sqlc.arg(user_id) AND n.organization_id = sqlc.arg(organization_id)
  AND n.type = sqlc.arg(type) AND n.read_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM organization_chat_messages m
                  WHERE m.id = n.entity_id AND m.seq > sqlc.arg(read_seq)::bigint);

-- name: RedactChatNotifications :exec
-- Silinen mesaj zildeki bildirimin gövdesinde kalmasın ("Son: Ahmet: …"
-- yerine "Ahmet: Mesaj silindi"). Telefona yeniden gönderilmez.
UPDATE notifications
SET body = CASE WHEN group_count > 1 THEN sqlc.arg(grouped_body)::text ELSE sqlc.arg(body)::text END
WHERE organization_id = sqlc.arg(organization_id) AND type = sqlc.arg(type) AND entity_id = sqlc.arg(message_id);
