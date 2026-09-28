package handler

import (
	"net/http"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// DashboardHandler, ana sayfa özetinin (GET /dashboard) ve hızlı işlem
// proje seçicisinin (GET /dashboard/project-options) HTTP katmanıdır.
// /dashboard'da perm() YOKTUR: her bölüm kendi kapısını serviste
// değerlendirir (yetkisiz bölüm yanıtta hiç görünmez).
type DashboardHandler struct {
	svc *service.DashboardService
}

func NewDashboardHandler(svc *service.DashboardService) *DashboardHandler {
	return &DashboardHandler{svc: svc}
}

// Get: bazı bölümler hesaplanamasa bile 200 döner (section_errors); 500
// yalnızca işlem ya da izleyici/meta sorguları başarısız olursa.
func (h *DashboardHandler) Get(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	authz, ok := middleware.AuthzContextFromRequest(r.Context())
	if !ok {
		httpjson.Error(w, http.StatusForbidden, "bu işlem için yetkiniz yok")
		return
	}
	role, _ := middleware.RoleFromContext(r.Context())
	res, err := h.svc.Get(r.Context(), service.DashboardInput{
		OrganizationID: orgID, UserID: authz.UserID, CoarseRole: role, Authz: authz, Now: time.Now(),
	})
	if err != nil {
		writeInternalError(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	httpjson.Write(w, http.StatusOK, res)
}

// ProjectOptions: {"projects":[{id, project_no, name, customer_name,
// currency, status}]} -- açık projeler, üyelik kapsamlı, ?q= ad/proje no
// araması, en fazla 50; tutar alanı YOK.
func (h *DashboardHandler) ProjectOptions(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	authz, ok := middleware.AuthzContextFromRequest(r.Context())
	if !ok {
		httpjson.Error(w, http.StatusForbidden, "bu işlem için yetkiniz yok")
		return
	}
	opts, err := h.svc.ProjectOptions(r.Context(), orgID, authz, r.URL.Query().Get("q"))
	if err != nil {
		writeInternalError(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	httpjson.Write(w, http.StatusOK, map[string]any{"projects": opts})
}
