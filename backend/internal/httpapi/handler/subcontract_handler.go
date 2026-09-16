package handler

import (
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// ARVEND V2 — Sprint 5: Taşeron Yönetimi, Subcontract uçları.

type subcontractResponse struct {
	ID             string  `json:"id"`
	SubcontractNo  string  `json:"subcontract_no"`
	SupplierID     string  `json:"supplier_id"`
	SupplierCode   string  `json:"supplier_code,omitempty"`
	SupplierName   string  `json:"supplier_name,omitempty"`
	Title          string  `json:"title"`
	ScopeSummary   string  `json:"scope_summary"`
	OriginalAmount float64 `json:"original_amount"`
	Currency       string  `json:"currency"`
	Status         string  `json:"status"`

	EffectiveDate         *string  `json:"effective_date,omitempty"`
	StartDate             *string  `json:"start_date,omitempty"`
	PlannedCompletionDate *string  `json:"planned_completion_date,omitempty"`
	RetentionPercent      *float64 `json:"retention_percent,omitempty"`
	AdvanceAmount         *float64 `json:"advance_amount,omitempty"`
	PaymentTerms          string   `json:"payment_terms"`
	Notes                 string   `json:"notes"`

	ActivatedAt *string `json:"activated_at,omitempty"`
	CompletedAt *string `json:"completed_at,omitempty"`

	CancelledAt  *string `json:"cancelled_at,omitempty"`
	CancelReason string  `json:"cancel_reason,omitempty"`

	TerminatedAt      *string `json:"terminated_at,omitempty"`
	TerminationReason string  `json:"termination_reason,omitempty"`

	CreatedAt string `json:"created_at"`
	UpdatedAt string `json:"updated_at"`
}

func toSubcontractResponse(sc domain.Subcontract) subcontractResponse {
	return subcontractResponse{
		ID: sc.ID, SubcontractNo: sc.SubcontractNo, SupplierID: sc.SupplierID,
		Title: sc.Title, ScopeSummary: sc.ScopeSummary, OriginalAmount: sc.OriginalAmount,
		Currency: sc.Currency, Status: sc.Status,
		EffectiveDate: dateStrPtr(sc.EffectiveDate), StartDate: dateStrPtr(sc.StartDate),
		PlannedCompletionDate: dateStrPtr(sc.PlannedCompletionDate),
		RetentionPercent:      sc.RetentionPercent, AdvanceAmount: sc.AdvanceAmount,
		PaymentTerms: sc.PaymentTerms, Notes: sc.Notes,
		ActivatedAt: tsStrPtr(sc.ActivatedAt), CompletedAt: tsStrPtr(sc.CompletedAt),
		CancelledAt: tsStrPtr(sc.CancelledAt), CancelReason: sc.CancelReason,
		TerminatedAt: tsStrPtr(sc.TerminatedAt), TerminationReason: sc.TerminationReason,
		CreatedAt: sc.CreatedAt.Format(rfc3339), UpdatedAt: sc.UpdatedAt.Format(rfc3339),
	}
}

func toSubcontractDetailedResponse(sc repository.SubcontractDetailed) subcontractResponse {
	resp := toSubcontractResponse(sc.Subcontract)
	resp.SupplierCode = sc.SupplierCode
	resp.SupplierName = sc.SupplierName
	return resp
}

type subcontractItemResponse struct {
	ID             string   `json:"id"`
	WBSNodeID      *string  `json:"wbs_node_id,omitempty"`
	CostCodeID     string   `json:"cost_code_id"`
	BudgetLineID   *string  `json:"budget_line_id,omitempty"`
	Description    string   `json:"description"`
	Quantity       *float64 `json:"quantity,omitempty"`
	Unit           string   `json:"unit"`
	UnitPrice      *float64 `json:"unit_price,omitempty"`
	OriginalAmount float64  `json:"original_amount"`
	SortOrder      int      `json:"sort_order"`
}

func toSubcontractItemResponse(i domain.SubcontractItem) subcontractItemResponse {
	return subcontractItemResponse{
		ID: i.ID, WBSNodeID: i.WBSNodeID, CostCodeID: i.CostCodeID, BudgetLineID: i.BudgetLineID,
		Description: i.Description, Quantity: i.Quantity, Unit: i.Unit, UnitPrice: i.UnitPrice,
		OriginalAmount: i.OriginalAmount, SortOrder: i.SortOrder,
	}
}

type subcontractItemRequest struct {
	WBSNodeID      string   `json:"wbs_node_id"`
	CostCodeID     string   `json:"cost_code_id"`
	BudgetLineID   string   `json:"budget_line_id"`
	Description    string   `json:"description"`
	Quantity       *float64 `json:"quantity"`
	Unit           string   `json:"unit"`
	UnitPrice      *float64 `json:"unit_price"`
	OriginalAmount float64  `json:"original_amount"`
}

type subcontractRequest struct {
	SupplierID            string                   `json:"supplier_id"`
	Title                 string                   `json:"title"`
	ScopeSummary          string                   `json:"scope_summary"`
	EffectiveDate         *string                  `json:"effective_date"`
	StartDate             *string                  `json:"start_date"`
	PlannedCompletionDate *string                  `json:"planned_completion_date"`
	RetentionPercent      *float64                 `json:"retention_percent"`
	AdvanceAmount         *float64                 `json:"advance_amount"`
	PaymentTerms          string                   `json:"payment_terms"`
	Notes                 string                   `json:"notes"`
	Items                 []subcontractItemRequest `json:"items"`
}

func (req subcontractRequest) toInput(userID string) service.SubcontractInput {
	items := make([]service.SubcontractItemInput, len(req.Items))
	for i, it := range req.Items {
		items[i] = service.SubcontractItemInput{
			WBSNodeID: it.WBSNodeID, CostCodeID: it.CostCodeID, BudgetLineID: it.BudgetLineID,
			Description: it.Description, Quantity: it.Quantity, Unit: it.Unit, UnitPrice: it.UnitPrice,
			OriginalAmount: it.OriginalAmount,
		}
	}
	return service.SubcontractInput{
		SupplierID: req.SupplierID, Title: req.Title, ScopeSummary: req.ScopeSummary,
		EffectiveDate: parseDateParam(req.EffectiveDate), StartDate: parseDateParam(req.StartDate),
		PlannedCompletionDate: parseDateParam(req.PlannedCompletionDate),
		RetentionPercent:      req.RetentionPercent, AdvanceAmount: req.AdvanceAmount,
		PaymentTerms: req.PaymentTerms, Notes: req.Notes, Items: items, UserID: userID,
	}
}

func (h *ProjectHandler) ListSubcontracts(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListSubcontracts(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]subcontractResponse, len(rows))
	for i, sc := range rows {
		out[i] = toSubcontractDetailedResponse(sc)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"subcontracts": out})
}

