package service

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/fcm"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Telefona bildirim (migration 0053). Bildirimler bugüne kadar olduğu gibi
// iş akışının KENDİ transaction'ında notifications'a yazılır; telefona
// gönderim ayrı bir döngüdür (Run): commit edilmiş, henüz gönderilmemiş
// satırları alır ve Firebase'e iletir. Böylece hiçbir iş akışı Firebase'i
// beklemez, Firebase çökse de iş akışı başarısız olmaz, ve geri alınan bir
// transaction'ın bildirimi asla telefona düşmez.

// PushSender, fcm.Client'ın gönderim yüzü (testte sahtesi).
type PushSender interface {
	Send(ctx context.Context, m fcm.Message) error
}

const (
	// pushWindow: bundan eski, hiç gönderilmemiş bildirim telefona gitmez
	// (push kapalıyken birikenler sonradan yağmasın).
	pushWindow    = 15 * time.Minute
	pushBatchSize = 50
	pushInterval  = 3 * time.Second
)

var (
	ErrPushTokenInvalid    = errors.New("geçersiz cihaz kaydı")
	ErrPushPlatformInvalid = errors.New("geçersiz platform")
)

type PushService struct {
	q      *sqlc.Queries
	sender PushSender // nil = gönderim kapalı (FCM anahtarı yok); kayıtlar yine tutulur
	now    func() time.Time
}

func NewPushService(q *sqlc.Queries, sender PushSender) *PushService {
	return &PushService{q: q, sender: sender, now: time.Now}
}

// Enabled: sunucu telefona bildirim gönderebiliyor mu.
func (s *PushService) Enabled() bool { return s.sender != nil }

// RegisterDevice: oturumdaki kullanıcının telefonunu kaydeder. Aynı token
// başka kullanıcıdaysa bu kullanıcıya geçer.
func (s *PushService) RegisterDevice(ctx context.Context, organizationID, userID, token, platform, appVersion string) error {
	token = strings.TrimSpace(token)
	if n := utf8.RuneCountInString(token); n < 20 || n > 4096 {
		return ErrPushTokenInvalid
	}
	platform = strings.TrimSpace(platform)
	if platform == "" {
		platform = "android"
	}
	if platform != "android" && platform != "ios" {
		return ErrPushPlatformInvalid
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return domain.ErrNotFound
	}
	_, err = s.q.UpsertPushDevice(ctx, sqlc.UpsertPushDeviceParams{
		OrganizationID: orgID, UserID: uid, Token: token, Platform: platform,
		AppVersion: truncateRunes(strings.TrimSpace(appVersion), 40),
	})
	return err
}

// UnregisterDevice: çıkışta -- yalnızca kendi kaydını siler.
func (s *PushService) UnregisterDevice(ctx context.Context, userID, token string) error {
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return domain.ErrNotFound
	}
	_, err = s.q.DeleteUserPushDevice(ctx, sqlc.DeleteUserPushDeviceParams{Token: strings.TrimSpace(token), UserID: uid})
	return err
}

// Run: ctx iptal edilene kadar her pushInterval'da DispatchOnce.
func (s *PushService) Run(ctx context.Context) {
	if s.sender == nil {
		return
	}
	t := time.NewTicker(pushInterval)
	defer t.Stop()
	for {
		if _, err := s.DispatchOnce(ctx); err != nil && ctx.Err() == nil {
			log.Printf("push: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// DispatchOnce: bekleyen bildirimleri gönderir; gönderilen mesaj sayısını
// döner. En fazla bir kez: satır gönderimden ÖNCE işaretlenir, Firebase
// hatası tekrar denenmez (bildirim zilde yine durur).
func (s *PushService) DispatchOnce(ctx context.Context) (int, error) {
	if s.sender == nil {
		return 0, nil
	}
	cutoff := s.now().Add(-pushWindow)
	ts := pgtype.Timestamptz{Time: cutoff, Valid: true}
	if _, err := s.q.SkipStalePushNotifications(ctx, ts); err != nil {
		return 0, err
	}
	rows, err := s.q.ClaimPendingPushNotifications(ctx, sqlc.ClaimPendingPushNotificationsParams{Since: ts, MaxRows: pushBatchSize})
	if err != nil {
		return 0, err
	}
	sent := 0
	for _, n := range rows {
		tokens, err := s.q.ListPushTokensForUser(ctx, n.UserID)
		if err != nil {
			return sent, err
		}
		for _, tok := range tokens {
			err := s.sender.Send(ctx, pushMessage(n, tok))
			switch {
			case err == nil:
				sent++
			case errors.Is(err, fcm.ErrUnregistered):
				if _, derr := s.q.DeletePushDeviceByToken(ctx, tok); derr != nil {
					log.Printf("push: geçersiz cihaz silinemedi: %v", derr)
				}
			default:
				log.Printf("push: bildirim %s gönderilemedi: %v", n.ID.String(), err)
			}
		}
	}
	return sent, nil
}

func pushMessage(n sqlc.Notification, token string) fcm.Message {
	data := map[string]string{
		"notification_id": n.ID.String(),
		"type":            n.Type,
		"action_target":   n.ActionTarget,
	}
	if n.ProjectID.Valid {
		data["project_id"] = n.ProjectID.String()
	}
	return fcm.Message{
		Token: token, Title: n.Title, Body: n.Body,
		// Gruplanan bildirim büyüyünce telefondaki aynı kartın yerine geçer.
		Tag:  n.ID.String(),
		Data: data,
	}
}

// ---------- Duyurular ----------

const (
	maxAnnouncementTitle = 120
	maxAnnouncementBody  = 500
)

var ErrAnnouncementEmpty = errors.New("duyuru başlığı ve metni zorunludur")

type AnnouncementInput struct {
	Title string
	Body  string
	// OrganizationIDs boşsa tüm aktif/deneme firmaları (yalnızca platform).
	OrganizationIDs []string
	SenderID        string
}

// SendAnnouncement: hedef firmaların her aktif kullanıcısına bildirim
// (gönderen hariç); kaç kişiye gittiğini döner. Telefona gönderim, diğer
// bildirimler gibi Run döngüsünden geçer.
func (s *PushService) SendAnnouncement(ctx context.Context, in AnnouncementInput) (int64, error) {
	title := strings.TrimSpace(in.Title)
	body := strings.TrimSpace(in.Body)
	if title == "" || body == "" {
		return 0, ErrAnnouncementEmpty
	}
	if utf8.RuneCountInString(title) > maxAnnouncementTitle || utf8.RuneCountInString(body) > maxAnnouncementBody {
		return 0, fmt.Errorf("duyuru başlığı en fazla %d, metni en fazla %d karakter olabilir", maxAnnouncementTitle, maxAnnouncementBody)
	}
	orgIDs := make([]pgtype.UUID, 0, len(in.OrganizationIDs))
	for _, id := range in.OrganizationIDs {
		u, err := repository.StringToUUID(id)
		if err != nil {
			return 0, domain.ErrNotFound
		}
		orgIDs = append(orgIDs, u)
	}
	sender, err := repository.StringToUUID(in.SenderID)
	if err != nil {
		return 0, domain.ErrNotFound
	}
	announcementID, err := repository.StringToUUID(uuid.NewString())
	if err != nil {
		return 0, err
	}
	return s.q.CreateAnnouncementNotifications(ctx, sqlc.CreateAnnouncementNotificationsParams{
		Title: title, Body: body, AnnouncementID: announcementID,
		ActionTarget: "/diger/bildirimler", OrganizationIds: orgIDs, SenderID: sender,
	})
}
