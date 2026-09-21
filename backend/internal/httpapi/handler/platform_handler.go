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

// PlatformHandler, YALNIZCA router.go'da requireSuperAdmin arkasında
// mount edilmelidir -- burada organizasyon izolasyonu yoktur (bilinçli).
type PlatformHandler struct {
	svc *service.PlatformService
}

func NewPlatformHandler(svc *service.PlatformService) *PlatformHandler {
	return &PlatformHandler{svc: svc}
}

type organizationResponse struct {
	ID                    string  `json:"id"`
	Name                  string  `json:"name"`
	Slug                  string  `json:"slug"`
	IsActive              bool    `json:"is_active"`
	Status                string  `json:"status"`
	PlanCode              string  `json:"plan_code"`
	TrialEndsAt           *string `json:"trial_ends_at,omitempty"`
	OnboardingCompleted   bool    `json:"onboarding_completed"`
	OnboardingCompletedAt *string `json:"onboarding_completed_at,omitempty"`
	OnboardingStep        string  `json:"onboarding_step"`
	CreatedAt             string  `json:"created_at"`
	UpdatedAt             string  `json:"updated_at"`
	// ActiveOwnerCount, YALNIZCA GetOrganization (firma detayı) tarafından
	// doldurulur (0 = alan yok) -- liste/oluşturma yanıtlarında ekstra bir
	// sorgu gerektirmez, omitempty ile hiç görünmez. Sayfalanmış kullanıcı
	// listesinden (200 sınırı) BAĞIMSIZDIR, bkz. PlatformService.CountActiveOwners.
	ActiveOwnerCount int64 `json:"active_owner_count,omitempty"`
	// DeletedAt, Status'ten TAMAMEN AYRI bir eksendir (bkz. migration 0043
	// -- "Askıya Al"/"İptal Et" İLE KARIŞTIRILMAMALI). Yalnızca Silinenler/
	// Arşiv görünümündeki ve tek firma detayındaki kayıtlarda dolu gelir.
	DeletedAt *string `json:"deleted_at,omitempty"`
}

func toOrganizationResponse(o domain.Organization) organizationResponse {
	resp := organizationResponse{
		ID: o.ID, Name: o.Name, Slug: o.Slug, IsActive: o.IsActive,
		Status: string(o.Status), PlanCode: o.PlanCode,
		OnboardingCompleted: o.OnboardingCompleted, OnboardingStep: string(o.OnboardingStep),
		CreatedAt: o.CreatedAt.Format("2006-01-02T15:04:05Z07:00"),
		UpdatedAt: o.UpdatedAt.Format("2006-01-02T15:04:05Z07:00"),
	}
	if o.TrialEndsAt != nil {
		s := o.TrialEndsAt.Format("2006-01-02T15:04:05Z07:00")
		resp.TrialEndsAt = &s
	}
	if o.OnboardingCompletedAt != nil {
		s := o.OnboardingCompletedAt.Format("2006-01-02T15:04:05Z07:00")
		resp.OnboardingCompletedAt = &s
	}
	if o.DeletedAt != nil {
		s := o.DeletedAt.Format("2006-01-02T15:04:05Z07:00")
		resp.DeletedAt = &s
	}
	return resp
}

type createOrganizationRequest struct {
	Name          string `json:"name"`
	Slug          string `json:"slug"`
	PlanCode      string `json:"plan_code"`
	Status        string `json:"status"`
	TrialDays     int    `json:"trial_days"`
	OwnerUsername string `json:"owner_username"`
	OwnerPassword string `json:"owner_password"`
	OwnerFullName string `json:"owner_full_name"`
}

func (h *PlatformHandler) CreateOrganization(w http.ResponseWriter, r *http.Request) {
	var req createOrganizationRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	actorID, _ := middleware.UserIDFromContext(r.Context())
	result, err := h.svc.CreateOrganizationWithOwner(r.Context(), service.CreateOrganizationInput{
		Name: req.Name, Slug: req.Slug, PlanCode: req.PlanCode, Status: domain.OrgStatus(req.Status),
		TrialDays: req.TrialDays, OwnerUsername: req.OwnerUsername, OwnerPassword: req.OwnerPassword,
		OwnerFullName: req.OwnerFullName, ActorUserID: actorID,
	})
	if err != nil {
		h.writePlatformError(w, err)
		return
	}
	resp := map[string]any{
		"organization": toOrganizationResponse(result.Organization),
		"owner":        toUserResponse(result.Owner),
	}
	if result.CalcCatalog == nil {
		resp["calc_catalog_provisioned"] = false
	} else {
		resp["calc_catalog_provisioned"] = true
	}
	httpjson.Write(w, http.StatusCreated, resp)
}

