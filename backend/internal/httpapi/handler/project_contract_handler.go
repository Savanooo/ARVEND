package handler

import (
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// ARVEND V2 -- Sprint 3: Proje Sözleşmesi (Contract) -- gelir (revenue)
// tarafı, Sprint 2'nin Bütçe/Maliyet Kontrolü (maliyet tarafı) İLE
// KARIŞTIRILMAMALI. Mevcut ProjectHandler'a EKLENİR (project_cost_control_
// handler.go İLE AYNI dosya-başına-endişe deseni).

type contractResponse struct {
	ID                    string  `json:"id"`
	Currency              string  `json:"currency"`
	Status                string  `json:"status"`
	Scope                 string  `json:"scope"`
	PaymentTerms          string  `json:"payment_terms"`
	RetentionTerms        string  `json:"retention_terms"`
	AdvanceTerms          string  `json:"advance_terms"`
	EffectiveDate         *string `json:"effective_date,omitempty"`
	PlannedCompletionDate *string `json:"planned_completion_date,omitempty"`
	InternalNotes         string  `json:"internal_notes"`
	CreatedAt             string  `json:"created_at"`
	UpdatedAt             string  `json:"updated_at"`
	ActivatedAt           *string `json:"activated_at,omitempty"`
	CompletedAt           *string `json:"completed_at,omitempty"`
	CancelledAt           *string `json:"cancelled_at,omitempty"`
	CancelReason          string  `json:"cancel_reason,omitempty"`
	TerminatedAt          *string `json:"terminated_at,omitempty"`
	TerminationReason     string  `json:"termination_reason,omitempty"`
}

func toContractResponse(c domain.ProjectContract) contractResponse {
	return contractResponse{
		ID: c.ID, Currency: c.Currency, Status: c.Status,
		Scope: c.Scope, PaymentTerms: c.PaymentTerms, RetentionTerms: c.RetentionTerms, AdvanceTerms: c.AdvanceTerms,
		EffectiveDate: dateStrPtr(c.EffectiveDate), PlannedCompletionDate: dateStrPtr(c.PlannedCompletionDate),
		InternalNotes: c.InternalNotes,
		CreatedAt:     c.CreatedAt.Format(rfc3339), UpdatedAt: c.UpdatedAt.Format(rfc3339),
		ActivatedAt: tsStrPtr(c.ActivatedAt), CompletedAt: tsStrPtr(c.CompletedAt),
		CancelledAt: tsStrPtr(c.CancelledAt), CancelReason: c.CancelReason,
		TerminatedAt: tsStrPtr(c.TerminatedAt), TerminationReason: c.TerminationReason,
	}
}

func (h *ProjectHandler) GetProjectContract(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	c, err := h.svc.GetProjectContract(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toContractResponse(*c))
}

func (h *ProjectHandler) CreateProjectContract(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	c, err := h.svc.CreateProjectContract(r.Context(), chi.URLParam(r, "id"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toContractResponse(*c))
}

type contractDraftRequest struct {
	Scope                 string  `json:"scope"`
	PaymentTerms          string  `json:"payment_terms"`
	RetentionTerms        string  `json:"retention_terms"`
	AdvanceTerms          string  `json:"advance_terms"`
	EffectiveDate         *string `json:"effective_date"`
	PlannedCompletionDate *string `json:"planned_completion_date"`
}

func (h *ProjectHandler) UpdateProjectContractDraft(w http.ResponseWriter, r *http.Request) {
	var req contractDraftRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	c, err := h.svc.UpdateProjectContractDraft(r.Context(), chi.URLParam(r, "id"), orgID, service.ContractDraftInput{
		Scope: req.Scope, PaymentTerms: req.PaymentTerms, RetentionTerms: req.RetentionTerms, AdvanceTerms: req.AdvanceTerms,
		EffectiveDate: parseDateParam(req.EffectiveDate), PlannedCompletionDate: parseDateParam(req.PlannedCompletionDate),
		UserID: userID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toContractResponse(*c))
}

type contractNotesRequest struct {
	InternalNotes string `json:"internal_notes"`
}

func (h *ProjectHandler) UpdateProjectContractNotes(w http.ResponseWriter, r *http.Request) {
	var req contractNotesRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	c, err := h.svc.UpdateProjectContractNotes(r.Context(), chi.URLParam(r, "id"), orgID, userID, req.InternalNotes)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toContractResponse(*c))
}

func (h *ProjectHandler) ActivateProjectContract(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	c, err := h.svc.ActivateProjectContract(r.Context(), chi.URLParam(r, "id"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toContractResponse(*c))
}

func (h *ProjectHandler) CompleteProjectContract(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	c, err := h.svc.CompleteProjectContract(r.Context(), chi.URLParam(r, "id"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toContractResponse(*c))
}

func (h *ProjectHandler) CancelProjectContract(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	_ = httpjson.Decode(r, &req)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	c, err := h.svc.CancelProjectContract(r.Context(), chi.URLParam(r, "id"), orgID, userID, req.Reason)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toContractResponse(*c))
}

func (h *ProjectHandler) TerminateProjectContract(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	_ = httpjson.Decode(r, &req)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	c, err := h.svc.TerminateProjectContract(r.Context(), chi.URLParam(r, "id"), orgID, userID, req.Reason)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toContractResponse(*c))
}
