package handler

import (
	"errors"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// Taşeronlar (migration 0069). İzin kapıları router'da: liste ve kart
// organization.suppliers.read, kart açma organization.suppliers.manage,
// taşeronun ödeme defteri projects.finance.read, proje dışı ödeme
// projects.finance.manage.

type moneyAmountResponse struct {
	Currency string  `json:"currency"`
	Amount   float64 `json:"amount"`
}

type subcontractorCardResponse struct {
	supplierResponse
	// PaidTotals: para birimi başına ödenen (iptaller hariç) -- yalnızca
	// finans okuyabilene; diğerlerinde alan gelmez.
	PaidTotals []moneyAmountResponse `json:"paid_totals,omitempty"`
}

// ListSubcontractorCards: GET /subcontractors.
func (h *SupplierHandler) ListSubcontractorCards(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	authz, ok := middleware.AuthzContextFromRequest(r.Context())
	withTotals := ok && authz.HasPermission(domain.PermProjectsFinanceRead)
	restrict := ""
	if !ok || !authz.BypassesProjectMembership() {
		restrict = userID
	}
	cards, err := h.svc.ListSubcontractorCards(r.Context(), orgID, withTotals, restrict)
	if err != nil {
		h.writeSubcontractorError(w, err)
		return
	}
	out := make([]subcontractorCardResponse, len(cards))
	for i, c := range cards {
		out[i] = subcontractorCardResponse{supplierResponse: toSupplierResponse(c.Supplier)}
		if withTotals {
			out[i].PaidTotals = make([]moneyAmountResponse, len(c.PaidTotals))
			for j, t := range c.PaidTotals {
				out[i].PaidTotals[j] = moneyAmountResponse{Currency: t.Currency, Amount: t.Amount}
			}
		}
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"subcontractors": out, "can_see_totals": withTotals})
}

// CreateSubcontractorCard: POST /subcontractors (tedarikçi gövdesi; kod
// boşsa TSR-NNNN).
func (h *SupplierHandler) CreateSubcontractorCard(w http.ResponseWriter, r *http.Request) {
	var req supplierRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	s, err := h.svc.CreateSubcontractorCard(r.Context(), orgID, req.toInput(userID))
	if err != nil {
		h.writeSubcontractorError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toSupplierResponse(*s))
}

// MarkAsSubcontractor: POST /subcontractors/{id}/mark -- katalogdaki
// tedarikçiyi Taşeronlar'a ekler.
func (h *SupplierHandler) MarkAsSubcontractor(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	s, err := h.svc.MarkAsSubcontractor(r.Context(), orgID, chi.URLParam(r, "id"), userID)
	if err != nil {
		h.writeSubcontractorError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toSupplierResponse(*s))
}

type subcontractorEngagementResponse struct {
	Kind            string  `json:"kind"`
	ID              string  `json:"id"`
	ProjectID       string  `json:"project_id"`
	ProjectName     string  `json:"project_name"`
	ProjectNo       string  `json:"project_no"`
	ProjectStatus   string  `json:"project_status"`
	Title           string  `json:"title"`
	Status          string  `json:"status"`
	Currency        string  `json:"currency"`
	ContractAmount  float64 `json:"contract_amount"`
	PaidAmount      float64 `json:"paid_amount"`
	RemainingAmount float64 `json:"remaining_amount"`
}

type subcontractorLedgerPaymentResponse struct {
	Source       string  `json:"source"`
	ID           string  `json:"id"`
	ProjectID    *string `json:"project_id"`
	ProjectName  string  `json:"project_name"`
	ProjectNo    string  `json:"project_no"`
	EngagementID *string `json:"engagement_id"`
	Amount       float64 `json:"amount"`
	Currency     string  `json:"currency"`
	PaidDate     string  `json:"paid_date"`
	Description  string  `json:"description"`
	VoidedAt     *string `json:"voided_at"`
	VoidReason   string  `json:"void_reason"`
}

func nonEmptyPtr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func toLedgerPaymentResponse(p domain.SubcontractorLedgerPayment) subcontractorLedgerPaymentResponse {
	return subcontractorLedgerPaymentResponse{
		Source: p.Source, ID: p.ID, ProjectID: nonEmptyPtr(p.ProjectID), ProjectName: p.ProjectName,
		ProjectNo: p.ProjectNo, EngagementID: nonEmptyPtr(p.EngagementID), Amount: p.Amount,
		Currency: p.Currency, PaidDate: p.PaidDate.Format(dateLayout), Description: p.Description,
		VoidedAt: tsStrPtr(p.VoidedAt), VoidReason: p.VoidReason,
	}
}

