package handler

import (
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// parseDateOrToday, zorunlu bir tarih alanını çözer: boşsa İSTANBUL'a göre
// bugün (sunucu UTC'dedir; time.Now() gece 00:00-03:00 arası dünü
// verirdi), çözülemiyorsa hata. Önceden çözülemeyen tarih ("06.10.2026")
// sessizce bugüne çevriliyor, ödeme/masraf yanlış güne kaydediliyordu.
func parseDateOrToday(raw string) (time.Time, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return service.IstanbulToday(), nil
	}
	t, err := time.Parse(dateLayout, raw)
	if err != nil {
		return time.Time{}, fmt.Errorf("geçersiz tarih %q: tarih YYYY-AA-GG biçiminde olmalıdır (ör. 2026-10-06)", raw)
	}
	return t, nil
}

// requestDate, parseDateOrToday'i çağırır; hata varsa 400 yazar ve false
// döner.
func requestDate(w http.ResponseWriter, raw string) (time.Time, bool) {
	t, err := parseDateOrToday(raw)
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, err.Error())
		return time.Time{}, false
	}
	return t, true
}

func dateStrPtr(t *time.Time) *string {
	if t == nil {
		return nil
	}
	s := t.Format(dateLayout)
	return &s
}

func tsStrPtr(t *time.Time) *string {
	if t == nil {
		return nil
	}
	s := t.Format(rfc3339)
	return &s
}

// ---------- Ödeme Planı ----------

type paymentPlanItemResponse struct {
	ID              string   `json:"id"`
	SortOrder       int      `json:"sort_order"`
	Name            string   `json:"name"`
	Percentage      *float64 `json:"percentage"`
	PlannedAmount   float64  `json:"planned_amount"`
	CollectedAmount float64  `json:"collected_amount"`
	RemainingAmount float64  `json:"remaining_amount"`
	DueDate         *string  `json:"due_date"`
	Status          string   `json:"status"`
	Notes           string   `json:"notes"`
}

func toPaymentPlanItemResponse(i domain.PaymentPlanItem) paymentPlanItemResponse {
	remaining := i.PlannedAmount - i.CollectedAmount
	if remaining < 0 {
		remaining = 0
	}
	return paymentPlanItemResponse{
		ID: i.ID, SortOrder: i.SortOrder, Name: i.Name, Percentage: i.Percentage,
		PlannedAmount: i.PlannedAmount, CollectedAmount: i.CollectedAmount,
		RemainingAmount: remaining, DueDate: dateStrPtr(i.DueDate), Status: i.Status, Notes: i.Notes,
	}
}

type paymentPlanItemRequest struct {
	Name          string   `json:"name"`
	Percentage    *float64 `json:"percentage"`
	PlannedAmount float64  `json:"planned_amount"`
	DueDate       *string  `json:"due_date"`
	SortOrder     int      `json:"sort_order"`
	Notes         string   `json:"notes"`
}

func (r paymentPlanItemRequest) toInput(userID string) service.PaymentPlanItemInput {
	return service.PaymentPlanItemInput{
		Name: r.Name, Percentage: r.Percentage, PlannedAmount: r.PlannedAmount,
		DueDate: parseDateParam(r.DueDate), SortOrder: r.SortOrder, Notes: r.Notes, UserID: userID,
	}
}

func (h *ProjectHandler) ListPaymentPlan(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	items, err := h.svc.ListPaymentPlan(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]paymentPlanItemResponse, len(items))
	for i, it := range items {
		out[i] = toPaymentPlanItemResponse(it)
	}
	// Toplam SQL/numeric üzerinde hesaplanır (Go'da float64 satır satır
	// toplama YERİNE) -- aksi halde financial-summary'nin
	// "planned_collections" alanıyla ikili yuvarlama farkından ötürü
	// ayrışabiliyordu (bkz. denetim bulgusu).
	plannedTotal, err := h.svc.GetPaymentPlanTotal(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"items": out, "planned_total": plannedTotal})
}

