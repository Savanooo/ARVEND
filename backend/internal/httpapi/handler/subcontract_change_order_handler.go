package handler

import (
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// ARVEND V2 — Sprint 5: Taşeron Yönetimi, Subcontract Change Order uçları.
// Customer Change Order (Sprint 3) uçlarıyla HİÇBİR İLİŞKİSİ YOKTUR.

type subcontractChangeOrderResponse struct {
	ID            string  `json:"id"`
	SubcontractID string  `json:"subcontract_id"`
	Number        string  `json:"number"`
	Title         string  `json:"title"`
	Description   string  `json:"description"`
	ChangeType    string  `json:"change_type"`
	Amount        float64 `json:"amount"`
	Status        string  `json:"status"`
	Reason        string  `json:"reason"`

	RequestedAt *string `json:"requested_at,omitempty"`
	ApprovedAt  *string `json:"approved_at,omitempty"`

	RejectedAt      *string `json:"rejected_at,omitempty"`
	RejectionReason string  `json:"rejection_reason,omitempty"`

	CancelledAt *string `json:"cancelled_at,omitempty"`

	CreatedAt string `json:"created_at"`
	UpdatedAt string `json:"updated_at"`
}

func toSubcontractChangeOrderResponse(co domain.SubcontractChangeOrder) subcontractChangeOrderResponse {
	return subcontractChangeOrderResponse{
		ID: co.ID, SubcontractID: co.SubcontractID, Number: co.Number,
		Title: co.Title, Description: co.Description, ChangeType: co.ChangeType, Amount: co.Amount,
		Status: co.Status, Reason: co.Reason,
		RequestedAt: tsStrPtr(co.RequestedAt), ApprovedAt: tsStrPtr(co.ApprovedAt),
		RejectedAt: tsStrPtr(co.RejectedAt), RejectionReason: co.RejectionReason,
		CancelledAt: tsStrPtr(co.CancelledAt),
		CreatedAt:   co.CreatedAt.Format(rfc3339), UpdatedAt: co.UpdatedAt.Format(rfc3339),
	}
}

type subcontractChangeOrderItemResponse struct {
	ID           string  `json:"id"`
	WBSNodeID    *string `json:"wbs_node_id,omitempty"`
	CostCodeID   string  `json:"cost_code_id"`
	BudgetLineID *string `json:"budget_line_id,omitempty"`
	Description  string  `json:"description"`
	Amount       float64 `json:"amount"`
	SortOrder    int     `json:"sort_order"`
}

func toSubcontractChangeOrderItemResponse(i domain.SubcontractChangeOrderItem) subcontractChangeOrderItemResponse {
	return subcontractChangeOrderItemResponse{
		ID: i.ID, WBSNodeID: i.WBSNodeID, CostCodeID: i.CostCodeID, BudgetLineID: i.BudgetLineID,
		Description: i.Description, Amount: i.Amount, SortOrder: i.SortOrder,
	}
}

type subcontractChangeOrderItemRequest struct {
	WBSNodeID    string  `json:"wbs_node_id"`
	CostCodeID   string  `json:"cost_code_id"`
	BudgetLineID string  `json:"budget_line_id"`
	Description  string  `json:"description"`
	Amount       float64 `json:"amount"`
}

type subcontractChangeOrderRequest struct {
	Title       string                              `json:"title"`
	Description string                              `json:"description"`
	ChangeType  string                              `json:"change_type"`
	Reason      string                              `json:"reason"`
	Items       []subcontractChangeOrderItemRequest `json:"items"`
}

func (req subcontractChangeOrderRequest) toInput(userID string) service.SubcontractChangeOrderInput {
	items := make([]service.SubcontractChangeOrderItemInput, len(req.Items))
	for i, it := range req.Items {
		items[i] = service.SubcontractChangeOrderItemInput{
			WBSNodeID: it.WBSNodeID, CostCodeID: it.CostCodeID, BudgetLineID: it.BudgetLineID,
			Description: it.Description, Amount: it.Amount,
		}
	}
	return service.SubcontractChangeOrderInput{
		Title: req.Title, Description: req.Description, ChangeType: req.ChangeType, Reason: req.Reason,
		Items: items, UserID: userID,
	}
}

func (h *ProjectHandler) ListSubcontractChangeOrders(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListSubcontractChangeOrders(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "subcontractId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]subcontractChangeOrderResponse, len(rows))
	for i, co := range rows {
		out[i] = toSubcontractChangeOrderResponse(co)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"subcontract_change_orders": out})
}

func (h *ProjectHandler) CreateSubcontractChangeOrder(w http.ResponseWriter, r *http.Request) {
	var req subcontractChangeOrderRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	co, err := h.svc.CreateSubcontractChangeOrder(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "subcontractId"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toSubcontractChangeOrderResponse(*co))
}

func (h *ProjectHandler) GetSubcontractChangeOrder(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	projectID, coID := chi.URLParam(r, "id"), chi.URLParam(r, "changeOrderId")
	co, err := h.svc.GetSubcontractChangeOrder(r.Context(), projectID, coID, orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	items, err := h.svc.ListSubcontractChangeOrderItems(r.Context(), projectID, coID, orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	itemsOut := make([]subcontractChangeOrderItemResponse, len(items))
	for i, it := range items {
		itemsOut[i] = toSubcontractChangeOrderItemResponse(it)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"subcontract_change_order": toSubcontractChangeOrderResponse(*co), "items": itemsOut})
}

func (h *ProjectHandler) UpdateSubcontractChangeOrder(w http.ResponseWriter, r *http.Request) {
	var req subcontractChangeOrderRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	co, err := h.svc.UpdateSubcontractChangeOrderDraft(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "changeOrderId"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toSubcontractChangeOrderResponse(*co))
}

func (h *ProjectHandler) SubmitSubcontractChangeOrder(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	co, err := h.svc.SubmitSubcontractChangeOrder(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "changeOrderId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toSubcontractChangeOrderResponse(*co))
}

func (h *ProjectHandler) ApproveSubcontractChangeOrder(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	co, err := h.svc.ApproveSubcontractChangeOrder(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "changeOrderId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toSubcontractChangeOrderResponse(*co))
}

func (h *ProjectHandler) RejectSubcontractChangeOrder(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	_ = httpjson.Decode(r, &req)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	co, err := h.svc.RejectSubcontractChangeOrder(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "changeOrderId"), orgID, userID, req.Reason)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toSubcontractChangeOrderResponse(*co))
}

func (h *ProjectHandler) CancelSubcontractChangeOrder(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	co, err := h.svc.CancelSubcontractChangeOrder(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "changeOrderId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toSubcontractChangeOrderResponse(*co))
}