// ListOrganizations, ?status=deleted için AYRI bir servis metoduna
// (ListDeletedOrganizations) yönlendirir -- "deleted" GERÇEK bir
// domain.OrgStatus değeri DEĞİLDİR (bkz. domain/organization.go
// Organization.DeletedAt yorumu: silme, status'ten BAĞIMSIZ bir eksendir),
// bu yüzden servis katmanına sahte bir status string'i olarak asla
// geçirilmez.
func (h *PlatformHandler) ListOrganizations(w http.ResponseWriter, r *http.Request) {
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	status := r.URL.Query().Get("status")

	var result *service.OrganizationListResult
	var err error
	if status == "deleted" {
		result, err = h.svc.ListDeletedOrganizations(r.Context(), page, limit)
	} else {
		result, err = h.svc.ListOrganizations(r.Context(), status, page, limit)
	}
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "firmalar alınamadı")
		return
	}
	orgs := make([]organizationResponse, len(result.Organizations))
	for i, o := range result.Organizations {
		orgs[i] = toOrganizationResponse(o)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"organizations": orgs, "total": result.Total})
}

func (h *PlatformHandler) DeleteOrganization(w http.ResponseWriter, r *http.Request) {
	actorID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.DeleteOrganization(r.Context(), chi.URLParam(r, "id"), actorID); err != nil {
		h.writePlatformError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *PlatformHandler) RestoreOrganization(w http.ResponseWriter, r *http.Request) {
	actorID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.RestoreOrganization(r.Context(), chi.URLParam(r, "id"), actorID); err != nil {
		h.writePlatformError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *PlatformHandler) GetOrganization(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	org, err := h.svc.GetOrganization(r.Context(), id)
	if err != nil {
		h.writePlatformError(w, err)
		return
	}
	resp := toOrganizationResponse(*org)
	if count, err := h.svc.CountActiveOwners(r.Context(), id); err == nil {
		resp.ActiveOwnerCount = count
	}
	httpjson.Write(w, http.StatusOK, resp)
}

type updateOrganizationStatusRequest struct {
	Status string `json:"status"`
}

func (h *PlatformHandler) UpdateOrganizationStatus(w http.ResponseWriter, r *http.Request) {
	var req updateOrganizationStatusRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	actorID, _ := middleware.UserIDFromContext(r.Context())
	org, err := h.svc.SetStatus(r.Context(), chi.URLParam(r, "id"), actorID, domain.OrgStatus(req.Status))
	if err != nil {
		h.writePlatformError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toOrganizationResponse(*org))
}

type updateOrganizationPlanRequest struct {
	PlanCode string `json:"plan_code"`
}

func (h *PlatformHandler) UpdateOrganizationPlan(w http.ResponseWriter, r *http.Request) {
	var req updateOrganizationPlanRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	actorID, _ := middleware.UserIDFromContext(r.Context())
	org, err := h.svc.UpdatePlan(r.Context(), chi.URLParam(r, "id"), actorID, req.PlanCode)
	if err != nil {
		h.writePlatformError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toOrganizationResponse(*org))
}

// ListOrganizationUsers, ?view=deleted için AYRI bir servis metoduna
// (ListDeletedOrganizationUsers) yönlendirir -- UsersTab.tsx yorumu ile
// AYNI ilke: normal görünüm silinmiş kullanıcıları HİÇ döndürmez.
func (h *PlatformHandler) ListOrganizationUsers(w http.ResponseWriter, r *http.Request) {
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))

	var result *service.ListResult
	var err error
	if r.URL.Query().Get("view") == "deleted" {
		result, err = h.svc.ListDeletedOrganizationUsers(r.Context(), chi.URLParam(r, "id"), page, limit)
	} else {
		result, err = h.svc.ListOrganizationUsers(r.Context(), chi.URLParam(r, "id"), page, limit)
	}
	if err != nil {
		h.writePlatformError(w, err)
		return
	}
	users := make([]userResponse, len(result.Users))
	for i, u := range result.Users {
		users[i] = toUserResponse(u)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"users": users, "total": result.Total})
}

func (h *PlatformHandler) DeleteOrganizationUser(w http.ResponseWriter, r *http.Request) {
	actorID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.DeleteOrganizationUser(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "userId"), actorID); err != nil {
		h.writePlatformError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *PlatformHandler) RestoreOrganizationUser(w http.ResponseWriter, r *http.Request) {
	actorID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.RestoreOrganizationUser(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "userId"), actorID); err != nil {
		h.writePlatformError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *PlatformHandler) ListOrganizationRoles(w http.ResponseWriter, r *http.Request) {
	roles, err := h.svc.ListOrganizationRoles(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		h.writePlatformError(w, err)
		return
	}
	resp := make([]organizationRoleResponse, len(roles))
	for i, role := range roles {
		resp[i] = toOrganizationRoleResponse(role)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"roles": resp})
}

type provisionOrganizationUserRequest struct {
	Username             string `json:"username"`
	FullName             string `json:"full_name"`
	TemporaryPassword    string `json:"temporary_password"`
	OrganizationRoleCode string `json:"organization_role_code"`
}

func (h *PlatformHandler) ProvisionOrganizationUser(w http.ResponseWriter, r *http.Request) {
	var req provisionOrganizationUserRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	actorID, _ := middleware.UserIDFromContext(r.Context())
	user, err := h.svc.ProvisionOrganizationUser(r.Context(), service.ProvisionOrganizationUserInput{
		OrganizationID: chi.URLParam(r, "id"), Username: req.Username, FullName: req.FullName,
		TemporaryPassword: req.TemporaryPassword, RoleCode: req.OrganizationRoleCode, ActorUserID: actorID,
	})
	if err != nil {
		h.writePlatformError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toUserResponse(*user))
}

