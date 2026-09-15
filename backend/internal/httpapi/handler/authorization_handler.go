package handler

import (
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// AuthorizationHandler, "Roller & Yetkiler" ve "Proje Erişimi" ekranlarının
// HTTP yüzeyidir -- RBAC/Project Membership sprint'i.
type AuthorizationHandler struct {
	svc *service.AuthorizationService
}

func NewAuthorizationHandler(svc *service.AuthorizationService) *AuthorizationHandler {
	return &AuthorizationHandler{svc: svc}
}

func (h *AuthorizationHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "kayıt bulunamadı")
	case errors.Is(err, domain.ErrUnknownPermission):
		httpjson.Error(w, http.StatusBadRequest, "tanımsız izin kodu")
	case errors.Is(err, domain.ErrLastOwner):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case errors.Is(err, domain.ErrCrossOrgMembership):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}

// ---------- İzin Kataloğu ----------

type permissionResponse struct {
	Code        string `json:"code"`
	Description string `json:"description"`
	Category    string `json:"category"`
}

func (h *AuthorizationHandler) ListPermissions(w http.ResponseWriter, r *http.Request) {
	rows, err := h.svc.ListPermissions(r.Context())
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]permissionResponse, len(rows))
	for i, p := range rows {
		out[i] = permissionResponse{Code: p.Code, Description: p.Description, Category: p.Category}
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"permissions": out})
}

// ---------- Organizasyon Rolleri ----------

type organizationRoleResponse struct {
	ID          string   `json:"id"`
	Code        string   `json:"code"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	IsSystem    bool     `json:"is_system"`
	Permissions []string `json:"permissions"`
}

func toOrganizationRoleResponse(r domain.OrganizationRole) organizationRoleResponse {
	perms := r.Permissions
	if perms == nil {
		perms = []string{}
	}
	return organizationRoleResponse{
		ID: r.ID, Code: r.Code, Name: r.Name, Description: r.Description,
		IsSystem: r.IsSystem, Permissions: perms,
	}
}

// ListOrganizationRoles, legacy_user'ı ASLA döndürmez (bkz.
// AuthorizationService.ListOrganizationRoles notu) -- web rol yönetim
// ekranı yalnızca gerçek atama hedeflerini görür.
func (h *AuthorizationHandler) ListOrganizationRoles(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListOrganizationRoles(r.Context(), orgID, false)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]organizationRoleResponse, len(rows))
	for i, r := range rows {
		out[i] = toOrganizationRoleResponse(r)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"roles": out})
}

func (h *AuthorizationHandler) GetOrganizationRole(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	role, err := h.svc.GetOrganizationRole(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toOrganizationRoleResponse(*role))
}

type setRolePermissionsRequest struct {
	Permissions []string `json:"permissions"`
}

func (h *AuthorizationHandler) SetRolePermissions(w http.ResponseWriter, r *http.Request) {
	var req setRolePermissionsRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	role, err := h.svc.SetRolePermissions(r.Context(), chi.URLParam(r, "id"), orgID, req.Permissions)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toOrganizationRoleResponse(*role))
}

type userProjectAssignmentResponse struct {
	ProjectID   string `json:"project_id"`
	ProjectNo   string `json:"project_no"`
	ProjectName string `json:"project_name"`
	ProjectRole string `json:"project_role"`
}

// ListUserProjects, "Kullanıcılar" ekranının kullanıcı detayındaki
// "Atandığı Projeler" listesidir.
func (h *AuthorizationHandler) ListUserProjects(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListUserProjects(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]userProjectAssignmentResponse, len(rows))
	for i, a := range rows {
		out[i] = userProjectAssignmentResponse{ProjectID: a.ProjectID, ProjectNo: a.ProjectNo, ProjectName: a.ProjectName, ProjectRole: a.ProjectRole}
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"projects": out})
}

// ---------- Proje Erişimi (project_users) ----------

type projectUserResponse struct {
	UserID               string `json:"user_id"`
	Username             string `json:"username"`
	FullName             string `json:"full_name"`
	UserIsActive         bool   `json:"user_is_active"`
	ProjectRole          string `json:"project_role"`
	OrganizationRoleCode string `json:"organization_role_code"`
	OrganizationRoleName string `json:"organization_role_name"`
}

func toProjectUserResponse(pu domain.ProjectUser) projectUserResponse {
	return projectUserResponse{
		UserID: pu.UserID, Username: pu.Username, FullName: pu.FullName, UserIsActive: pu.UserIsActive,
		ProjectRole: pu.ProjectRole, OrganizationRoleCode: pu.OrganizationRole, OrganizationRoleName: pu.OrganizationRoleName,
	}
}

func (h *AuthorizationHandler) ListProjectUsers(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListProjectUsers(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]projectUserResponse, len(rows))
	for i, pu := range rows {
		out[i] = toProjectUserResponse(pu)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"users": out})
}

type addProjectUserRequest struct {
	UserID      string `json:"user_id"`
	ProjectRole string `json:"project_role"`
}

func (h *AuthorizationHandler) AddProjectUser(w http.ResponseWriter, r *http.Request) {
	var req addProjectUserRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	pu, err := h.svc.AddProjectUser(r.Context(), chi.URLParam(r, "id"), orgID, service.ProjectUserInput{
		UserID: req.UserID, ProjectRole: req.ProjectRole, CreatedBy: userID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, map[string]any{"user_id": pu.UserID, "project_role": pu.ProjectRole})
}

func (h *AuthorizationHandler) RemoveProjectUser(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	if err := h.svc.RemoveProjectUser(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "userId"), orgID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

type updateProjectUserRoleRequest struct {
	ProjectRole string `json:"project_role"`
}

func (h *AuthorizationHandler) UpdateProjectUserRole(w http.ResponseWriter, r *http.Request) {
	var req updateProjectUserRoleRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	pu, err := h.svc.UpdateProjectUserRole(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "userId"), orgID, req.ProjectRole)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"user_id": pu.UserID, "project_role": pu.ProjectRole})
}
