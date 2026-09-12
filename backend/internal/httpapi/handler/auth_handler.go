package handler

import (
	"errors"
	"net/http"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type AuthHandler struct {
	svc          *service.AuthService
	accessTTL    time.Duration
	refreshTTL   time.Duration
	cookieDomain string
	cookieSecure bool
}

func NewAuthHandler(svc *service.AuthService, accessTTL, refreshTTL time.Duration, cookieDomain string, cookieSecure bool) *AuthHandler {
	return &AuthHandler{svc: svc, accessTTL: accessTTL, refreshTTL: refreshTTL, cookieDomain: cookieDomain, cookieSecure: cookieSecure}
}

type loginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type userResponse struct {
	ID       string      `json:"id"`
	Username string      `json:"username"`
	FullName string      `json:"full_name"`
	Role     domain.Role `json:"role"`
	IsActive bool        `json:"is_active"`
}

func toUserResponse(u domain.User) userResponse {
	return userResponse{
		ID:       u.ID,
		Username: u.Username,
		FullName: u.FullName,
		Role:     u.Role,
		IsActive: u.IsActive,
	}
}

func (h *AuthHandler) Login(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	session, err := h.svc.Login(r.Context(), req.Username, req.Password)
	if err != nil {
		h.writeAuthError(w, err)
		return
	}
	h.setSessionCookies(w, session.AccessToken, session.RefreshToken)
	httpjson.Write(w, http.StatusOK, toUserResponse(session.User))
}

func (h *AuthHandler) Refresh(w http.ResponseWriter, r *http.Request) {
	cookie, err := r.Cookie("refresh_token")
	if err != nil {
		httpjson.Error(w, http.StatusUnauthorized, "refresh token yok")
		return
	}
	session, err := h.svc.Refresh(r.Context(), cookie.Value)
	if err != nil {
		h.clearSessionCookies(w)
		h.writeAuthError(w, err)
		return
	}
	h.setSessionCookies(w, session.AccessToken, session.RefreshToken)
	httpjson.Write(w, http.StatusOK, toUserResponse(session.User))
}

func (h *AuthHandler) Logout(w http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie("refresh_token"); err == nil {
		_ = h.svc.Logout(r.Context(), cookie.Value)
	}
	h.clearSessionCookies(w)
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *AuthHandler) Me(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.UserIDFromContext(r.Context())
	if !ok {
		httpjson.Error(w, http.StatusUnauthorized, "oturum bulunamadı")
		return
	}
	user, err := h.svc.Me(r.Context(), userID)
	if err != nil {
		httpjson.Error(w, http.StatusUnauthorized, "oturum geçersiz")
		return
	}
	httpjson.Write(w, http.StatusOK, toUserResponse(*user))
}

func (h *AuthHandler) writeAuthError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrInvalidCredentials):
		httpjson.Error(w, http.StatusUnauthorized, "kullanıcı adı veya şifre hatalı")
	case errors.Is(err, domain.ErrInactiveUser):
		httpjson.Error(w, http.StatusForbidden, "kullanıcı pasif durumda")
	case errors.Is(err, domain.ErrInvalidToken):
		httpjson.Error(w, http.StatusUnauthorized, "oturum geçersiz veya süresi dolmuş")
	default:
		httpjson.Error(w, http.StatusInternalServerError, "beklenmeyen bir hata oluştu")
	}
}

func (h *AuthHandler) setSessionCookies(w http.ResponseWriter, access, refresh string) {
	http.SetCookie(w, h.cookie("access_token", access, h.accessTTL))
	http.SetCookie(w, h.cookie("refresh_token", refresh, h.refreshTTL))
}

func (h *AuthHandler) clearSessionCookies(w http.ResponseWriter) {
	http.SetCookie(w, h.cookie("access_token", "", -time.Hour))
	http.SetCookie(w, h.cookie("refresh_token", "", -time.Hour))
}

func (h *AuthHandler) cookie(name, value string, ttl time.Duration) *http.Cookie {
	return &http.Cookie{
		Name:     name,
		Value:    value,
		Path:     "/",
		Domain:   h.cookieDomain,
		MaxAge:   int(ttl.Seconds()),
		HttpOnly: true,
		Secure:   h.cookieSecure,
		SameSite: http.SameSiteStrictMode,
	}
}
