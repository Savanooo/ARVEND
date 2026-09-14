package handler

import (
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type changeOrderItemRequest struct {
	ProductID         *string  `json:"product_id"`
	Description       string   `json:"description"`
	Quantity          float64  `json:"quantity"`
	Unit              string   `json:"unit"`
	UnitPrice         float64  `json:"unit_price"`
	EstimatedUnitCost *float64 `json:"estimated_unit_cost"`
}

type changeOrderRequest struct {
	ChangeType    string                   `json:"change_type"`
	Title         string                   `json:"title"`
	Description   string                   `json:"description"`
	VatRate       float64                  `json:"vat_rate"`
	CustomerNotes string                   `json:"customer_notes"`
	InternalNotes string                   `json:"internal_notes"`
	Items         []changeOrderItemRequest `json:"items"`
}

func (r changeOrderRequest) toInput(userID string) service.ChangeOrderInput {
	items := make([]service.ChangeOrderItemInput, len(r.Items))
	for i, it := range r.Items {
		items[i] = service.ChangeOrderItemInput{
			ProductID: it.ProductID, Description: it.Description, Quantity: it.Quantity,
			Unit: it.Unit, UnitPrice: it.UnitPrice, EstimatedUnitCost: it.EstimatedUnitCost,
		}
	}
	return service.ChangeOrderInput{
		ChangeType: r.ChangeType, Title: r.Title, Description: r.Description, VatRate: r.VatRate,
		CustomerNotes: r.CustomerNotes, InternalNotes: r.InternalNotes, Items: items, UserID: userID,
	}
}

type changeOrderItemResponse struct {
	ID                string   `json:"id"`
	ProductID         *string  `json:"product_id"`
	Description       string   `json:"description"`
	Quantity          float64  `json:"quantity"`
	Unit              string   `json:"unit"`
	UnitPrice         float64  `json:"unit_price"`
	LineTotal         float64  `json:"line_total"`
	SortOrder         int      `json:"sort_order"`
	EstimatedUnitCost *float64 `json:"estimated_unit_cost,omitempty"`
	EstimatedCost     *float64 `json:"estimated_cost,omitempty"`
}

type changeOrderProfitabilityResponse struct {
	RevenueEffect          float64 `json:"revenue_effect"`
	RealizedCost           float64 `json:"realized_cost"`
	CommittedCost          float64 `json:"committed_cost"`
	RealizedProfit         float64 `json:"realized_profit"`
	EstimatedProfit        float64 `json:"estimated_profit"`
	RealizedMarginPercent  float64 `json:"realized_margin_percent"`
	EstimatedMarginPercent float64 `json:"estimated_margin_percent"`
}

// changeOrderResponse, YALNIZCA kimlik doğrulamalı (dahili) uçlarda
// kullanılır -- internal_notes ve profitability (maliyet/kâr) taşır.
// Müşteri paylaşım sayfası bunu ASLA görmez; ayrı bir public DTO
// kullanır (bkz. public_change_order_handler.go).
type changeOrderResponse struct {
	ID                      string                            `json:"id"`
	ProjectID               string                            `json:"project_id"`
	SequenceNo              int                               `json:"sequence_no"`
	ChangeOrderNo           string                            `json:"change_order_no"`
	ChangeType              string                            `json:"change_type"`
	Title                   string                            `json:"title"`
	Description             string                            `json:"description"`
	Status                  string                            `json:"status"`
	Subtotal                float64                           `json:"subtotal"`
	VatRate                 float64                           `json:"vat_rate"`
	VatAmount               float64                           `json:"vat_amount"`
	GrandTotal              float64                           `json:"grand_total"`
	Currency                string                            `json:"currency"`
	InternalNotes           string                            `json:"internal_notes"`
	CustomerNotes           string                            `json:"customer_notes"`
	CreatedBy               *string                           `json:"created_by"`
	CreatedAt               string                            `json:"created_at"`
	UpdatedAt               string                            `json:"updated_at"`
	SentAt                  *string                           `json:"sent_at"`
	RespondedAt             *string                           `json:"responded_at"`
	ApprovedAt              *string                           `json:"approved_at"`
	RejectedAt              *string                           `json:"rejected_at"`
	CancelledAt             *string                           `json:"cancelled_at"`
	SupersedesChangeOrderID *string                           `json:"supersedes_change_order_id"`
	ActiveShareToken        *string                           `json:"active_share_token,omitempty"`
	Items                   []changeOrderItemResponse         `json:"items,omitempty"`
	Profitability           *changeOrderProfitabilityResponse `json:"profitability,omitempty"`
}

func toChangeOrderResponse(co domain.ChangeOrder) changeOrderResponse {
	resp := changeOrderResponse{
		ID: co.ID, ProjectID: co.ProjectID, SequenceNo: co.SequenceNo, ChangeOrderNo: co.ChangeOrderNo(),
		ChangeType: co.ChangeType, Title: co.Title, Description: co.Description, Status: co.Status,
		Subtotal: co.Subtotal, VatRate: co.VatRate, VatAmount: co.VatAmount, GrandTotal: co.GrandTotal,
		Currency: co.Currency, InternalNotes: co.InternalNotes, CustomerNotes: co.CustomerNotes,
		CreatedBy: co.CreatedBy, CreatedAt: co.CreatedAt.Format(rfc3339), UpdatedAt: co.UpdatedAt.Format(rfc3339),
		SentAt: tsStrPtr(co.SentAt), RespondedAt: tsStrPtr(co.RespondedAt), ApprovedAt: tsStrPtr(co.ApprovedAt),
		RejectedAt: tsStrPtr(co.RejectedAt), CancelledAt: tsStrPtr(co.CancelledAt),
		SupersedesChangeOrderID: co.SupersedesChangeOrderID,
		ActiveShareToken:        co.ActiveShareToken,
	}
	if len(co.Items) > 0 {
		resp.Items = make([]changeOrderItemResponse, len(co.Items))
		for i, it := range co.Items {
			resp.Items[i] = changeOrderItemResponse{
				ID: it.ID, ProductID: it.ProductID, Description: it.Description, Quantity: it.Quantity,
				Unit: it.Unit, UnitPrice: it.UnitPrice, LineTotal: it.LineTotal, SortOrder: it.SortOrder,
				EstimatedUnitCost: it.EstimatedUnitCost, EstimatedCost: it.EstimatedCost,
			}
		}
	}
	if co.Profitability != nil {
		p := co.Profitability
		resp.Profitability = &changeOrderProfitabilityResponse{
			RevenueEffect: p.RevenueEffect, RealizedCost: p.RealizedCost, CommittedCost: p.CommittedCost,
			RealizedProfit: p.RealizedProfit, EstimatedProfit: p.EstimatedProfit,
			RealizedMarginPercent: p.RealizedMarginPercent, EstimatedMarginPercent: p.EstimatedMarginPercent,
		}
	}
	return resp
}

func (h *ProjectHandler) ListChangeOrders(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListChangeOrders(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]changeOrderResponse, len(rows))
	for i, co := range rows {
		out[i] = toChangeOrderResponse(co)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"change_orders": out})
}

