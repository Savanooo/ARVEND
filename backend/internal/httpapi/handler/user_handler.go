package handler

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type UserHandler struct {
	svc *service.UserService
}

func NewUserHandler(svc *service.UserService) *UserHandler {
	return &UserHandler{svc: svc}
}

func (h *UserHandler) List(w http.ResponseWriter, r *http.Request) {
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	result, err := h.svc.List(r.Context(), orgID, page, limit)
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "kullanıcılar alınamadı")
		return
	}
	users := make([]userResponse, len(result.Users))
	for i, u := range result.Users {
		users[i] = toUserResponse(u)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"users": users, "total": result.Total})
}

func (h *UserHandler) Get(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	user, err := h.svc.Get(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeUserError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toUserResponse(*user))
}

type createUserRequest struct {
	Username string      `json:"username"`
	Password string      `json:"password"`
	FullName string      `json:"full_name"`
	Role     domain.Role `json:"role"`
}

func (h *UserHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req createUserRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	user, err := h.svc.Create(r.Context(), orgID, req.Username, req.Password, req.FullName, req.Role)
	if err != nil {
		h.writeUserError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toUserResponse(*user))
}

type updateUserRequest struct {
	FullName string      `json:"full_name"`
	Role     domain.Role `json:"role"`
	IsActive bool        `json:"is_active"`
}

func (h *UserHandler) Update(w http.ResponseWriter, r *http.Request) {
	var req updateUserRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	user, err := h.svc.Update(r.Context(), chi.URLParam(r, "id"), orgID, req.FullName, req.Role, req.IsActive)
	if err != nil {
		h.writeUserError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toUserResponse(*user))
}

func (h *UserHandler) Deactivate(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	if err := h.svc.Deactivate(r.Context(), chi.URLParam(r, "id"), orgID); err != nil {
		h.writeUserError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

type changeOwnPasswordRequest struct {
	CurrentPassword string `json:"current_password"`
	NewPassword     string `json:"new_password"`
}

func (h *UserHandler) ChangeOwnPassword(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.UserIDFromContext(r.Context())
	if !ok {
		httpjson.Error(w, http.StatusUnauthorized, "oturum bulunamadı")
		return
	}
	var req changeOwnPasswordRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	if err := h.svc.ChangeOwnPassword(r.Context(), userID, orgID, req.CurrentPassword, req.NewPassword); err != nil {
		h.writeUserError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

type resetPasswordRequest struct {
	NewPassword string `json:"new_password"`
}

func (h *UserHandler) AdminResetPassword(w http.ResponseWriter, r *http.Request) {
	var req resetPasswordRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	if err := h.svc.AdminResetPassword(r.Context(), chi.URLParam(r, "id"), orgID, req.NewPassword); err != nil {
		h.writeUserError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *UserHandler) writeUserError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "kullanıcı bulunamadı")
	case errors.Is(err, domain.ErrDuplicateUsername):
		httpjson.Error(w, http.StatusConflict, "bu kullanıcı adı zaten kullanılıyor")
	case errors.Is(err, domain.ErrInvalidCredentials):
		httpjson.Error(w, http.StatusBadRequest, "mevcut şifre hatalı")
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