func (h *ProjectHandler) CreatePaymentPlanItem(w http.ResponseWriter, r *http.Request) {
	var req paymentPlanItemRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	item, err := h.svc.CreatePaymentPlanItem(r.Context(), chi.URLParam(r, "id"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toPaymentPlanItemResponse(*item))
}

func (h *ProjectHandler) UpdatePaymentPlanItem(w http.ResponseWriter, r *http.Request) {
	var req paymentPlanItemRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	item, err := h.svc.UpdatePaymentPlanItem(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "itemId"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPaymentPlanItemResponse(*item))
}

func (h *ProjectHandler) CancelPaymentPlanItem(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.CancelPaymentPlanItem(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "itemId"), orgID, userID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

// ---------- Tahsilatlar ----------

type collectionResponse struct {
	ID                string  `json:"id"`
	PaymentPlanItemID *string `json:"payment_plan_item_id"`
	InvoiceID         *string `json:"invoice_id"`
	Amount            float64 `json:"amount"`
	Currency          string  `json:"currency"`
	ReceivedDate      string  `json:"received_date"`
	PaymentMethod     string  `json:"payment_method"`
	Description       string  `json:"description"`
	ReferenceNo       string  `json:"reference_no"`
	VoidedAt          *string `json:"voided_at"`
	VoidReason        string  `json:"void_reason"`
	CreatedAt         string  `json:"created_at"`
}

func toCollectionResponse(c domain.Collection) collectionResponse {
	return collectionResponse{
		ID: c.ID, PaymentPlanItemID: c.PaymentPlanItemID, InvoiceID: c.InvoiceID, Amount: c.Amount, Currency: c.Currency,
		ReceivedDate: c.ReceivedDate.Format(dateLayout), PaymentMethod: c.PaymentMethod,
		Description: c.Description, ReferenceNo: c.ReferenceNo, VoidedAt: tsStrPtr(c.VoidedAt),
		VoidReason: c.VoidReason, CreatedAt: c.CreatedAt.Format(rfc3339),
	}
}

type collectionRequest struct {
	PaymentPlanItemID *string `json:"payment_plan_item_id"`
	Amount            float64 `json:"amount"`
	Currency          string  `json:"currency"`
	ReceivedDate      string  `json:"received_date"`
	PaymentMethod     string  `json:"payment_method"`
	Description       string  `json:"description"`
	ReferenceNo       string  `json:"reference_no"`
	IdempotencyKey    string  `json:"idempotency_key"`
}

func (h *ProjectHandler) ListCollections(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListCollections(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]collectionResponse, len(rows))
	for i, c := range rows {
		out[i] = toCollectionResponse(c)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"collections": out})
}

func (h *ProjectHandler) CreateCollection(w http.ResponseWriter, r *http.Request) {
	var req collectionRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	receivedDate, ok := requestDate(w, req.ReceivedDate)
	if !ok {
		return
	}
	c, err := h.svc.CreateCollection(r.Context(), chi.URLParam(r, "id"), orgID, service.CollectionInput{
		PaymentPlanItemID: req.PaymentPlanItemID,
		Amount:            req.Amount,
		Currency:          req.Currency,
		ReceivedDate:      receivedDate,
		PaymentMethod:     req.PaymentMethod,
		Description:       req.Description,
		ReferenceNo:       req.ReferenceNo,
		IdempotencyKey:    req.IdempotencyKey,
		UserID:            userID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toCollectionResponse(*c))
}

type voidRequest struct {
	Reason string `json:"reason"`
}

func (h *ProjectHandler) VoidCollection(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	_ = httpjson.Decode(r, &req)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	c, err := h.svc.VoidCollection(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "collectionId"), orgID, userID, req.Reason)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toCollectionResponse(*c))
}

// ---------- Masraflar ----------

type expenseResponse struct {
	ID            string  `json:"id"`
	Category      string  `json:"category"`
	Description   string  `json:"description"`
	Amount        float64 `json:"amount"`
	Currency      string  `json:"currency"`
	ExpenseDate   string  `json:"expense_date"`
	SupplierName  string  `json:"supplier_name"`
	InvoiceNo     string  `json:"invoice_no"`
	Notes         string  `json:"notes"`
	VoidedAt      *string `json:"voided_at"`
	VoidReason    string  `json:"void_reason"`
	CreatedAt     string  `json:"created_at"`
	ChangeOrderID *string `json:"change_order_id,omitempty"`
	CostCodeID    *string `json:"cost_code_id,omitempty"`
	BudgetLineID  *string `json:"budget_line_id,omitempty"`
}

