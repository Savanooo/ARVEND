package handler

import (
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// ARVEND V2 — Sprint 5 follow-up: Taşeron Ödemeleri (Subcontract Payments,
// bkz. migration 0039). collectionResponse/collectionRequest
// (project_finance_handler.go) İLE AYNI desen -- durum makinesi yok,
// create+void.

type subcontractPaymentResponse struct {
	ID              string  `json:"id"`
	SubcontractID   string  `json:"subcontract_id"`
	ProgressClaimID *string `json:"progress_claim_id"`
	Amount          float64 `json:"amount"`
	Currency        string  `json:"currency"`
	PaidDate        string  `json:"paid_date"`
	PaymentMethod   string  `json:"payment_method"`
	ReferenceNo     string  `json:"reference_no"`
	Description     string  `json:"description"`
	VoidedAt        *string `json:"voided_at"`
	VoidReason      string  `json:"void_reason"`
	CreatedAt       string  `json:"created_at"`
}

func toSubcontractPaymentResponse(p domain.SubcontractPayment) subcontractPaymentResponse {
	return subcontractPaymentResponse{
		ID: p.ID, SubcontractID: p.SubcontractID, ProgressClaimID: p.ProgressClaimID,
		Amount: p.Amount, Currency: p.Currency, PaidDate: p.PaidDate.Format(dateLayout),
		PaymentMethod: p.PaymentMethod, ReferenceNo: p.ReferenceNo, Description: p.Description,
		VoidedAt: tsStrPtr(p.VoidedAt), VoidReason: p.VoidReason, CreatedAt: p.CreatedAt.Format(rfc3339),
	}
}

type subcontractPaymentRequest struct {
	ProgressClaimID string  `json:"progress_claim_id"`
	Amount          float64 `json:"amount"`
	Currency        string  `json:"currency"`
	PaidDate        string  `json:"paid_date"`
	PaymentMethod   string  `json:"payment_method"`
	ReferenceNo     string  `json:"reference_no"`
	Description     string  `json:"description"`
	IdempotencyKey  string  `json:"idempotency_key"`
}

func (h *ProjectHandler) ListSubcontractPayments(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListSubcontractPayments(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "subcontractId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]subcontractPaymentResponse, len(rows))
	for i, p := range rows {
		out[i] = toSubcontractPaymentResponse(p)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"payments": out})
}

func (h *ProjectHandler) CreateSubcontractPayment(w http.ResponseWriter, r *http.Request) {
	var req subcontractPaymentRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	paidDate, ok := requestDate(w, req.PaidDate)
	if !ok {
		return
	}
	p, err := h.svc.CreateSubcontractPayment(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "subcontractId"), orgID, service.SubcontractPaymentInput{
		ProgressClaimID: req.ProgressClaimID,
		Amount:          req.Amount,
		Currency:        req.Currency,
		PaidDate:        paidDate,
		PaymentMethod:   req.PaymentMethod,
		ReferenceNo:     req.ReferenceNo,
		Description:     req.Description,
		IdempotencyKey:  req.IdempotencyKey,
		UserID:          userID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toSubcontractPaymentResponse(*p))
}

func (h *ProjectHandler) VoidSubcontractPayment(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	_ = httpjson.Decode(r, &req)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.VoidSubcontractPayment(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "paymentId"), orgID, userID, req.Reason)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toSubcontractPaymentResponse(*p))
}