// GetSubcontractorLedger: GET /subcontractors/{id}/ledger -- kart,
// projelerdeki işleri, bütün ödemeleri ve para birimi başına ödenen toplam.
func (h *SupplierHandler) GetSubcontractorLedger(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	restrict := ""
	if authz, ok := middleware.AuthzContextFromRequest(r.Context()); !ok || !authz.BypassesProjectMembership() {
		restrict = userID
	}
	ledger, err := h.svc.GetSubcontractorLedger(r.Context(), orgID, chi.URLParam(r, "id"), restrict)
	if err != nil {
		h.writeSubcontractorError(w, err)
		return
	}
	engagements := make([]subcontractorEngagementResponse, len(ledger.Engagements))
	for i, e := range ledger.Engagements {
		remaining := e.ContractAmount - e.PaidAmount
		if remaining < 0 {
			remaining = 0
		}
		engagements[i] = subcontractorEngagementResponse{
			Kind: e.Kind, ID: e.ID, ProjectID: e.ProjectID, ProjectName: e.ProjectName, ProjectNo: e.ProjectNo,
			ProjectStatus: e.ProjectStatus, Title: e.Title, Status: e.Status, Currency: e.Currency,
			ContractAmount: e.ContractAmount, PaidAmount: e.PaidAmount, RemainingAmount: roundMoney(remaining),
		}
	}
	payments := make([]subcontractorLedgerPaymentResponse, len(ledger.Payments))
	totals := map[string]float64{}
	var order []string
	for i, p := range ledger.Payments {
		payments[i] = toLedgerPaymentResponse(p)
		if p.VoidedAt != nil {
			continue
		}
		if _, seen := totals[p.Currency]; !seen {
			order = append(order, p.Currency)
		}
		totals[p.Currency] += p.Amount
	}
	paid := make([]moneyAmountResponse, 0, len(order))
	for _, c := range order {
		paid = append(paid, moneyAmountResponse{Currency: c, Amount: roundMoney(totals[c])})
	}
	httpjson.Write(w, http.StatusOK, map[string]any{
		"subcontractor": toSupplierResponse(ledger.Card),
		"engagements":   engagements,
		"payments":      payments,
		"paid_totals":   paid,
	})
}

type directPaymentRequest struct {
	Amount         float64 `json:"amount"`
	Currency       string  `json:"currency"`
	PaidDate       string  `json:"paid_date"`
	Description    string  `json:"description"`
	IdempotencyKey string  `json:"idempotency_key"`
}

// CreateDirectPayment: POST /subcontractors/{id}/payments -- proje dışı
// ödeme (projects.finance.manage).
func (h *SupplierHandler) CreateDirectPayment(w http.ResponseWriter, r *http.Request) {
	var req directPaymentRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	paid := time.Now()
	if req.PaidDate != "" {
		t, err := time.Parse(dateLayout, req.PaidDate)
		if err != nil {
			httpjson.Error(w, http.StatusBadRequest, "geçersiz ödeme tarihi (YYYY-AA-GG bekleniyor)")
			return
		}
		paid = t
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.CreateDirectPayment(r.Context(), orgID, chi.URLParam(r, "id"), service.DirectPaymentInput{
		Amount: req.Amount, Currency: req.Currency, PaidDate: paid, Description: req.Description,
		IdempotencyKey: req.IdempotencyKey, UserID: userID,
	})
	if err != nil {
		h.writeSubcontractorError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toLedgerPaymentResponse(*p))
}

// VoidDirectPayment: POST /subcontractors/{id}/payments/{paymentId}/void {reason}.
func (h *SupplierHandler) VoidDirectPayment(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	_ = httpjson.Decode(r, &req)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.VoidDirectPayment(r.Context(), orgID, chi.URLParam(r, "id"), chi.URLParam(r, "paymentId"), userID, req.Reason)
	if err != nil {
		h.writeSubcontractorError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toLedgerPaymentResponse(*p))
}

func (h *SupplierHandler) writeSubcontractorError(w http.ResponseWriter, err error) {
	var notFound *service.NotFoundError
	switch {
	case errors.As(err, &notFound):
		httpjson.Error(w, http.StatusNotFound, notFound.Error())
	case errors.Is(err, service.ErrSubcontractorCardArchived),
		errors.Is(err, service.ErrExpenseIdempotencyKeyInUse):
		httpjson.Error(w, http.StatusConflict, err.Error())
	default:
		h.writeError(w, err)
	}
}
