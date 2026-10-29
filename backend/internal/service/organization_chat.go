package service

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/storage"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Firma Grubu (migration 0077). Ürün sahibi: "Toplu mesaj kanalı olsun, grup
// mesajı gibi düşün" -- firma başına TEK grup, metin + fotoğraf, telefona
// bildirim. Grubun üyeleri firmanın aktif çalışan hesaplarıdır
// (organization.chat.use); taşeron hesabı grubu hiç görmez.
//
// Okuma uçları izni middleware'de denetler; yazma (gönder/sil) burada da
// kişiyi yeniden okur (requireChatAuthor): yazar adı bildirime girer,
// silmede rol gerekir -- aynı okuma, oturum kapısından bağımsız ikinci bir
// "çalışan mı" kontrolü de olur.

var (
	ErrChatEmpty   = errors.New("Mesaj boş olamaz")
	ErrChatTooLong = fmt.Errorf("Mesaj en fazla %d karakter olabilir", domain.ChatMaxBodyRunes)
	// ErrChatRateLimited: handler 429. Sınır insan için geniş, bir döngü
	// (takılan istemci, betik) için dar: dakikada chatRateLimit mesaj.
	ErrChatRateLimited = errors.New("Çok hızlı mesaj gönderiyorsunuz; biraz bekleyip tekrar deneyin")
	// ErrChatNotMember: yazan kişi grubun üyesi değil (taşeron hesabı, pasif
	// hesap, izni kaldırılmış kişi). Handler 403.
	ErrChatNotMember = errors.New("Firma Grubu'na yalnızca firmanın çalışanları yazabilir")
	// ErrChatDeleteNotAllowed: başkasının mesajını yalnızca Sahip/Yönetici
	// siler. Handler 403 (permission_denied kodu OLMADAN -- istemci yetki
	// listesini tazelemeye kalkmasın, izin değişmedi).
	ErrChatDeleteNotAllowed = errors.New("Yalnızca kendi mesajınızı silebilirsiniz")
	ErrChatInvalidClientID  = errors.New("geçersiz client_id")
	ErrChatInvalidCursor    = errors.New("geçersiz sayfa: before ve after birlikte ya da eksi değerle kullanılamaz")
	ErrChatPhotoType        = errors.New("Yalnızca JPEG, PNG, WebP ya da GIF fotoğraf gönderilebilir")
)

const (
	chatRateLimit   = 20
	chatRateWindow  = time.Minute
	chatDefaultPage = 50
	chatMaxPage     = 100
	// chatPreviewRunes: bildirimde görünen metin parçası.
	chatPreviewRunes = 120
	// chatDeletedOverlap: "bu arada silinenler" sorgusu istemcinin son
	// yoklama zamanından bu kadar geriden başlar -- yoklama, commit'i
	// süren bir silmeyle aynı anda düştüyse silme kaçmasın (istemci aynı
	// silmeyi iki kez almaktan etkilenmez).
	chatDeletedOverlap = time.Minute

	chatTitle              = "Firma Grubu"
	chatGroupedTitleFormat = "Firma Grubu: %s yeni mesaj" // PostgreSQL format(); %s = sayı
	chatGroupedBodyPrefix  = "Son: "
)

// chatPhotoTypes: içerikten tespit edilen türler -> anahtar uzantısı.
// Telefonun gösterebildiği yaygın türler; HEIC vb. istemcide JPEG'e çevrilir.
var chatPhotoTypes = map[string]string{
	"image/jpeg": ".jpg",
	"image/png":  ".png",
	"image/webp": ".webp",
	"image/gif":  ".gif",
}

type OrganizationChatService struct {
	pool  *pgxpool.Pool
	q     *sqlc.Queries
	store storage.Store
	// rateLimit: chatRateWindow içinde kişi başına en çok mesaj (testler
	// SetChatRateLimitForTest ile değiştirir).
	rateLimit int
	now       func() time.Time
}

func NewOrganizationChatService(pool *pgxpool.Pool, q *sqlc.Queries, store storage.Store) *OrganizationChatService {
	return &OrganizationChatService{pool: pool, q: q, store: store, rateLimit: chatRateLimit, now: time.Now}
}

func chatScope(organizationID, userID string) (pgtype.UUID, pgtype.UUID, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return pgtype.UUID{}, pgtype.UUID{}, domain.ErrNotFound
	}
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return pgtype.UUID{}, pgtype.UUID{}, domain.ErrNotFound
	}
	return orgID, uid, nil
}