func (h *ProjectHandler) GetChangeOrder(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	co, err := h.svc.GetChangeOrder(r.Context(), chi.URLParam(r, "changeOrderId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toChangeOrderResponse(*co))
}

func (h *ProjectHandler) CreateChangeOrder(w http.ResponseWriter, r *http.Request) {
	var req changeOrderRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	co, err := h.svc.CreateChangeOrder(r.Context(), chi.URLParam(r, "id"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toChangeOrderResponse(*co))
}

func (h *ProjectHandler) UpdateChangeOrder(w http.ResponseWriter, r *http.Request) {
	var req changeOrderRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	co, err := h.svc.UpdateChangeOrderDraft(r.Context(), chi.URLParam(r, "changeOrderId"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toChangeOrderResponse(*co))
}

func (h *ProjectHandler) SendChangeOrder(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	co, err := h.svc.SendChangeOrder(r.Context(), chi.URLParam(r, "changeOrderId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toChangeOrderResponse(*co))
}

type changeOrderEmailRequest struct {
	To      string `json:"to"`
	Subject string `json:"subject"`
	Message string `json:"message"`
}

func (h *ProjectHandler) SendChangeOrderEmail(w http.ResponseWriter, r *http.Request) {
	var req changeOrderEmailRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	err := h.svc.SendChangeOrderEmail(r.Context(), chi.URLParam(r, "changeOrderId"), orgID, service.ChangeOrderEmailInput{
		To: req.To, Subject: req.Subject, Message: req.Message, UserID: userID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"status": "sent"})
}

func (h *ProjectHandler) CancelChangeOrder(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	co, err := h.svc.CancelChangeOrder(r.Context(), chi.URLParam(r, "changeOrderId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toChangeOrderResponse(*co))
}

func (h *ProjectHandler) ReviseChangeOrder(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	co, err := h.svc.ReviseChangeOrder(r.Context(), chi.URLParam(r, "changeOrderId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toChangeOrderResponse(*co))
}