func (h *PlatformHandler) DeactivateOrganizationUser(w http.ResponseWriter, r *http.Request) {
	actorID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.DeactivateOrganizationUser(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "userId"), actorID); err != nil {
		h.writePlatformError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *PlatformHandler) ReactivateOrganizationUser(w http.ResponseWriter, r *http.Request) {
	actorID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.ReactivateOrganizationUser(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "userId"), actorID); err != nil {
		h.writePlatformError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

type setOrganizationUserRoleRequest struct {
	RoleCode string `json:"role_code"`
}

func (h *PlatformHandler) SetOrganizationUserRole(w http.ResponseWriter, r *http.Request) {
	var req setOrganizationUserRoleRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	actorID, _ := middleware.UserIDFromContext(r.Context())
	role, err := h.svc.SetOrganizationUserRole(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "userId"), req.RoleCode, actorID)
	if err != nil {
		h.writePlatformError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"organization_role_code": role.Code, "organization_role_name": role.Name})
}

type resetOrganizationUserPasswordRequest struct {
	TemporaryPassword string `json:"temporary_password"`
}

func (h *PlatformHandler) ResetOrganizationUserPassword(w http.ResponseWriter, r *http.Request) {
	var req resetOrganizationUserPasswordRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	actorID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.ResetOrganizationUserPassword(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "userId"), req.TemporaryPassword, actorID); err != nil {
		h.writePlatformError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

type reprovisionCalcCatalogRequest struct {
	LinkProducts bool `json:"link_products"`
}

func (h *PlatformHandler) ReprovisionCalcCatalog(w http.ResponseWriter, r *http.Request) {
	var req reprovisionCalcCatalogRequest
	_ = httpjson.Decode(r, &req) // gövde boş olabilir (varsayılan link_products=false)
	actorID, _ := middleware.UserIDFromContext(r.Context())
	res, err := h.svc.ReprovisionCalcCatalog(r.Context(), chi.URLParam(r, "id"), actorID, req.LinkProducts)
	if err != nil {
		h.writePlatformError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, res)
}

type auditEventResponse struct {
	ID                   string         `json:"id"`
	ActorUserID          *string        `json:"actor_user_id"`
	Action               string         `json:"action"`
	TargetOrganizationID *string        `json:"target_organization_id"`
	TargetUserID         *string        `json:"target_user_id"`
	Metadata             map[string]any `json:"metadata"`
	CreatedAt            string         `json:"created_at"`
}

func toAuditEventResponse(e domain.AuditEvent) auditEventResponse {
	return auditEventResponse{
		ID: e.ID, ActorUserID: e.ActorUserID, Action: e.Action,
		TargetOrganizationID: e.TargetOrganizationID, TargetUserID: e.TargetUserID,
		Metadata: e.Metadata, CreatedAt: e.CreatedAt.Format("2006-01-02T15:04:05Z07:00"),
	}
}

func (h *PlatformHandler) ListAuditEvents(w http.ResponseWriter, r *http.Request) {
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	events, err := h.svc.ListAuditEvents(r.Context(), chi.URLParam(r, "id"), page, limit)
	if err != nil {
		h.writePlatformError(w, err)
		return
	}
	resp := make([]auditEventResponse, len(events))
	for i, e := range events {
		resp[i] = toAuditEventResponse(e)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"events": resp})
}

type planResponse struct {
	Code        string `json:"code"`
	Name        string `json:"name"`
	IsActive    bool   `json:"is_active"`
	MaxUsers    int    `json:"max_users"`
	MaxProjects int    `json:"max_projects"`
	SortOrder   int    `json:"sort_order"`
}

func toPlanResponse(p domain.Plan) planResponse {
	return planResponse{
		Code: p.Code, Name: p.Name, IsActive: p.IsActive,
		MaxUsers: p.MaxUsers, MaxProjects: p.MaxProjects, SortOrder: p.SortOrder,
	}
}

func (h *PlatformHandler) ListPlans(w http.ResponseWriter, r *http.Request) {
	plans, err := h.svc.ListPlans(r.Context())
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "planlar alınamadı")
		return
	}
	resp := make([]planResponse, len(plans))
	for i, p := range plans {
		resp[i] = toPlanResponse(p)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"plans": resp})
}

func (h *PlatformHandler) writePlatformError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "kayıt bulunamadı")
	case errors.Is(err, domain.ErrDuplicateUsername):
		httpjson.Error(w, http.StatusConflict, "bu kullanıcı adı zaten kullanılıyor")
	case errors.Is(err, domain.ErrLastOwner), errors.Is(err, domain.ErrInvalidOrgStatusTransition),
		errors.Is(err, domain.ErrAlreadyDeleted), errors.Is(err, domain.ErrNotDeleted),
		errors.Is(err, domain.ErrOrganizationDeleted), errors.Is(err, domain.ErrUserDeleted):
		httpjson.Error(w, http.StatusConflict, err.Error())
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