func toExpenseResponse(e domain.Expense) expenseResponse {
	return expenseResponse{
		ID: e.ID, Category: e.Category, Description: e.Description, Amount: e.Amount,
		Currency: e.Currency, ExpenseDate: e.ExpenseDate.Format(dateLayout),
		SupplierName: e.SupplierName, InvoiceNo: e.InvoiceNo, Notes: e.Notes,
		VoidedAt: tsStrPtr(e.VoidedAt), VoidReason: e.VoidReason, CreatedAt: e.CreatedAt.Format(rfc3339),
		ChangeOrderID: e.ChangeOrderID, CostCodeID: e.CostCodeID, BudgetLineID: e.BudgetLineID,
	}
}

type expenseRequest struct {
	Category       string  `json:"category"`
	Description    string  `json:"description"`
	Amount         float64 `json:"amount"`
	Currency       string  `json:"currency"`
	ExpenseDate    string  `json:"expense_date"`
	SupplierName   string  `json:"supplier_name"`
	InvoiceNo      string  `json:"invoice_no"`
	Notes          string  `json:"notes"`
	IdempotencyKey string  `json:"idempotency_key"`
	ChangeOrderID  string  `json:"change_order_id"`
	// CostCodeID/BudgetLineID, Cost Control (Sprint 2) eşlemesi -- İKİSİ
	// de OPSİYONELDİR (bkz. service.ExpenseInput.CostCodeID notu).
	CostCodeID   string `json:"cost_code_id"`
	BudgetLineID string `json:"budget_line_id"`
}

func (r expenseRequest) toInput(userID string, expenseDate time.Time) service.ExpenseInput {
	return service.ExpenseInput{
		Category: r.Category, Description: r.Description, Amount: r.Amount, Currency: r.Currency,
		ExpenseDate: expenseDate, SupplierName: r.SupplierName,
		InvoiceNo: r.InvoiceNo, Notes: r.Notes, IdempotencyKey: r.IdempotencyKey,
		ChangeOrderID: r.ChangeOrderID, UserID: userID,
		CostCodeID: r.CostCodeID, BudgetLineID: r.BudgetLineID,
	}
}

func (h *ProjectHandler) ListExpenses(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListExpenses(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]expenseResponse, len(rows))
	for i, e := range rows {
		out[i] = toExpenseResponse(e)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"expenses": out})
}

func (h *ProjectHandler) CreateExpense(w http.ResponseWriter, r *http.Request) {
	var req expenseRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	expenseDate, ok := requestDate(w, req.ExpenseDate)
	if !ok {
		return
	}
	e, err := h.svc.CreateExpense(r.Context(), chi.URLParam(r, "id"), orgID, req.toInput(userID, expenseDate))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toExpenseResponse(*e))
}

func (h *ProjectHandler) UpdateExpense(w http.ResponseWriter, r *http.Request) {
	var req expenseRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	expenseDate, ok := requestDate(w, req.ExpenseDate)
	if !ok {
		return
	}
	e, err := h.svc.UpdateExpense(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "expenseId"), orgID, req.toInput(userID, expenseDate))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toExpenseResponse(*e))
}

func (h *ProjectHandler) VoidExpense(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	_ = httpjson.Decode(r, &req)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	e, err := h.svc.VoidExpense(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "expenseId"), orgID, userID, req.Reason)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toExpenseResponse(*e))
}

// ---------- Faturalar ----------

type invoiceResponse struct {
	ID           string  `json:"id"`
	InvoiceNo    string  `json:"invoice_no"`
	InvoiceType  string  `json:"invoice_type"`
	InvoiceDate  string  `json:"invoice_date"`
	DueDate      *string `json:"due_date"`
	Amount       float64 `json:"amount"`
	Currency     string  `json:"currency"`
	Status       string  `json:"status"`
	CustomerName string  `json:"customer_name"`
	Notes        string  `json:"notes"`
	CreatedAt    string  `json:"created_at"`
}

func toInvoiceResponse(i domain.ProjectInvoice) invoiceResponse {
	return invoiceResponse{
		ID: i.ID, InvoiceNo: i.InvoiceNo, InvoiceType: i.InvoiceType,
		InvoiceDate: i.InvoiceDate.Format(dateLayout), DueDate: dateStrPtr(i.DueDate),
		Amount: i.Amount, Currency: i.Currency, Status: i.Status,
		CustomerName: i.CustomerName, Notes: i.Notes, CreatedAt: i.CreatedAt.Format(rfc3339),
	}
}

