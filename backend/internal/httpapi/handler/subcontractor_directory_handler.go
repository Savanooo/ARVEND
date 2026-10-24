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
	// RemainingTotals: para birimi başına kalan borç -- aynı kural.
	RemainingTotals []moneyAmountResponse `json:"remaining_totals,omitempty"`
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
			out[i].RemainingTotals = make([]moneyAmountResponse, len(c.RemainingTotals))
			for j, t := range c.RemainingTotals {
				out[i].RemainingTotals[j] = moneyAmountResponse{Currency: t.Currency, Amount: roundMoney(t.Amount)}
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
	// kind: "work" | "advance" | "general" (proje dışı genel ödeme).
	Kind string `json:"kind"`
}

// subcontractorSiteDayResponse: günlük raporlardan sahada çalıştığı gün.
type subcontractorSiteDayResponse struct {
	ReportDate  string `json:"report_date"`
	ProjectID   string `json:"project_id"`
	ProjectName string `json:"project_name"`
	ProjectNo   string `json:"project_no"`
	Workers     int    `json:"workers"`
	WorkNote    string `json:"work_note"`
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
		VoidedAt: tsStrPtr(p.VoidedAt), VoidReason: p.VoidReason, Kind: p.Kind,
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
	siteDays := make([]subcontractorSiteDayResponse, len(ledger.SiteDays))
	for i, d := range ledger.SiteDays {
		siteDays[i] = subcontractorSiteDayResponse{
			ReportDate: d.ReportDate.Format(dateLayout), ProjectID: d.ProjectID, ProjectName: d.ProjectName,
			ProjectNo: d.ProjectNo, Workers: d.Workers, WorkNote: d.WorkNote,
		}
	}
	httpjson.Write(w, http.StatusOK, map[string]any{
		"subcontractor": toSupplierResponse(ledger.Card),
		"engagements":   engagements,
		"payments":      payments,
		"paid_totals":   paid,
		"site_days":     siteDays,
	})
}

type directPaymentRequest struct {
	Amount         float64 `json:"amount"`
	Currency       string  `json:"currency"`
	PaidDate       string  `json:"paid_date"`
	Description    string  `json:"description"`
	IdempotencyKey string  `json:"idempotency_key"`
	// payment_kind: "general" (boşsa) | "advance".
	PaymentKind string `json:"payment_kind"`
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
		IdempotencyKey: req.IdempotencyKey, UserID: userID, PaymentKind: req.PaymentKind,
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
	case errors.Is(err, domain.ErrDuplicateUsername):
		httpjson.Error(w, http.StatusConflict, "bu kullanıcı adı zaten kullanılıyor")
	default:
		h.writeError(w, err)
	}
}

// ---------- Taşeron Paneli: firma tarafı (migration 0075) ----------

type portalUserResponse struct {
	ID                 string  `json:"id"`
	Username           string  `json:"username"`
	FullName           string  `json:"full_name"`
	IsActive           bool    `json:"is_active"`
	MustChangePassword bool    `json:"must_change_password"`
	LastLoginAt        *string `json:"last_login_at"`
	CreatedAt          string  `json:"created_at"`
}

func toPortalUserResponse(u domain.PortalUser) portalUserResponse {
	return portalUserResponse{
		ID: u.ID, Username: u.Username, FullName: u.FullName, IsActive: u.IsActive,
		MustChangePassword: u.MustChangePassword, LastLoginAt: tsStrPtr(u.LastLoginAt),
		CreatedAt: u.CreatedAt.Format(rfc3339),
	}
}

type portalProjectChoiceResponse struct {
	ID            string `json:"id"`
	ProjectNo     string `json:"project_no"`
	Name          string `json:"name"`
	Status        string `json:"status"`
	Granted       bool   `json:"granted"`
	HasEngagement bool   `json:"has_engagement"`
}

func toPortalSettingsResponse(s service.PortalSettings) map[string]any {
	users := make([]portalUserResponse, len(s.Users))
	for i, u := range s.Users {
		users[i] = toPortalUserResponse(u)
	}
	projects := make([]portalProjectChoiceResponse, len(s.Projects))
	for i, p := range s.Projects {
		projects[i] = portalProjectChoiceResponse{
			ID: p.ID, ProjectNo: p.ProjectNo, Name: p.Name, Status: p.Status,
			Granted: p.Granted, HasEngagement: p.HasEngagement,
		}
	}
	return map[string]any{"users": users, "projects": projects}
}

// GetPortalSettings: GET /subcontractors/{id}/portal -- kartın girişleri ve
// proje izinleri.
func (h *SupplierHandler) GetPortalSettings(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	s, err := h.svc.GetPortalSettings(r.Context(), orgID, chi.URLParam(r, "id"))
	if err != nil {
		h.writeSubcontractorError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPortalSettingsResponse(*s))
}

type portalUserRequest struct {
	FullName          string `json:"full_name"`
	Username          string `json:"username"`
	TemporaryPassword string `json:"temporary_password"`
}

// CreatePortalUser: POST /subcontractors/{id}/portal/users -- giriş açar.
func (h *SupplierHandler) CreatePortalUser(w http.ResponseWriter, r *http.Request) {
	var req portalUserRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	u, err := h.svc.CreatePortalUser(r.Context(), orgID, chi.URLParam(r, "id"), service.PortalUserInput{
		FullName: req.FullName, Username: req.Username, TemporaryPassword: req.TemporaryPassword, ActorUserID: userID,
	})
	if err != nil {
		h.writeSubcontractorError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toPortalUserResponse(*u))
}

