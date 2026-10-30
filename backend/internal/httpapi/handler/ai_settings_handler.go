package handler

// Yapay Zekâ Ayarları (migration 0081; bkz. service/ai_settings_service.go).
// Uçlar /api/v1/ai/settings altında, requireAdmin + organization.roles.manage
// ile (router). Neden roles.manage (settings.manage değil): ekranın asıl
// işi kişiye maliyetli bir İZİN (ai.images.use) açıp kapatmak -- bu,
// PUT /users/{id}/permissions ile AYNI yetki; settings.manage'ı olup
// roles.manage'ı olmayan biri bu ekrandan Roller & Yetkiler kapısını
// atlayıp izin dağıtamasın. Varsayılan: Sahip ve Yönetici.

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// canManageAI: /ai/status'taki can_manage -- router'daki kapıyla aynı
// (kaba rol admin + organization.roles.manage), uygulama dişliyi buna göre
// gösterir.
func canManageAI(r *http.Request) bool {
	role, _ := middleware.RoleFromContext(r.Context())
	authz, _ := middleware.AuthzContextFromRequest(r.Context())
	return role == domain.RoleAdmin && authz.HasPermission(domain.PermOrganizationRolesManage)
}

type aiSettingsUserResponse struct {
	UserID        string `json:"user_id"`
	FullName      string `json:"full_name"`
	RoleCode      string `json:"role_code"`
	RoleName      string `json:"role_name"`
	IsOwner       bool   `json:"is_owner"`
	CanUse        bool   `json:"can_use"`
	Source        string `json:"source"`
	UsedThisMonth int    `json:"used_this_month"`
}

type aiSettingsResponse struct {
	Enabled               bool                     `json:"enabled"`
	MonthlyLimit          *int                     `json:"monthly_limit"`
	EffectiveMonthlyLimit int                      `json:"effective_monthly_limit"`
	ServerMax             int                      `json:"server_max"`
	PerUserMonthlyLimit   *int                     `json:"per_user_monthly_limit"`
	UsedThisMonth         int                      `json:"used_this_month"`
	ResetsAt              string                   `json:"resets_at"`
	Users                 []aiSettingsUserResponse `json:"users"`
}

func toAISettingsResponse(st *domain.AISettings) aiSettingsResponse {
	out := aiSettingsResponse{
		Enabled: st.Enabled, MonthlyLimit: st.MonthlyLimit, EffectiveMonthlyLimit: st.EffectiveMonthlyLimit,
		ServerMax: st.ServerMax, PerUserMonthlyLimit: st.PerUserMonthlyLimit, UsedThisMonth: st.UsedThisMonth,
		ResetsAt: st.ResetsAt.Format(rfc3339), Users: make([]aiSettingsUserResponse, len(st.Users)),
	}
	for i, u := range st.Users {
		out.Users[i] = aiSettingsUserResponse{
			UserID: u.UserID, FullName: u.FullName, RoleCode: u.RoleCode, RoleName: u.RoleName,
			IsOwner: u.IsOwner, CanUse: u.CanUse, Source: u.Source, UsedThisMonth: u.UsedThisMonth,
		}
	}
	return out
}

// GetSettings: GET /ai/settings.
func (h *AIImageHandler) GetSettings(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	st, err := h.svc.GetSettings(r.Context(), orgID)
	if err != nil {
		h.writeSettingsError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toAISettingsResponse(st))
}

type updateAISettingsRequest struct {
	Enabled             *bool `json:"enabled"`
	MonthlyLimit        *int  `json:"monthly_limit"`
	PerUserMonthlyLimit *int  `json:"per_user_monthly_limit"`
}

// UpdateSettings: PUT /ai/settings -- bütün kurallar birlikte (null limit =
// sunucu varsayılanı / kişi sınırı yok).
func (h *AIImageHandler) UpdateSettings(w http.ResponseWriter, r *http.Request) {
	var req updateAISettingsRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	if req.Enabled == nil {
		httpjson.Error(w, http.StatusBadRequest, "Yapay zekânın açık mı kapalı mı olacağını seçin")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	actorID, _ := middleware.UserIDFromContext(r.Context())
	st, err := h.svc.UpdateSettings(r.Context(), orgID, actorID, service.UpdateAISettingsInput{
		Enabled: *req.Enabled, MonthlyLimit: req.MonthlyLimit, PerUserMonthlyLimit: req.PerUserMonthlyLimit,
	})
	if err != nil {
		h.writeSettingsError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toAISettingsResponse(st))
}

// SetUserAccess: PUT /ai/settings/users/{userId} {"can_use": true|false|null}
// -- ai.images.use'un kişiye özel ayarı (null = rolüne bırak). Alan
// zorunlu: boş gövde yanlışlıkla ayarı silmesin.
func (h *AIImageHandler) SetUserAccess(w http.ResponseWriter, r *http.Request) {
	var raw map[string]json.RawMessage
	if err := httpjson.Decode(r, &raw); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	v, ok := raw["can_use"]
	if !ok {
		httpjson.Error(w, http.StatusBadRequest, "can_use alanı gerekli (true, false ya da null)")
		return
	}
	var canUse *bool
	if err := json.Unmarshal(v, &canUse); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "can_use alanı gerekli (true, false ya da null)")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	actorID, _ := middleware.UserIDFromContext(r.Context())
	err := h.authz.SetUserPermissionOverride(r.Context(), chi.URLParam(r, "userId"), orgID, actorID, domain.PermAIImagesUse, canUse)
	if errors.Is(err, domain.ErrOwnerPermissionsFixed) {
		// Sahip her zaman kullanır: "aç"/"role bırak" zaten öyle (değişiklik
		// yok), "kapat" yapılamaz -- kapatılmış görünüp çalışmasın.
		if canUse != nil && !*canUse {
			err = service.ErrAIOwnerAlwaysAllowed
		} else {
			err = nil
		}
	}
	if err != nil {
		h.writeSettingsError(w, err)
		return
	}
	st, err := h.svc.GetSettings(r.Context(), orgID)
	if err != nil {
		h.writeSettingsError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toAISettingsResponse(st))
}

func (h *AIImageHandler) writeSettingsError(w http.ResponseWriter, err error) {
	var invalid *service.AISettingsValidationError
	switch {
	case errors.As(err, &invalid):
		httpjson.Error(w, http.StatusBadRequest, invalid.Error())
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "kişi bulunamadı")
	case errors.Is(err, service.ErrAIOwnerAlwaysAllowed),
		errors.Is(err, domain.ErrUserDeleted),
		errors.Is(err, domain.ErrPortalUserLocked),
		errors.Is(err, domain.ErrUserHasNoRole):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case errors.Is(err, domain.ErrUnknownPermission), errors.Is(err, domain.ErrPermissionNeedsAdminRole):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	default:
		writeInternalError(w, err)
	}
}