// ---------- Okuma ----------

type ChatListQuery struct {
	// Before > 0: o numaradan eski sayfa. After != nil: yoklama, o
	// numaradan sonrakiler. İkisi de yoksa en yeni sayfa.
	Before int64
	After  *int64
	Limit  int
	// ChangedSince: yoklamada istemcinin son yanıttaki ServerTime'ı -- o
	// zamandan beri silinen (istemcinin elindeki aralıkta, numara <= After)
	// mesajlar Updated'da döner.
	ChangedSince *time.Time
}

type ChatListResult struct {
	// Messages HER ZAMAN yeniden eskiye (numara azalan) sıralıdır.
	Messages []domain.ChatMessage
	// HasMore: sorgunun yönünde (Before: daha eski, After: daha yeni) daha
	// fazla mesaj var.
	HasMore     bool
	Updated     []domain.ChatMessage
	LastReadSeq int64
	Muted       bool
	// CanModerate: çağıran herkesin mesajını silebilir (Sahip/Yönetici).
	CanModerate bool
	// ServerTime: bir sonraki yoklamanın ChangedSince'i.
	ServerTime time.Time
}

func (s *OrganizationChatService) List(ctx context.Context, organizationID, userID string, in ChatListQuery) (*ChatListResult, error) {
	orgID, uid, err := chatScope(organizationID, userID)
	if err != nil {
		return nil, err
	}
	if in.Before < 0 || (in.After != nil && (*in.After < 0 || in.Before > 0)) {
		return nil, ErrChatInvalidCursor
	}
	limit := in.Limit
	if limit <= 0 || limit > chatMaxPage {
		limit = chatDefaultPage
	}
	// Sorgulardan ÖNCE: bu andan sonra silinen her mesaj bir sonraki
	// yoklamada yakalanır.
	out := &ChatListResult{ServerTime: s.now()}

	if in.After != nil {
		rows, err := s.q.ListChatMessagesAfter(ctx, sqlc.ListChatMessagesAfterParams{
			OrganizationID: orgID, After: *in.After, MaxRows: int32(limit + 1),
		})
		if err != nil {
			return nil, err
		}
		if len(rows) > limit {
			out.HasMore = true
			rows = rows[:limit]
		}
		out.Messages = make([]domain.ChatMessage, len(rows))
		for i, r := range rows {
			out.Messages[len(rows)-1-i] = repository.ToDomainChatMessage(r.OrganizationChatMessage, r.AuthorName)
		}
		if in.ChangedSince != nil && *in.After > 0 {
			changed, err := s.q.ListChatMessagesChangedSince(ctx, sqlc.ListChatMessagesChangedSinceParams{
				OrganizationID: orgID, MaxSeq: *in.After,
				Since: pgtype.Timestamptz{Time: in.ChangedSince.Add(-chatDeletedOverlap), Valid: true},
			})
			if err != nil {
				return nil, err
			}
			for _, r := range changed {
				out.Updated = append(out.Updated, repository.ToDomainChatMessage(r.OrganizationChatMessage, r.AuthorName))
			}
		}
	} else {
		rows, err := s.q.ListChatMessagesBefore(ctx, sqlc.ListChatMessagesBeforeParams{
			OrganizationID: orgID, Before: in.Before, MaxRows: int32(limit + 1),
		})
		if err != nil {
			return nil, err
		}
		if len(rows) > limit {
			out.HasMore = true
			rows = rows[:limit]
		}
		out.Messages = make([]domain.ChatMessage, len(rows))
		for i, r := range rows {
			out.Messages[i] = repository.ToDomainChatMessage(r.OrganizationChatMessage, r.AuthorName)
		}
	}

	state, err := s.memberState(ctx, orgID, uid)
	if err != nil {
		return nil, err
	}
	out.LastReadSeq, out.Muted = state.LastReadSeq, state.Muted
	role, err := s.q.GetUserRoleCode(ctx, sqlc.GetUserRoleCodeParams{ID: uid, OrganizationID: orgID})
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	out.CanModerate = domain.CanModerateChat(role.Code)
	return out, nil
}