type invoiceRequest struct {
	InvoiceNo    string  `json:"invoice_no"`
	InvoiceType  string  `json:"invoice_type"`
	InvoiceDate  string  `json:"invoice_date"`
	DueDate      *string `json:"due_date"`
	Amount       float64 `json:"amount"`
	Currency     string  `json:"currency"`
	Status       string  `json:"status"`
	CustomerName string  `json:"customer_name"`
	Notes        string  `json:"notes"`
}

func (h *ProjectHandler) ListInvoices(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListInvoices(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]invoiceResponse, len(rows))
	for i, inv := range rows {
		out[i] = toInvoiceResponse(inv)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"invoices": out})
}

func (h *ProjectHandler) CreateInvoice(w http.ResponseWriter, r *http.Request) {
	var req invoiceRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	invoiceDate, ok := requestDate(w, req.InvoiceDate)
	if !ok {
		return
	}
	inv, err := h.svc.CreateInvoice(r.Context(), chi.URLParam(r, "id"), orgID, service.InvoiceInput{
		InvoiceNo: req.InvoiceNo, InvoiceType: req.InvoiceType,
		InvoiceDate: invoiceDate, DueDate: parseDateParam(req.DueDate),
		Amount: req.Amount, Currency: req.Currency, Status: req.Status,
		CustomerName: req.CustomerName, Notes: req.Notes, UserID: userID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toInvoiceResponse(*inv))
}

type invoiceStatusRequest struct {
	Status string `json:"status"`
	// RecordCollection: satış faturası "ödendi" yapılırken tahsilat da
	// açılsın mı (nil = evet). Bkz. ProjectService.UpdateInvoiceStatus.
	RecordCollection *bool `json:"record_collection"`
}

func (h *ProjectHandler) UpdateInvoiceStatus(w http.ResponseWriter, r *http.Request) {
	var req invoiceStatusRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	// record_collection verilmezse varsayılan: satış faturası "ödendi"
	// yapılınca tahsilat da açılır (eski istemciler gönderemez; özet boş
	// kalmasın). Kullanıcı tahsilatı ayrıca girdiyse false gönderir.
	record := true
	if req.RecordCollection != nil {
		record = *req.RecordCollection
	}
	inv, err := h.svc.UpdateInvoiceStatus(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "invoiceId"), orgID, req.Status, userID, record)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toInvoiceResponse(*inv))
}

// ---------- Taşeronlar ----------

type subcontractorResponse struct {
	ID              string  `json:"id"`
	Name            string  `json:"name"`
	CompanyName     string  `json:"company_name"`
	Phone           string  `json:"phone"`
	Email           string  `json:"email"`
	WorkDescription string  `json:"work_description"`
	ContractAmount  float64 `json:"contract_amount"`
	PaidAmount      float64 `json:"paid_amount"`
	RemainingAmount float64 `json:"remaining_amount"`
	Currency        string  `json:"currency"`
	StartDate       *string `json:"start_date"`
	EndDate         *string `json:"end_date"`
	Status          string  `json:"status"`
	Notes           string  `json:"notes"`
	ChangeOrderID   *string `json:"change_order_id,omitempty"`
	CostCodeID      *string `json:"cost_code_id,omitempty"`
}

func toSubcontractorResponse(s domain.Subcontractor) subcontractorResponse {
	return subcontractorResponse{
		ID: s.ID, Name: s.Name, CompanyName: s.CompanyName, Phone: s.Phone, Email: s.Email,
		WorkDescription: s.WorkDescription, ContractAmount: s.ContractAmount,
		PaidAmount: s.PaidAmount, RemainingAmount: s.RemainingAmount, Currency: s.Currency,
		StartDate: dateStrPtr(s.StartDate), EndDate: dateStrPtr(s.EndDate),
		Status: s.Status, Notes: s.Notes, ChangeOrderID: s.ChangeOrderID, CostCodeID: s.CostCodeID,
	}
}

