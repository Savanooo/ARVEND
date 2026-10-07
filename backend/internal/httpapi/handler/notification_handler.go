package handler

import (
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type NotificationHandler struct {
	svc *service.NotificationService
}

func NewNotificationHandler(svc *service.NotificationService) *NotificationHandler {
	return &NotificationHandler{svc: svc}
}

type notificationResponse struct {
	ID           string  `json:"id"`
	Type         string  `json:"type"`
	Title        string  `json:"title"`
	Body         string  `json:"body"`
	EntityType   string  `json:"entity_type"`
	EntityID     *string `json:"entity_id"`
	ProjectID    *string `json:"project_id"`
	ActionTarget string  `json:"action_target"`
	ReadAt       *string `json:"read_at"`
	CreatedAt    string  `json:"created_at"`
}

func toNotificationResponse(n domain.Notification) notificationResponse {
	resp := notificationResponse{
		ID: n.ID, Type: n.Type, Title: n.Title, Body: n.Body,
		EntityType: n.EntityType, EntityID: n.EntityID, ProjectID: n.ProjectID,
		ActionTarget: n.ActionTarget, CreatedAt: n.CreatedAt.Format(time.RFC3339),
	}
	if n.ReadAt != nil {
		s := n.ReadAt.Format(time.RFC3339)
		resp.ReadAt = &s
	}
	return resp
}

// List, çağıranın KENDİ bildirimlerini döner -- user_id her zaman
// authenticated context'ten gelir, istekten ASLA alınmaz (bkz.
// NotificationService.List, organization_id+user_id ikisiyle birden
// scoped).
func (h *NotificationHandler) List(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	result, err := h.svc.List(r.Context(), userID, orgID, page, limit)
	if err != nil {
		h.writeError(w, err)
		return
	}
	notifications := make([]notificationResponse, len(result.Notifications))
	for i, n := range result.Notifications {
		notifications[i] = toNotificationResponse(n)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"notifications": notifications, "total": result.Total})
}

func (h *NotificationHandler) UnreadCount(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	count, err := h.svc.UnreadCount(r.Context(), userID, orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"unread_count": count})
}

func (h *NotificationHandler) MarkRead(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.MarkRead(r.Context(), chi.URLParam(r, "id"), userID, orgID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"ok": true})
}

func (h *NotificationHandler) MarkAllRead(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.MarkAllRead(r.Context(), userID, orgID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"ok": true})
}

func (h *NotificationHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "kayıt bulunamadı")
	case isInternalError(err), isUnexpectedServiceError(err):
		// Bu uçların servis hataları yalnızca ErrNotFound ya da veritabanı
		// hatasıdır -- ham DB metni 400 ile istemciye gitmesin.
		writeInternalError(w, err)
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