// memberState: kişinin grup satırı; yoksa sıfır değer (hiç okumamış,
// sessizde değil).
func (s *OrganizationChatService) memberState(ctx context.Context, orgID, uid pgtype.UUID) (sqlc.OrganizationChatMember, error) {
	st, err := s.q.GetChatMemberState(ctx, sqlc.GetChatMemberStateParams{OrganizationID: orgID, UserID: uid})
	if errors.Is(err, pgx.ErrNoRows) {
		return sqlc.OrganizationChatMember{}, nil
	}
	return st, err
}

// ChatStatus: rozet ve menü için kişinin grup durumu.
type ChatStatus struct {
	UnreadCount int64
	Muted       bool
	LastReadSeq int64
}

func (s *OrganizationChatService) Status(ctx context.Context, organizationID, userID string) (*ChatStatus, error) {
	orgID, uid, err := chatScope(organizationID, userID)
	if err != nil {
		return nil, err
	}
	return s.status(ctx, orgID, uid)
}

func (s *OrganizationChatService) status(ctx context.Context, orgID, uid pgtype.UUID) (*ChatStatus, error) {
	state, err := s.memberState(ctx, orgID, uid)
	if err != nil {
		return nil, err
	}
	n, err := s.q.CountUnreadChatMessages(ctx, sqlc.CountUnreadChatMessagesParams{OrganizationID: orgID, UserID: uid})
	if err != nil {
		return nil, err
	}
	return &ChatStatus{UnreadCount: n, Muted: state.Muted, LastReadSeq: state.LastReadSeq}, nil
}

// MarkRead: kişi grubu `seq` numarasına kadar okudu. Numara firmanın en
// büyük numarasıyla sınırlanır (istemci "sonsuza kadar okudum" diyemez) ve
// geri gitmez. Zildeki Firma Grubu bildirimi, gösterdiği son mesaj okunmuşsa
// kapanır.
func (s *OrganizationChatService) MarkRead(ctx context.Context, organizationID, userID string, seq int64) (*ChatStatus, error) {
	orgID, uid, err := chatScope(organizationID, userID)
	if err != nil {
		return nil, err
	}
	if seq < 0 {
		return nil, ErrChatInvalidCursor
	}
	last, err := s.q.GetChatLastSeq(ctx, orgID)
	if err != nil {
		return nil, err
	}
	if seq > last {
		seq = last
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)
	st, err := txq.MarkChatRead(ctx, sqlc.MarkChatReadParams{OrganizationID: orgID, UserID: uid, LastReadSeq: seq})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound // kişi bu firmanın değil
		}
		return nil, err
	}
	if err := txq.MarkChatNotificationsRead(ctx, sqlc.MarkChatNotificationsReadParams{
		UserID: uid, OrganizationID: orgID, Type: domain.NotificationOrganizationChat, ReadSeq: st.LastReadSeq,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return s.status(ctx, orgID, uid)
}

// SetMuted: "Bildirimleri sessize al". Sessizdeki kişiye bildirim (zil ve
// telefon) gitmez; rozet sayısı yine görünür.
func (s *OrganizationChatService) SetMuted(ctx context.Context, organizationID, userID string, muted bool) (*ChatStatus, error) {
	orgID, uid, err := chatScope(organizationID, userID)
	if err != nil {
		return nil, err
	}
	if _, err := s.q.SetChatMuted(ctx, sqlc.SetChatMutedParams{OrganizationID: orgID, UserID: uid, Muted: muted}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound // kişi bu firmanın değil
		}
		return nil, err
	}
	return s.status(ctx, orgID, uid)
}

// OpenPhoto: fotoğraflı mesajın dosyası. Başka firmanın mesajı, silinmiş ya
// da fotoğrafsız mesaj -- hepsi ErrNotFound (ayrım sızdırılmaz).
func (s *OrganizationChatService) OpenPhoto(ctx context.Context, organizationID, messageID string) (*domain.ChatPhoto, io.ReadCloser, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, nil, domain.ErrNotFound
	}
	mid, err := repository.StringToUUID(messageID)
	if err != nil {
		return nil, nil, domain.ErrNotFound
	}
	row, err := s.q.GetChatMessage(ctx, sqlc.GetChatMessageParams{ID: mid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil, domain.ErrNotFound
		}
		return nil, nil, err
	}
	m := row.OrganizationChatMessage
	if m.DeletedAt.Valid || m.PhotoKey == nil || m.PhotoMime == nil {
		return nil, nil, domain.ErrNotFound
	}
	rc, err := s.store.Open(ctx, *m.PhotoKey)
	if err != nil {
		if errors.Is(err, storage.ErrNotFound) {
			return nil, nil, domain.ErrNotFound
		}
		return nil, nil, wrapStorageErr(err)
	}
	photo := &domain.ChatPhoto{MIMEType: *m.PhotoMime}
	if m.PhotoSize != nil {
		photo.SizeBytes = *m.PhotoSize
	}
	return photo, rc, nil
}

