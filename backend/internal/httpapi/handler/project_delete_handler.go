package handler

import (
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
)

// Proje silme (migration 0070). İzin kapıları router'da: direkt silme ve
// talebe karar projects.delete, talep açma/geri çekme projects.update (proje
// erişimiyle). Para hareketi olan proje 409 (ProjectHasRecordsError metni
// neyin engellediğini sayar).

type projectDeleteRequestResponse struct {
	ID              string  `json:"id"`
	ProjectID       string  `json:"project_id"`
	RequestedBy     *string `json:"requested_by"`
	RequestedByName string  `json:"requested_by_name"`
	Reason          string  `json:"reason"`
	CreatedAt       string  `json:"created_at"`
	ProjectNo       string  `json:"project_no,omitempty"`
	ProjectName     string  `json:"project_name,omitempty"`
	CustomerName    string  `json:"customer_name,omitempty"`
}

func toProjectDeleteRequestResponse(r domain.ProjectDeleteRequest, withProject bool) *projectDeleteRequestResponse {
	resp := &projectDeleteRequestResponse{
		ID: r.ID, ProjectID: r.ProjectID, RequestedBy: r.RequestedBy, RequestedByName: r.RequestedByName,
		Reason: r.Reason, CreatedAt: r.CreatedAt.Format(time.RFC3339),
	}
	if withProject {
		resp.ProjectNo, resp.ProjectName, resp.CustomerName = r.ProjectNo, r.ProjectName, r.CustomerName
	}
	return resp
}

// DeleteProject: DELETE /projects/{id} (projects.delete).
func (h *ProjectHandler) DeleteProject(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.DeleteProject(r.Context(), chi.URLParam(r, "id"), orgID, userID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

// RequestProjectDelete: POST /projects/{id}/delete-request {"reason"}.
func (h *ProjectHandler) RequestProjectDelete(w http.ResponseWriter, r *http.Request) {
	var req offerDeleteNoteRequest
	if err := decodeOptionalBody(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	out, err := h.svc.RequestProjectDelete(r.Context(), chi.URLParam(r, "id"), orgID, userID, req.Reason)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toProjectDeleteRequestResponse(*out, false))
}

// WithdrawProjectDeleteRequest: DELETE /projects/{id}/delete-request.
func (h *ProjectHandler) WithdrawProjectDeleteRequest(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.WithdrawProjectDeleteRequest(r.Context(), chi.URLParam(r, "id"), orgID, userID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

// ApproveProjectDeleteRequest: POST /projects/{id}/delete-request/approve.
func (h *ProjectHandler) ApproveProjectDeleteRequest(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.ApproveProjectDeleteRequest(r.Context(), chi.URLParam(r, "id"), orgID, userID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

// RejectProjectDeleteRequest: POST /projects/{id}/delete-request/reject {"note"}.
func (h *ProjectHandler) RejectProjectDeleteRequest(w http.ResponseWriter, r *http.Request) {
	var req offerDeleteNoteRequest
	if err := decodeOptionalBody(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.RejectProjectDeleteRequest(r.Context(), chi.URLParam(r, "id"), orgID, userID, req.Note); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

// ListProjectDeleteRequests: GET /projects/delete-requests (projects.delete).
func (h *ProjectHandler) ListProjectDeleteRequests(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListPendingProjectDeleteRequests(r.Context(), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]*projectDeleteRequestResponse, len(rows))
	for i, row := range rows {
		out[i] = toProjectDeleteRequestResponse(row, true)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"data": out})
}
