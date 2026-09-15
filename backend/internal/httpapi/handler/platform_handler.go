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

func (h *PlatformHandler) ListOrganizations(w http.ResponseWriter, r *http.Request) {
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	status := r.URL.Query().Get("status")
	result, err := h.svc.ListOrganizations(r.Context(), status, page, limit)
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

func (h *PlatformHandler) GetOrganization(w http.ResponseWriter, r *http.Request) {
	org, err := h.svc.GetOrganization(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		h.writePlatformError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toOrganizationResponse(*org))
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

func (h *PlatformHandler) ListOrganizationUsers(w http.ResponseWriter, r *http.Request) {
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	result, err := h.svc.ListOrganizationUsers(r.Context(), chi.URLParam(r, "id"), page, limit)
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
		httpjson.Error(w, http.StatusNotFound, "firma bulunamadı")
	case errors.Is(err, domain.ErrDuplicateUsername):
		httpjson.Error(w, http.StatusConflict, "bu kullanıcı adı zaten kullanılıyor")
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