// ---------- Gönderme ----------

type ChatSendInput struct {
	OrganizationID string
	UserID         string
	Text           string
	// ClientID: istemcinin mesaj için ürettiği uuid (isteğe bağlı). Aynı
	// kimlikle ikinci istek ("Tekrar dene", yanıt yolda kaybolmuştu) yeni
	// mesaj yazmaz, ilkini döner.
	ClientID string
	// Yalnızca SendPhoto: fotoğrafın içeriği. Dosya adı kullanılmaz -- tür
	// ve anahtar uzantısı içerikten tespit edilir.
	Photo io.Reader
}

type ChatSendResult struct {
	Message domain.ChatMessage
	// Created=false: aynı ClientID ile daha önce yazılmış mesaj döndü.
	Created bool
}

// Send: metin mesajı.
func (s *OrganizationChatService) Send(ctx context.Context, in ChatSendInput) (*ChatSendResult, error) {
	body := cleanChatText(in.Text)
	if body == "" {
		return nil, ErrChatEmpty
	}
	return s.send(ctx, in, body, false)
}

// SendPhoto: fotoğraf mesajı; metin (alt yazı) isteğe bağlı.
func (s *OrganizationChatService) SendPhoto(ctx context.Context, in ChatSendInput) (*ChatSendResult, error) {
	if in.Photo == nil {
		return nil, ErrEmptyFile
	}
	return s.send(ctx, in, cleanChatText(in.Text), true)
}

func (s *OrganizationChatService) send(ctx context.Context, in ChatSendInput, body string, withPhoto bool) (*ChatSendResult, error) {
	orgID, uid, err := chatScope(in.OrganizationID, in.UserID)
	if err != nil {
		return nil, err
	}
	if utf8.RuneCountInString(body) > domain.ChatMaxBodyRunes {
		return nil, ErrChatTooLong
	}
	var clientID pgtype.UUID
	if strings.TrimSpace(in.ClientID) != "" {
		if clientID, err = repository.StringToUUID(strings.TrimSpace(in.ClientID)); err != nil {
			return nil, ErrChatInvalidClientID
		}
	}
	author, err := requireChatAuthor(ctx, s.q, orgID, uid)
	if err != nil {
		return nil, err
	}
	// Tekrar deneme: fotoğraf ikinci kez diske yazılmadan önce yakalanır
	// (kesin kontrol aşağıda, grup kilidinin altında).
	if existing, ok, err := s.findByClientID(ctx, s.q, orgID, uid, clientID); err != nil || ok {
		return existing, err
	}

	// Fotoğraf transaction'dan ÖNCE yazılır: grup kilidi (NextChatSeq) firma
	// içindeki bütün gönderimleri sıraya sokar, disk yazımı onu tutmasın.
	var photo *storage.Object
	if withPhoto {
		obj, err := s.storePhoto(ctx, orgID.String(), in.Photo)
		if err != nil {
			return nil, err
		}
		photo = &obj
	}
	committed := false
	defer func() {
		if photo != nil && !committed {
			_ = s.store.Delete(ctx, photo.Key)
		}
	}()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	seq, err := txq.NextChatSeq(ctx, orgID)
	if err != nil {
		return nil, err
	}
	if existing, ok, err := s.findByClientID(ctx, txq, orgID, uid, clientID); err != nil || ok {
		return existing, err
	}
	recent, err := txq.CountRecentChatMessagesByAuthor(ctx, sqlc.CountRecentChatMessagesByAuthorParams{
		OrganizationID: orgID, AuthorID: uid, WindowSeconds: int32(chatRateWindow / time.Second),
	})
	if err != nil {
		return nil, err
	}
	if recent >= int64(s.rateLimit) {
		return nil, ErrChatRateLimited
	}

	params := sqlc.CreateChatMessageParams{
		OrganizationID: orgID, Seq: seq, AuthorID: uid, Body: body, ClientID: clientID,
	}
	if photo != nil {
		params.PhotoKey, params.PhotoMime = &photo.Key, &photo.MIMEType
		params.PhotoSize, params.PhotoSha256 = &photo.Size, &photo.SHA256
	}
	row, err := txq.CreateChatMessage(ctx, params)
	if err != nil {
		return nil, err
	}
	// Yazan, kendi mesajına kadar grubu okumuş sayılır (yanıt yazmak
	// okumaktır); kendi mesajı zaten okunmamış sayılmaz.
	if _, err := txq.MarkChatRead(ctx, sqlc.MarkChatReadParams{OrganizationID: orgID, UserID: uid, LastReadSeq: seq}); err != nil {
		return nil, err
	}
	if err := notifyChatMembers(ctx, txq, orgID, author, row); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	committed = true
	return &ChatSendResult{Message: repository.ToDomainChatMessage(row, author.FullName), Created: true}, nil
}

