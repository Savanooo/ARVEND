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

// FeedbackHandler: öneri gönderme (her kullanıcı) ve Super Admin listesi.
type FeedbackHandler struct {
	svc *service.FeedbackService
}

func NewFeedbackHandler(svc *service.FeedbackService) *FeedbackHandler {
	return &FeedbackHandler{svc: svc}
}

type feedbackRequest struct {
	Category   string `json:"category"`
	Body       string `json:"body"`
	AppVersion string `json:"app_version"`
}

// Submit, POST /api/v1/feedback.
func (h *FeedbackHandler) Submit(w http.ResponseWriter, r *http.Request) {
	var req feedbackRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.Submit(r.Context(), orgID, userID, req.Category, req.Body, req.AppVersion); err != nil {
		switch {
		case errors.Is(err, service.ErrFeedbackEmpty), errors.Is(err, service.ErrFeedbackTooLong), errors.Is(err, service.ErrFeedbackCategory):
			httpjson.Error(w, http.StatusBadRequest, err.Error())
		default:
			httpjson.Error(w, http.StatusInternalServerError, "öneri kaydedilemedi")
		}
		return
	}
	httpjson.Write(w, http.StatusCreated, map[string]bool{"ok": true})
}

type feedbackResponse struct {
	ID               string  `json:"id"`
	OrganizationID   string  `json:"organization_id"`
	OrganizationName string  `json:"organization_name"`
	UserName         string  `json:"user_name"`
	Category         string  `json:"category"`
	Body             string  `json:"body"`
	AppVersion       string  `json:"app_version"`
	ReadAt           *string `json:"read_at"`
	CreatedAt        string  `json:"created_at"`
}

// List, GET /api/v1/platform/feedback?unread=1&page=&limit= (Super Admin).
func (h *FeedbackHandler) List(w http.ResponseWriter, r *http.Request) {
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	res, err := h.svc.List(r.Context(), r.URL.Query().Get("unread") == "1", page, limit)
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "öneriler okunamadı")
		return
	}
	out := make([]feedbackResponse, len(res.Messages))
	for i, m := range res.Messages {
		out[i] = feedbackResponse{
			ID: m.ID, OrganizationID: m.OrganizationID, OrganizationName: m.OrganizationName, UserName: m.UserName,
			Category: m.Category, Body: m.Body, AppVersion: m.AppVersion, CreatedAt: m.CreatedAt.Format(time.RFC3339),
		}
		if m.ReadAt != nil {
			s := m.ReadAt.Format(time.RFC3339)
			out[i].ReadAt = &s
		}
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"messages": out, "total": res.Total, "unread": res.Unread})
}

// MarkRead, POST /api/v1/platform/feedback/{id}/read (Super Admin).
func (h *FeedbackHandler) MarkRead(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.MarkRead(r.Context(), chi.URLParam(r, "id")); err != nil {
		if errors.Is(err, domain.ErrNotFound) {
			httpjson.Error(w, http.StatusNotFound, "kayıt bulunamadı")
			return
		}
		httpjson.Error(w, http.StatusInternalServerError, "işaretlenemedi")
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}