// ResetPortalUserPassword: POST /subcontractors/{id}/portal/users/{userId}/password
// {temporary_password} -- yeni geçici şifre; açık oturumlar kapanır.
func (h *SupplierHandler) ResetPortalUserPassword(w http.ResponseWriter, r *http.Request) {
	var req struct {
		TemporaryPassword string `json:"temporary_password"`
	}
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	u, err := h.svc.ResetPortalUserPassword(r.Context(), orgID, chi.URLParam(r, "id"), chi.URLParam(r, "userId"),
		req.TemporaryPassword, userID)
	if err != nil {
		h.writeSubcontractorError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPortalUserResponse(*u))
}

// SetPortalUserActive: POST /subcontractors/{id}/portal/users/{userId}/active {active}.
func (h *SupplierHandler) SetPortalUserActive(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Active *bool `json:"active"`
	}
	if err := httpjson.Decode(r, &req); err != nil || req.Active == nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	u, err := h.svc.SetPortalUserActive(r.Context(), orgID, chi.URLParam(r, "id"), chi.URLParam(r, "userId"), *req.Active, userID)
	if err != nil {
		h.writeSubcontractorError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPortalUserResponse(*u))
}

// SetPortalProjects: PUT /subcontractors/{id}/portal/projects {project_ids} --
// proje izinlerini verilen kümeyle değiştirir.
func (h *SupplierHandler) SetPortalProjects(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ProjectIDs []string `json:"project_ids"`
	}
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	s, err := h.svc.SetPortalProjects(r.Context(), orgID, chi.URLParam(r, "id"), req.ProjectIDs, userID)
	if err != nil {
		h.writeSubcontractorError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPortalSettingsResponse(*s))
}

// ---------- Taşeron Paneli: taşeron tarafı ----------

type portalEngagementResponse struct {
	Kind           string   `json:"kind"`
	ID             string   `json:"id"`
	ProjectID      string   `json:"project_id"`
	ProjectName    string   `json:"project_name"`
	ProjectNo      string   `json:"project_no"`
	ProjectStatus  string   `json:"project_status"`
	Title          string   `json:"title"`
	Status         string   `json:"status"`
	Currency       string   `json:"currency"`
	ContractAmount float64  `json:"contract_amount"`
	Certified      *float64 `json:"certified"`
	Paid           float64  `json:"paid"`
	Payable        float64  `json:"payable"`
	Retention      float64  `json:"retention"`
	AdvanceOpen    float64  `json:"advance_open"`
	PendingClaims  float64  `json:"pending_claims"`
	Remaining      float64  `json:"remaining"`
}

type portalPaymentResponse struct {
	Source      string  `json:"source"`
	ID          string  `json:"id"`
	ProjectID   *string `json:"project_id"`
	ProjectName string  `json:"project_name"`
	ProjectNo   string  `json:"project_no"`
	Amount      float64 `json:"amount"`
	Currency    string  `json:"currency"`
	PaidDate    string  `json:"paid_date"`
	Description string  `json:"description"`
	Kind        string  `json:"kind"`
}

type portalTotalsResponse struct {
	Currency       string  `json:"currency"`
	ContractAmount float64 `json:"contract_amount"`
	Paid           float64 `json:"paid"`
	Remaining      float64 `json:"remaining"`
	Payable        float64 `json:"payable"`
	Retention      float64 `json:"retention"`
}

// GetPortalOverview: GET /portal/overview -- taşeronun ana ekranı. Taşeron
// her zaman oturumdaki hesaptan bulunur (istekte kimlik yok).
func (h *SupplierHandler) GetPortalOverview(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	supplierID, ok := middleware.SupplierIDFromContext(r.Context())
	if !ok {
		httpjson.Error(w, http.StatusForbidden, "bu bölüm yalnızca taşeron hesapları içindir")
		return
	}
	o, err := h.svc.PortalOverview(r.Context(), orgID, supplierID)
	if err != nil {
		h.writeSubcontractorError(w, err)
		return
	}
	projects := make([]map[string]string, len(o.Projects))
	for i, p := range o.Projects {
		projects[i] = map[string]string{"id": p.ID, "project_no": p.ProjectNo, "name": p.Name, "status": p.Status}
	}
	engs := make([]portalEngagementResponse, len(o.Engagements))
	for i, e := range o.Engagements {
		engs[i] = portalEngagementResponse{
			Kind: e.Kind, ID: e.ID, ProjectID: e.ProjectID, ProjectName: e.ProjectName, ProjectNo: e.ProjectNo,
			ProjectStatus: e.ProjectStatus, Title: e.Title, Status: e.Status, Currency: e.Currency,
			ContractAmount: e.ContractAmount, Certified: e.Certified, Paid: e.Paid, Payable: e.Payable,
			Retention: e.Retention, AdvanceOpen: e.AdvanceOpen, PendingClaims: e.PendingClaims, Remaining: e.Remaining,
		}
	}
	pays := make([]portalPaymentResponse, len(o.Payments))
	for i, p := range o.Payments {
		pays[i] = portalPaymentResponse{
			Source: p.Source, ID: p.ID, ProjectID: p.ProjectID, ProjectName: p.ProjectName, ProjectNo: p.ProjectNo,
			Amount: p.Amount, Currency: p.Currency, PaidDate: p.PaidDate.Format(dateLayout),
			Description: p.Description, Kind: p.Kind,
		}
	}
	totals := make([]portalTotalsResponse, len(o.Totals))
	for i, t := range o.Totals {
		totals[i] = portalTotalsResponse{
			Currency: t.Currency, ContractAmount: t.ContractAmount, Paid: t.Paid,
			Remaining: t.Remaining, Payable: t.Payable, Retention: t.Retention,
		}
	}
	httpjson.Write(w, http.StatusOK, map[string]any{
		"supplier": map[string]string{"id": o.SupplierID, "name": o.SupplierName},
		"projects": projects, "engagements": engs, "payments": pays, "totals": totals,
	})
}
