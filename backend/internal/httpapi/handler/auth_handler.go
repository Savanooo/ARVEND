package handler

import (
	"context"
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
	authzSvc     *service.AuthorizationService
	accessTTL    time.Duration
	refreshTTL   time.Duration
	cookieDomain string
	cookieSecure bool
}

func NewAuthHandler(svc *service.AuthService, authzSvc *service.AuthorizationService, accessTTL, refreshTTL time.Duration, cookieDomain string, cookieSecure bool) *AuthHandler {
	return &AuthHandler{svc: svc, authzSvc: authzSvc, accessTTL: accessTTL, refreshTTL: refreshTTL, cookieDomain: cookieDomain, cookieSecure: cookieSecure}
}

type loginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type userResponse struct {
	ID             string      `json:"id"`
	OrganizationID *string     `json:"organization_id"`
	Username       string      `json:"username"`
	FullName       string      `json:"full_name"`
	Role           domain.Role `json:"role"`
	IsActive       bool        `json:"is_active"`
	// OrganizationName, web/mobil'in sidebar/topbar'da HARDCODED "Arvend
	// Yapı" göstermek yerine gerçek firma adını göstermesi içindir --
	// birden fazla organizasyon var olduğu andan (bu faz) itibaren tek-
	// kiracılı varsayım artık YANLIŞ. Super Admin oturumlarında (organizasyonu
	// yok) boş string döner.
	OrganizationName   string `json:"organization_name"`
	MustChangePassword bool   `json:"must_change_password"`
	// OnboardingCompleted/OnboardingStep, Super Admin oturumlarında
	// (Organization nil) her zaman true/"completed" döner -- onboarding
	// platform seviyesi hesaplara uygulanmaz, web/mobil route guard'ları bu
	// varsayılanla sorgusuz çalışır.
	OnboardingCompleted bool   `json:"onboarding_completed"`
	OnboardingStep      string `json:"onboarding_step"`
	// OrganizationRoleCode/-Name, RBAC/Project Membership sprint'inin ince-
	// taneli organizasyon rolüdür -- Super Admin'de her zaman boştur (bu,
	// bilinçli olarak platform rolünü net biçimde ayırt eder: tenant
	// izinlerine ASLA köprülenmez, spec §3). Permissions, YALNIZCA
	// toSessionResponse (login/refresh/me) tarafından doldurulur -- salt
	// UX gösterimi/gizleme içindir, güvenlik sınırı DEĞİLDİR (backend her
	// zaman yeniden doğrular).
	OrganizationRoleCode string   `json:"organization_role_code,omitempty"`
	OrganizationRoleName string   `json:"organization_role_name,omitempty"`
	Permissions          []string `json:"permissions,omitempty"`
}

// toUserResponse, organizasyon (onboarding) bağlamı olmayan çağrı
// noktaları içindir (ör. UserHandler'ın org-içi kullanıcı CRUD'u) --
// onboarding alanları bu bağlamda anlamsız olduğu için sabit "tamamlanmış"
// değerine düşer (ekstra bir organizasyon sorgusu gerektirmez).
func toUserResponse(u domain.User) userResponse {
	return userResponse{
		ID:                   u.ID,
		OrganizationID:       u.OrganizationID,
		Username:             u.Username,
		FullName:             u.FullName,
		Role:                 u.Role,
		IsActive:             u.IsActive,
		MustChangePassword:   u.MustChangePassword,
		OnboardingCompleted:  true,
		OnboardingStep:       string(domain.OnboardingStepCompleted),
		OrganizationRoleCode: u.OrganizationRoleCode,
		OrganizationRoleName: u.OrganizationRoleName,
	}
}

// toSessionResponse, giriş/refresh/me akışları içindir -- kullanıcının
// GERÇEK organizasyon onboarding durumunu VE (super_admin hariç) ince-
// taneli izin listesini taşır. authzSvc nil GEÇİLEBİLİR (ör. gelecekte
// authzSvc'siz bir test/araç çağrısı) -- o durumda izin/rol alanları
// sessizce boş kalır, çağıran KIRILMAZ.
func toSessionResponse(ctx context.Context, authzSvc *service.AuthorizationService, session service.Session) userResponse {
	resp := toUserResponse(session.User)
	if session.Organization != nil {
		resp.OrganizationName = session.Organization.Name
		resp.OnboardingCompleted = session.Organization.OnboardingCompleted
		resp.OnboardingStep = string(session.Organization.OnboardingStep)
	}
	// super_admin'in organization_id'si YOKTUR -- tenant izin sorgusuna
	// hiç girmez, permissions/organization_role alanları BOŞ kalır (spec
	// §3: platform rolü tenant izinlerine ASLA köprülenmez).
	if authzSvc != nil && session.User.Role != domain.RoleSuperAdmin && session.User.OrganizationID != nil {
		if authz, err := authzSvc.LoadAuthzContext(ctx, session.User.ID, *session.User.OrganizationID); err == nil {
			resp.OrganizationRoleCode = authz.RoleCode
			resp.OrganizationRoleName = authz.RoleName
			perms := make([]string, 0, len(authz.Permissions))
			for code := range authz.Permissions {
				perms = append(perms, code)
			}
			resp.Permissions = perms
		}
	}
	return resp
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
	httpjson.Write(w, http.StatusOK, toSessionResponse(r.Context(), h.authzSvc, *session))
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
	httpjson.Write(w, http.StatusOK, toSessionResponse(r.Context(), h.authzSvc, *session))
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
	session, err := h.svc.Me(r.Context(), userID)
	if err != nil {
		httpjson.Error(w, http.StatusUnauthorized, "oturum geçersiz")
		return
	}
	httpjson.Write(w, http.StatusOK, toSessionResponse(r.Context(), h.authzSvc, *session))
}

func (h *AuthHandler) writeAuthError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrInvalidCredentials):
		httpjson.Error(w, http.StatusUnauthorized, "kullanıcı adı veya şifre hatalı")
	case errors.Is(err, domain.ErrInactiveUser):
		httpjson.Error(w, http.StatusForbidden, "kullanıcı pasif durumda")
	case errors.Is(err, domain.ErrOrganizationSuspended):
		httpjson.Error(w, http.StatusForbidden, "firma askıya alınmış veya erişilemiyor")
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
