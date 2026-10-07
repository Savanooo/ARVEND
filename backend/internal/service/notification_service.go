package service

import (
	"context"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// NotificationService, uygulama-içi bildirim kalıcılığı + okuma +
// alıcı-çözümlemesidir. Create/CreateForUsers yalnızca bir DB INSERT'tir,
// hiçbir harici servise ağ çağrısı yapmaz, bu yüzden çağıranın kendi
// transaction'ına GÜVENLE piyabinebilir (bkz. Faz 1 araştırması: her
// olay zaten bir tx içinde çalışıyor -- bildirim satırı, iş eylemiyle
// ATOMIK olur). Telefona gönderim ayrıdır: PushService.Run commit edilmiş
// her satırı FCM'e iletir (migration 0053, push_service.go) -- burada
// yazılan her bildirim ek bir şey yapmadan telefona da düşer.
type NotificationService struct {
	q *sqlc.Queries
}

func NewNotificationService(q *sqlc.Queries) *NotificationService {
	return &NotificationService{q: q}
}

type CreateNotificationInput struct {
	OrganizationID pgtype.UUID
	UserID         pgtype.UUID
	Type           string
	Title          string
	Body           string
	EntityType     string
	EntityID       pgtype.UUID
	ProjectID      pgtype.UUID
	ActionTarget   string
}

// createNotification, VERİLEN txq üzerinden (çağıranın KENDİ transaction'ı)
// tek bir kullanıcıya bildirim yazar. Paket-seviyesi bir fonksiyondur --
// logProjectEvent/logOfferEvent İLE AYNI desen -- ki ProjectService/
// OfferService/vb. bir NotificationService ÖRNEĞİNE ihtiyaç duymadan,
// KENDİ txq'sını geçerek doğrudan çağırabilsin (struct/constructor
// değişikliği gerektirmez). UserID geçersizse (ör. atanan personelin
// bağlı kullanıcı hesabı yoksa -- bkz. employees.user_id, nullable)
// SESSİZCE atlanır ve nil döner -- "bildirilecek biri yok" bir hata
// DEĞİLDİR, iş eyleminin kendisini asla başarısız kılmamalıdır.
func createNotification(ctx context.Context, txq *sqlc.Queries, in CreateNotificationInput) error {
	if !in.UserID.Valid {
		return nil
	}
	_, err := txq.CreateNotification(ctx, sqlc.CreateNotificationParams{
		OrganizationID: in.OrganizationID,
		UserID:         in.UserID,
		Type:           in.Type,
		Title:          in.Title,
		Body:           in.Body,
		EntityType:     in.EntityType,
		EntityID:       in.EntityID,
		ProjectID:      in.ProjectID,
		ActionTarget:   in.ActionTarget,
	})
	return err
}

// createNotificationsForUsers, AYNI bildirim içeriğini birden çok alıcıya
// yazar (ör. bir projede onay izni olan TÜM kullanıcılara) -- her biri
// kendi okundu/okunmadı durumuna sahip AYRI bir satırdır, paylaşılan bir
// "recipients" alanı İCAT EDİLMEZ.
func createNotificationsForUsers(ctx context.Context, txq *sqlc.Queries, userIDs []pgtype.UUID, in CreateNotificationInput) error {
	for _, uid := range userIDs {
		in.UserID = uid
		if err := createNotification(ctx, txq, in); err != nil {
			return err
		}
	}
	return nil
}

// Teklif/ek iş kararı ve teklifin ilk açılışı (müşteri paylaşım linki):
// bkz. customer_link_notify.go.

// resolveProjectApprovers, BELİRLİ bir projede BELİRLİ bir izin kodunu
// (ör. projects.procurement.approve) tutan kullanıcıları döner --
// org-çapında o izne sahip olanları (ListUsersWithPermission) proje
// erişimiyle (AÇIK üyelik VEYA bypass rolü -- owner/admin/legacy_user,
// bkz. domain.RoleBypassesProjectMembership) KESİŞTİRİR. Kesişim boşsa
// boş dilim döner -- ASLA "herkese bildir" gibi geniş bir varsayılana
// düşmez (bkz. Faz 1 araştırması: PR/SCO/hakediş onayı proje-kapsamlıdır).
func resolveProjectApprovers(ctx context.Context, txq *sqlc.Queries, orgID, projectID pgtype.UUID, permissionCode string) ([]pgtype.UUID, error) {
	holders, err := txq.ListUsersWithPermission(ctx, sqlc.ListUsersWithPermissionParams{OrganizationID: orgID, PermissionCode: permissionCode})
	if err != nil {
		return nil, err
	}
	if len(holders) == 0 {
		return nil, nil
	}
	members, err := txq.ListProjectUsersDetailed(ctx, sqlc.ListProjectUsersDetailedParams{ProjectID: projectID, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	memberSet := make(map[string]bool, len(members))
	for _, m := range members {
		memberSet[m.UserID.String()] = true
	}
	var out []pgtype.UUID
	for _, h := range holders {
		if domain.RoleBypassesProjectMembership(h.OrganizationRoleCode) || memberSet[h.ID.String()] {
			out = append(out, h.ID)
		}
	}
	return out, nil
}

// ---------- Okuma tarafı (HTTP handler için) ----------

type NotificationListResult struct {
	Notifications []domain.Notification
	Total         int64
}

func (s *NotificationService) List(ctx context.Context, userID, organizationID string, page, limit int) (*NotificationListResult, error) {
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if limit <= 0 || limit > 100 {
		limit = 30
	}
	if page <= 0 {
		page = 1
	}
	rows, err := s.q.ListNotificationsForUser(ctx, sqlc.ListNotificationsForUserParams{
		UserID: uid, OrganizationID: orgID, Limit: int32(limit), Offset: int32((page - 1) * limit),
	})
	if err != nil {
		return nil, err
	}
	total, err := s.q.CountNotificationsForUser(ctx, sqlc.CountNotificationsForUserParams{UserID: uid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.Notification, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainNotification(r)
	}
	return &NotificationListResult{Notifications: out, Total: total}, nil
}

func (s *NotificationService) UnreadCount(ctx context.Context, userID, organizationID string) (int64, error) {
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return 0, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return 0, domain.ErrNotFound
	}
	return s.q.CountUnreadNotifications(ctx, sqlc.CountUnreadNotificationsParams{UserID: uid, OrganizationID: orgID})
}

// MarkRead, verilen bildirimi okundu işaretler. Bildirim yoksa VEYA başka
// bir kullanıcıya aitse VEYA zaten okunmuşsa -- HER ÜÇ durumda da
// SESSİZCE başarılı döner (0 satır etkilenmiş olsa bile hata YOK) --
// bir bildirim ID'sinin var olup olmadığını veya kime ait olduğunu
// dışarıya SIZDIRMAZ (bkz. dosya/fotoğraf modülünün AYNI "yok/yasak
// ayrımı sızdırma" güvenlik ilkesi).
func (s *NotificationService) MarkRead(ctx context.Context, id, userID, organizationID string) error {
	nid, err := repository.StringToUUID(id)
	if err != nil {
		return nil
	}
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	_, err = s.q.MarkNotificationRead(ctx, sqlc.MarkNotificationReadParams{ID: nid, UserID: uid, OrganizationID: orgID})
	return err
}

func (s *NotificationService) MarkAllRead(ctx context.Context, userID, organizationID string) error {
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	_, err = s.q.MarkAllNotificationsRead(ctx, sqlc.MarkAllNotificationsReadParams{UserID: uid, OrganizationID: orgID})
	return err
}