type subcontractorRequest struct {
	Name            string  `json:"name"`
	CompanyName     string  `json:"company_name"`
	Phone           string  `json:"phone"`
	Email           string  `json:"email"`
	WorkDescription string  `json:"work_description"`
	ContractAmount  float64 `json:"contract_amount"`
	Currency        string  `json:"currency"`
	StartDate       *string `json:"start_date"`
	EndDate         *string `json:"end_date"`
	Status          string  `json:"status"`
	Notes           string  `json:"notes"`
	ChangeOrderID   string  `json:"change_order_id"`
	// CostCodeID, Cost Control (Sprint 2) eşlemesi -- OPSİYONELDİR (bkz.
	// service.SubcontractorInput.CostCodeID notu).
	CostCodeID string `json:"cost_code_id"`
}

func (r subcontractorRequest) toInput(userID string) service.SubcontractorInput {
	return service.SubcontractorInput{
		Name: r.Name, CompanyName: r.CompanyName, Phone: r.Phone, Email: r.Email,
		WorkDescription: r.WorkDescription, ContractAmount: r.ContractAmount, Currency: r.Currency,
		StartDate: parseDateParam(r.StartDate), EndDate: parseDateParam(r.EndDate),
		Status: r.Status, Notes: r.Notes, ChangeOrderID: r.ChangeOrderID, UserID: userID,
		CostCodeID: r.CostCodeID,
	}
}

func (h *ProjectHandler) ListSubcontractors(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListSubcontractors(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]subcontractorResponse, len(rows))
	for i, s := range rows {
		out[i] = toSubcontractorResponse(s)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"subcontractors": out})
}

func (h *ProjectHandler) CreateSubcontractor(w http.ResponseWriter, r *http.Request) {
	var req subcontractorRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	s, err := h.svc.CreateSubcontractor(r.Context(), chi.URLParam(r, "id"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toSubcontractorResponse(*s))
}

func (h *ProjectHandler) UpdateSubcontractor(w http.ResponseWriter, r *http.Request) {
	var req subcontractorRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	s, err := h.svc.UpdateSubcontractor(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "subcontractorId"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toSubcontractorResponse(*s))
}

type subcontractorPaymentResponse struct {
	ID              string  `json:"id"`
	SubcontractorID string  `json:"subcontractor_id"`
	Amount          float64 `json:"amount"`
	Currency        string  `json:"currency"`
	PaidDate        string  `json:"paid_date"`
	Description     string  `json:"description"`
	VoidedAt        *string `json:"voided_at"`
	VoidReason      string  `json:"void_reason"`
	CreatedAt       string  `json:"created_at"`
}

func toSubcontractorPaymentResponse(p domain.SubcontractorPayment) subcontractorPaymentResponse {
	return subcontractorPaymentResponse{
		ID: p.ID, SubcontractorID: p.SubcontractorID, Amount: p.Amount, Currency: p.Currency,
		PaidDate: p.PaidDate.Format(dateLayout), Description: p.Description,
		VoidedAt: tsStrPtr(p.VoidedAt), VoidReason: p.VoidReason, CreatedAt: p.CreatedAt.Format(rfc3339),
	}
}

type subcontractorPaymentRequest struct {
	Amount         float64 `json:"amount"`
	Currency       string  `json:"currency"`
	PaidDate       string  `json:"paid_date"`
	Description    string  `json:"description"`
	IdempotencyKey string  `json:"idempotency_key"`
}

func (h *ProjectHandler) ListSubcontractorPayments(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListSubcontractorPayments(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]subcontractorPaymentResponse, len(rows))
	for i, p := range rows {
		out[i] = toSubcontractorPaymentResponse(p)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"payments": out})
}

func (h *ProjectHandler) CreateSubcontractorPayment(w http.ResponseWriter, r *http.Request) {
	var req subcontractorPaymentRequest
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
	p, err := h.svc.CreateSubcontractorPayment(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "subcontractorId"), orgID, service.SubcontractorPaymentInput{
		Amount: req.Amount, Currency: req.Currency, PaidDate: paidDate,
		Description: req.Description, IdempotencyKey: req.IdempotencyKey, UserID: userID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toSubcontractorPaymentResponse(*p))
}

func (h *ProjectHandler) VoidSubcontractorPayment(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	_ = httpjson.Decode(r, &req)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.VoidSubcontractorPayment(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "paymentId"), orgID, userID, req.Reason)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toSubcontractorPaymentResponse(*p))
}

// ---------- Finans Özeti + Olaylar ----------

