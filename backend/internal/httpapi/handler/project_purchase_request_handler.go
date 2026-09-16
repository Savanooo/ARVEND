package handler

import (
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// ARVEND V2 — Sprint 4: Procurement Foundation, Purchase Request uçları.
// Mevcut ProjectHandler'a EKLENİR (project_contract_handler.go İLE AYNI
// dosya-başına-endişe deseni).

type purchaseRequestResponse struct {
	ID              string  `json:"id"`
	PRNo            string  `json:"pr_no"`
	Title           string  `json:"title"`
	Description     string  `json:"description"`
	NeededBy        *string `json:"needed_by,omitempty"`
	Status          string  `json:"status"`
	EstimatedTotal  float64 `json:"estimated_total"`
	RequestedBy     *string `json:"requested_by,omitempty"`
	SubmittedAt     *string `json:"submitted_at,omitempty"`
	ApprovedAt      *string `json:"approved_at,omitempty"`
	ApprovedBy      *string `json:"approved_by,omitempty"`
	RejectedAt      *string `json:"rejected_at,omitempty"`
	RejectedBy      *string `json:"rejected_by,omitempty"`
	RejectionReason string  `json:"rejection_reason,omitempty"`
	CancelledAt     *string `json:"cancelled_at,omitempty"`
	CancelledBy     *string `json:"cancelled_by,omitempty"`
	CancelReason    string  `json:"cancel_reason,omitempty"`
	CreatedAt       string  `json:"created_at"`
	UpdatedAt       string  `json:"updated_at"`
}

func toPurchaseRequestResponse(p domain.PurchaseRequest) purchaseRequestResponse {
	return purchaseRequestResponse{
		ID: p.ID, PRNo: p.PRNo, Title: p.Title, Description: p.Description,
		NeededBy: dateStrPtr(p.NeededBy), Status: p.Status, EstimatedTotal: p.EstimatedTotal,
		RequestedBy: p.RequestedBy, SubmittedAt: tsStrPtr(p.SubmittedAt),
		ApprovedAt: tsStrPtr(p.ApprovedAt), ApprovedBy: p.ApprovedBy,
		RejectedAt: tsStrPtr(p.RejectedAt), RejectedBy: p.RejectedBy, RejectionReason: p.RejectionReason,
		CancelledAt: tsStrPtr(p.CancelledAt), CancelledBy: p.CancelledBy, CancelReason: p.CancelReason,
		CreatedAt: p.CreatedAt.Format(rfc3339), UpdatedAt: p.UpdatedAt.Format(rfc3339),
	}
}

type purchaseRequestItemResponse struct {
	ID                string   `json:"id"`
	WBSNodeID         *string  `json:"wbs_node_id,omitempty"`
	CostCodeID        *string  `json:"cost_code_id,omitempty"`
	BudgetLineID      *string  `json:"budget_line_id,omitempty"`
	Description       string   `json:"description"`
	Quantity          float64  `json:"quantity"`
	Unit              string   `json:"unit"`
	EstimatedUnitCost *float64 `json:"estimated_unit_cost,omitempty"`
	EstimatedTotal    float64  `json:"estimated_total"`
	Notes             string   `json:"notes"`
	SortOrder         int      `json:"sort_order"`
}

func toPurchaseRequestItemResponse(i domain.PurchaseRequestItem) purchaseRequestItemResponse {
	return purchaseRequestItemResponse{
		ID: i.ID, WBSNodeID: i.WBSNodeID, CostCodeID: i.CostCodeID, BudgetLineID: i.BudgetLineID,
		Description: i.Description, Quantity: i.Quantity, Unit: i.Unit,
		EstimatedUnitCost: i.EstimatedUnitCost, EstimatedTotal: i.EstimatedTotal, Notes: i.Notes, SortOrder: i.SortOrder,
	}
}

type purchaseRequestItemRequest struct {
	WBSNodeID         string   `json:"wbs_node_id"`
	CostCodeID        string   `json:"cost_code_id"`
	BudgetLineID      string   `json:"budget_line_id"`
	Description       string   `json:"description"`
	Quantity          float64  `json:"quantity"`
	Unit              string   `json:"unit"`
	EstimatedUnitCost *float64 `json:"estimated_unit_cost"`
	EstimatedTotal    float64  `json:"estimated_total"`
	Notes             string   `json:"notes"`
}

type purchaseRequestRequest struct {
	Title       string                       `json:"title"`
	Description string                       `json:"description"`
	NeededBy    *string                      `json:"needed_by"`
	Items       []purchaseRequestItemRequest `json:"items"`
}

func (req purchaseRequestRequest) toInput(userID string) service.PurchaseRequestInput {
	items := make([]service.PurchaseRequestItemInput, len(req.Items))
	for i, it := range req.Items {
		items[i] = service.PurchaseRequestItemInput{
			WBSNodeID: it.WBSNodeID, CostCodeID: it.CostCodeID, BudgetLineID: it.BudgetLineID,
			Description: it.Description, Quantity: it.Quantity, Unit: it.Unit,
			EstimatedUnitCost: it.EstimatedUnitCost, EstimatedTotal: it.EstimatedTotal, Notes: it.Notes,
		}
	}
	return service.PurchaseRequestInput{
		Title: req.Title, Description: req.Description, NeededBy: parseDateParam(req.NeededBy), Items: items, UserID: userID,
	}
}

func (h *ProjectHandler) ListPurchaseRequests(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListPurchaseRequests(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]purchaseRequestResponse, len(rows))
	for i, p := range rows {
		out[i] = toPurchaseRequestResponse(p)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"purchase_requests": out})
}

func (h *ProjectHandler) CreatePurchaseRequest(w http.ResponseWriter, r *http.Request) {
	var req purchaseRequestRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.CreatePurchaseRequest(r.Context(), chi.URLParam(r, "id"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toPurchaseRequestResponse(*p))
}

func (h *ProjectHandler) GetPurchaseRequest(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	p, err := h.svc.GetPurchaseRequest(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "prId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	items, err := h.svc.ListPurchaseRequestItems(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "prId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	itemsOut := make([]purchaseRequestItemResponse, len(items))
	for i, it := range items {
		itemsOut[i] = toPurchaseRequestItemResponse(it)
	}
	resp := toPurchaseRequestResponse(*p)
	httpjson.Write(w, http.StatusOK, map[string]any{"purchase_request": resp, "items": itemsOut})
}

func (h *ProjectHandler) UpdatePurchaseRequest(w http.ResponseWriter, r *http.Request) {
	var req purchaseRequestRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.UpdatePurchaseRequestDraft(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "prId"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPurchaseRequestResponse(*p))
}

func (h *ProjectHandler) SubmitPurchaseRequest(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.SubmitPurchaseRequest(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "prId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPurchaseRequestResponse(*p))
}

func (h *ProjectHandler) WithdrawPurchaseRequest(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.WithdrawPurchaseRequest(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "prId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPurchaseRequestResponse(*p))
}

func (h *ProjectHandler) ApprovePurchaseRequest(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.ApprovePurchaseRequest(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "prId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPurchaseRequestResponse(*p))
}

func (h *ProjectHandler) RejectPurchaseRequest(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	_ = httpjson.Decode(r, &req)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.RejectPurchaseRequest(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "prId"), orgID, userID, req.Reason)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPurchaseRequestResponse(*p))
}

func (h *ProjectHandler) CancelPurchaseRequest(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	_ = httpjson.Decode(r, &req)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.CancelPurchaseRequest(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "prId"), orgID, userID, req.Reason)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPurchaseRequestResponse(*p))
}