func (h *ProjectHandler) CreateSubcontract(w http.ResponseWriter, r *http.Request) {
	var req subcontractRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	sc, err := h.svc.CreateSubcontract(r.Context(), chi.URLParam(r, "id"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toSubcontractResponse(*sc))
}

func (h *ProjectHandler) GetSubcontract(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	projectID, scID := chi.URLParam(r, "id"), chi.URLParam(r, "subcontractId")
	sc, err := h.svc.GetSubcontract(r.Context(), projectID, scID, orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	items, err := h.svc.ListSubcontractItems(r.Context(), projectID, scID, orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	value, err := h.svc.GetSubcontractValue(r.Context(), projectID, scID, orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	commitments, err := h.svc.ListCommitmentsForSubcontract(r.Context(), projectID, scID, orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	itemsOut := make([]subcontractItemResponse, len(items))
	for i, it := range items {
		itemsOut[i] = toSubcontractItemResponse(it)
	}
	commitmentsOut := make([]commitmentResponse, len(commitments))
	for i, c := range commitments {
		commitmentsOut[i] = toCommitmentResponse(c)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{
		"subcontract": toSubcontractDetailedResponse(*sc), "items": itemsOut,
		"current_value": map[string]any{
			"original_amount": value.OriginalAmount, "approved_additions": value.ApprovedAdditions,
			"approved_deductions": value.ApprovedDeductions, "pending_additions": value.PendingAdditions,
			"pending_deductions": value.PendingDeductions, "current_value": value.CurrentValue,
			"certified_to_date": value.CertifiedToDate, "remaining_commitment": value.RemainingCommitment,
		},
		"commitments": commitmentsOut,
	})
}

func (h *ProjectHandler) UpdateSubcontract(w http.ResponseWriter, r *http.Request) {
	var req subcontractRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	sc, err := h.svc.UpdateSubcontractDraft(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "subcontractId"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toSubcontractResponse(*sc))
}

func (h *ProjectHandler) ActivateSubcontract(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	sc, err := h.svc.ActivateSubcontract(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "subcontractId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toSubcontractResponse(*sc))
}

func (h *ProjectHandler) CompleteSubcontract(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	sc, err := h.svc.CompleteSubcontract(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "subcontractId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toSubcontractResponse(*sc))
}

func (h *ProjectHandler) CancelSubcontract(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	_ = httpjson.Decode(r, &req)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	sc, err := h.svc.CancelSubcontract(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "subcontractId"), orgID, userID, req.Reason)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toSubcontractResponse(*sc))
}

func (h *ProjectHandler) TerminateSubcontract(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	_ = httpjson.Decode(r, &req)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	sc, err := h.svc.TerminateSubcontract(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "subcontractId"), orgID, userID, req.Reason)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toSubcontractResponse(*sc))
}