type financialSummaryResponse struct {
	// Faz 8: ana sözleşme ile güncel proje bedeli arasındaki ayrım.
	// ContractAmount, geriye dönük uyumluluk için AYNI değeri taşımaya
	// devam eder (== BaseContractAmount).
	BaseContractAmount     float64 `json:"base_contract_amount"`
	ApprovedAdditions      float64 `json:"approved_additions"`
	ApprovedDeductions     float64 `json:"approved_deductions"`
	CurrentContractValue   float64 `json:"current_contract_value"`
	PendingAdditions       float64 `json:"pending_additions"`
	PendingDeductions      float64 `json:"pending_deductions"`
	PotentialContractValue float64 `json:"potential_contract_value"`

	ContractAmount               float64 `json:"contract_amount"`
	Currency                     string  `json:"currency"`
	PlannedCollections           float64 `json:"planned_collections"`
	CollectedAmount              float64 `json:"collected_amount"`
	RemainingReceivable          float64 `json:"remaining_receivable"`
	OverCollected                float64 `json:"over_collected"`
	TotalExpenses                float64 `json:"total_expenses"`
	TotalSubcontractorCommitment float64 `json:"total_subcontractor_commitment"`
	SubcontractorPaid            float64 `json:"subcontractor_paid"`
	SubcontractorRemaining       float64 `json:"subcontractor_remaining"`
	NewSubcontractPaid           float64 `json:"new_subcontract_paid"`
	NewSubcontractRemaining      float64 `json:"new_subcontract_remaining"`
	IssuedInvoiceTotal           float64 `json:"issued_invoice_total"`
	PaidInvoiceTotal             float64 `json:"paid_invoice_total"`
	RealizedCost                 float64 `json:"realized_cost"`
	CommittedCost                float64 `json:"committed_cost"`
	RealizedGrossProfit          float64 `json:"realized_gross_profit"`
	EstimatedGrossProfit         float64 `json:"estimated_gross_profit"`
	RealizedMarginPercent        float64 `json:"realized_margin_percent"`
	EstimatedMarginPercent       float64 `json:"estimated_margin_percent"`
}

func (h *ProjectHandler) FinancialSummary(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	s, err := h.svc.FinancialSummary(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, financialSummaryResponse{
		BaseContractAmount: s.BaseContractAmount, ApprovedAdditions: s.ApprovedAdditions,
		ApprovedDeductions: s.ApprovedDeductions, CurrentContractValue: s.CurrentContractValue,
		PendingAdditions: s.PendingAdditions, PendingDeductions: s.PendingDeductions,
		PotentialContractValue: s.PotentialContractValue,
		ContractAmount:         s.ContractAmount, Currency: s.Currency,
		PlannedCollections: s.PlannedCollections, CollectedAmount: s.CollectedAmount,
		RemainingReceivable: s.RemainingReceivable, OverCollected: s.OverCollected(),
		TotalExpenses: s.TotalExpenses, TotalSubcontractorCommitment: s.TotalSubcontractorCommitment,
		SubcontractorPaid: s.SubcontractorPaid, SubcontractorRemaining: s.SubcontractorRemaining,
		NewSubcontractPaid: s.NewSubcontractPaid, NewSubcontractRemaining: s.NewSubcontractRemaining,
		IssuedInvoiceTotal: s.IssuedInvoiceTotal, PaidInvoiceTotal: s.PaidInvoiceTotal,
		RealizedCost: s.RealizedCost, CommittedCost: s.CommittedCost,
		RealizedGrossProfit: s.RealizedGrossProfit, EstimatedGrossProfit: s.EstimatedGrossProfit,
		RealizedMarginPercent: s.RealizedMarginPercent, EstimatedMarginPercent: s.EstimatedMarginPercent,
	})
}

type projectEventResponse struct {
	ID        string         `json:"id"`
	EventType string         `json:"event_type"`
	UserID    *string        `json:"user_id"`
	Metadata  map[string]any `json:"metadata,omitempty"`
	CreatedAt string         `json:"created_at"`
}

func (h *ProjectHandler) ListEvents(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListProjectEvents(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]projectEventResponse, len(rows))
	for i, e := range rows {
		out[i] = projectEventResponse{
			ID: e.ID, EventType: e.EventType, UserID: e.UserID,
			Metadata: e.Metadata, CreatedAt: e.CreatedAt.Format(rfc3339),
		}
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"events": out})
}
