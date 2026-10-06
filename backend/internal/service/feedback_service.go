package service

import (
	"context"
	"errors"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Öneri / görüş (migration 0054): firmaların kullanıcılarından platform
// ekibine. Firma yöneticisi bu kayıtları görmez -- çalışan, yöneticisi
// hakkındaki bir şikâyeti de rahatça yazabilsin.

var (
	ErrFeedbackEmpty    = errors.New("öneri metni boş olamaz")
	ErrFeedbackTooLong  = errors.New("öneri en fazla 2000 karakter olabilir")
	ErrFeedbackCategory = errors.New("geçersiz öneri türü")
)

var feedbackCategories = map[string]bool{"oneri": true, "hata": true, "sikayet": true, "diger": true}

type FeedbackMessage struct {
	ID               string
	OrganizationID   string
	OrganizationName string
	UserName         string
	Category         string
	Body             string
	AppVersion       string
	ReadAt           *time.Time
	CreatedAt        time.Time
}

type FeedbackService struct{ q *sqlc.Queries }

func NewFeedbackService(q *sqlc.Queries) *FeedbackService { return &FeedbackService{q: q} }

// Submit: oturumdaki kullanıcının önerisi. Yazanın adı o anki addır.
func (s *FeedbackService) Submit(ctx context.Context, organizationID, userID, category, body, appVersion string) error {
	body = strings.TrimSpace(body)
	if body == "" {
		return ErrFeedbackEmpty
	}
	if utf8.RuneCountInString(body) > 2000 {
		return ErrFeedbackTooLong
	}
	category = strings.TrimSpace(category)
	if category == "" {
		category = "oneri"
	}
	if !feedbackCategories[category] {
		return ErrFeedbackCategory
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	uid := actorUUID(userID)
	name := ""
	if uid.Valid {
		if u, err := s.q.GetUserByID(ctx, uid); err == nil {
			name = u.FullName
		}
	}
	_, err = s.q.CreateFeedbackMessage(ctx, sqlc.CreateFeedbackMessageParams{
		OrganizationID: orgID, UserID: uid, UserName: name, Category: category, Body: body,
		AppVersion: truncateRunes(strings.TrimSpace(appVersion), 40),
	})
	return err
}

type FeedbackList struct {
	Messages []FeedbackMessage
	Total    int64
	Unread   int64
}

// List: Super Admin listesi, en yeni önce.
func (s *FeedbackService) List(ctx context.Context, onlyUnread bool, page, limit int) (*FeedbackList, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	if page < 1 {
		page = 1
	}
	rows, err := s.q.ListFeedbackMessages(ctx, sqlc.ListFeedbackMessagesParams{
		OnlyUnread: onlyUnread, MaxRows: int32(limit), SkipRows: int32((page - 1) * limit),
	})
	if err != nil {
		return nil, err
	}
	counts, err := s.q.CountFeedbackMessages(ctx)
	if err != nil {
		return nil, err
	}
	out := &FeedbackList{Messages: make([]FeedbackMessage, len(rows)), Total: counts.Total, Unread: counts.Unread}
	for i, r := range rows {
		m := FeedbackMessage{
			ID: r.ID.String(), OrganizationID: r.OrganizationID.String(), OrganizationName: r.OrganizationName,
			UserName: r.UserName, Category: r.Category, Body: r.Body, AppVersion: r.AppVersion, CreatedAt: r.CreatedAt.Time,
		}
		if r.ReadAt.Valid {
			t := r.ReadAt.Time
			m.ReadAt = &t
		}
		out.Messages[i] = m
	}
	return out, nil
}

// MarkRead: tekrarlanabilir; zaten okunmuşsa bir şey yapmaz.
func (s *FeedbackService) MarkRead(ctx context.Context, id string) error {
	fid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	_, err = s.q.MarkFeedbackMessageRead(ctx, fid)
	return err
}