func (s *OrganizationChatService) findByClientID(ctx context.Context, q *sqlc.Queries, orgID, uid, clientID pgtype.UUID) (*ChatSendResult, bool, error) {
	if !clientID.Valid {
		return nil, false, nil
	}
	row, err := q.GetChatMessageByClientID(ctx, sqlc.GetChatMessageByClientIDParams{
		OrganizationID: orgID, AuthorID: uid, ClientID: clientID,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return &ChatSendResult{Message: repository.ToDomainChatMessage(row.OrganizationChatMessage, row.AuthorName)}, true, nil
}

// storePhoto: içerikten tür tespiti (istemcinin beyanına güvenilmez), 25 MB
// sınırı, sunucuda üretilen anahtar. Proje fotoğraflarıyla aynı kurallar
// (bkz. ProjectService.storeUpload); anahtar projesiz: chat/<firma>/<uuid>.
func (s *OrganizationChatService) storePhoto(ctx context.Context, orgID string, r io.Reader) (storage.Object, error) {
	mime, body, n, err := sniffMIME(io.LimitReader(r, MaxUploadBytes+1))
	if err != nil {
		return storage.Object{}, err
	}
	if n == 0 {
		return storage.Object{}, ErrEmptyFile
	}
	ext, ok := chatPhotoTypes[mime]
	if !ok {
		return storage.Object{}, ErrChatPhotoType
	}
	key := "chat/" + orgID + "/" + uuid.NewString() + ext
	obj, err := s.store.Put(ctx, key, body)
	if err != nil {
		return storage.Object{}, wrapStorageErr(err)
	}
	if obj.Size > MaxUploadBytes {
		_ = s.store.Delete(ctx, key)
		return storage.Object{}, ErrFileTooLarge
	}
	obj.MIMEType = mime
	return obj, nil
}

// requireChatAuthor: yazma işlemini yapan kişi grubun üyesi mi -- bu
// firmada, aktif, silinmemiş, taşeron hesabı değil ve organization.chat.use
// izni etkin.
func requireChatAuthor(ctx context.Context, q *sqlc.Queries, orgID, uid pgtype.UUID) (sqlc.GetChatAuthorRow, error) {
	author, err := q.GetChatAuthor(ctx, sqlc.GetChatAuthorParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return author, ErrChatNotMember
		}
		return author, err
	}
	if !author.IsActive || author.Deleted || author.SupplierID.Valid || author.RoleCode == domain.OrgRoleSubcontractor {
		return author, ErrChatNotMember
	}
	perms, err := q.GetUserPermissions(ctx, sqlc.GetUserPermissionsParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		return author, err
	}
	for _, p := range perms {
		if p == domain.PermOrganizationChatUse {
			return author, nil
		}
	}
	return author, ErrChatNotMember
}

// notifyChatMembers: yeni mesajı üyelere bildirir -- yazar, sessize alanlar,
// pasif ve taşeron hesapları hariç (ListChatNotificationRecipients). Kişi
// başına tek okunmamış bildirim: varsa büyür ("Firma Grubu: 3 yeni mesaj",
// "Son: Ahmet: …"), yoksa açılır. Telefonda tek kart (domain.ChatPushTag).
func notifyChatMembers(ctx context.Context, txq *sqlc.Queries, orgID pgtype.UUID, author sqlc.GetChatAuthorRow, msg sqlc.OrganizationChatMessage) error {
	recipients, err := txq.ListChatNotificationRecipients(ctx, sqlc.ListChatNotificationRecipientsParams{
		OrganizationID: orgID, AuthorID: author.ID, PermissionCode: domain.PermOrganizationChatUse,
	})
	if err != nil || len(recipients) == 0 {
		return err
	}
	preview := chatPreview(author.FullName, msg.Body, msg.PhotoKey != nil)
	return txq.UpsertChatNotifications(ctx, sqlc.UpsertChatNotificationsParams{
		OrganizationID: orgID, Type: domain.NotificationOrganizationChat,
		Title: chatTitle, Body: truncateRunes(preview, 500),
		GroupedTitleFormat: chatGroupedTitleFormat, GroupedBody: truncateRunes(chatGroupedBodyPrefix+preview, 500),
		EntityType: domain.NotificationEntityChatMessage, MessageID: msg.ID,
		ActionTarget: domain.ChatActionTarget, RecipientIds: recipients,
	})
}

// chatPreview: bildirimdeki tek satır -- "Ahmet Yılmaz: Beton yarın 8'de",
// fotoğrafta "Ahmet Yılmaz: Fotoğraf" (alt yazı varsa "Fotoğraf · …").
func chatPreview(author, body string, hasPhoto bool) string {
	text := strings.Join(strings.Fields(body), " ")
	if r := []rune(text); len(r) > chatPreviewRunes {
		text = strings.TrimSpace(string(r[:chatPreviewRunes])) + "…"
	}
	switch {
	case hasPhoto && text != "":
		text = "Fotoğraf · " + text
	case hasPhoto:
		text = "Fotoğraf"
	}
	if strings.TrimSpace(author) == "" {
		author = "Bir çalışan"
	}
	return author + ": " + text
}

// cleanChatText: geçersiz UTF-8 ve kontrol karakterleri (satır sonu ve
// sekme hariç) atılır, \r\n -> \n; baş ve sondaki boşluk kırpılır.
// PostgreSQL metinde NUL kabul etmez -- ham hata 500 olarak dönerdi.
func cleanChatText(s string) string {
	s = strings.ToValidUTF8(s, "")
	s = strings.Map(func(r rune) rune {
		switch {
		case r == '\n' || r == '\t':
			return r
		case unicode.IsControl(r):
			return -1
		}
		return r
	}, s)
	return strings.TrimSpace(s)
}

// ---------- Silme ----------

// Delete: mesajı yumuşak siler. Kendi mesajını herkes, başkasınınkini
// Sahip/Yönetici siler. Zaten silinmiş mesaj olduğu gibi döner (iki
// telefondan aynı anda silme hata vermesin). Zildeki bildirimin gövdesi
// "Mesaj silindi" olur.
func (s *OrganizationChatService) Delete(ctx context.Context, organizationID, userID, messageID string) (*domain.ChatMessage, error) {
	orgID, uid, err := chatScope(organizationID, userID)
	if err != nil {
		return nil, err
	}
	mid, err := repository.StringToUUID(messageID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	actor, err := requireChatAuthor(ctx, txq, orgID, uid)
	if err != nil {
		return nil, err
	}
	row, err := txq.GetChatMessage(ctx, sqlc.GetChatMessageParams{ID: mid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	m := row.OrganizationChatMessage
	if !(m.AuthorID.Valid && m.AuthorID == uid) && !domain.CanModerateChat(actor.RoleCode) {
		return nil, ErrChatDeleteNotAllowed
	}
	if m.DeletedAt.Valid {
		out := repository.ToDomainChatMessage(m, row.AuthorName)
		return &out, nil
	}
	deleted, err := txq.SoftDeleteChatMessage(ctx, sqlc.SoftDeleteChatMessageParams{DeletedBy: uid, ID: mid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// Aynı anda başka biri sildi.
			out := repository.ToDomainChatMessage(m, row.AuthorName)
			out.Deleted, out.Body, out.Photo = true, "", nil
			return &out, nil
		}
		return nil, err
	}
	name := row.AuthorName
	if strings.TrimSpace(name) == "" {
		name = "Bir çalışan"
	}
	redacted := name + ": Mesaj silindi"
	if err := txq.RedactChatNotifications(ctx, sqlc.RedactChatNotificationsParams{
		GroupedBody: chatGroupedBodyPrefix + redacted, Body: redacted,
		OrganizationID: orgID, Type: domain.NotificationOrganizationChat, MessageID: mid,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainChatMessage(deleted, row.AuthorName)
	return &out, nil
}
