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

// ARVEND V2 — Sprint 4: Procurement Foundation, RFQ + Tedarikçi Teklifi +
// Teklif Karşılaştırma + Award uçları.

type rfqResponse struct {
	ID                 string  `json:"id"`
	RFQNo              string  `json:"rfq_no"`
	PurchaseRequestID  *string `json:"purchase_request_id,omitempty"`
	Title              string  `json:"title"`
	IssueDate          string  `json:"issue_date"`
	DueDate            *string `json:"due_date,omitempty"`
	Status             string  `json:"status"`
	Notes              string  `json:"notes"`
	AwardedQuotationID *string `json:"awarded_quotation_id,omitempty"`
	AwardedAt          *string `json:"awarded_at,omitempty"`
	AwardedBy          *string `json:"awarded_by,omitempty"`
	AwardNotes         string  `json:"award_notes,omitempty"`
	CreatedAt          string  `json:"created_at"`
	UpdatedAt          string  `json:"updated_at"`
}

func toRFQResponse(r domain.RFQ) rfqResponse {
	issueDate := r.IssueDate.Format(dateLayout)
	return rfqResponse{
		ID: r.ID, RFQNo: r.RFQNo, PurchaseRequestID: r.PurchaseRequestID,
		Title: r.Title, IssueDate: issueDate, DueDate: dateStrPtr(r.DueDate), Status: r.Status, Notes: r.Notes,
		AwardedQuotationID: r.AwardedQuotationID, AwardedAt: tsStrPtr(r.AwardedAt), AwardedBy: r.AwardedBy, AwardNotes: r.AwardNotes,
		CreatedAt: r.CreatedAt.Format(rfc3339), UpdatedAt: r.UpdatedAt.Format(rfc3339),
	}
}

type rfqItemResponse struct {
	ID             string  `json:"id"`
	SourcePRItemID *string `json:"source_pr_item_id,omitempty"`
	WBSNodeID      *string `json:"wbs_node_id,omitempty"`
	CostCodeID     *string `json:"cost_code_id,omitempty"`
	BudgetLineID   *string `json:"budget_line_id,omitempty"`
	Description    string  `json:"description"`
	Quantity       float64 `json:"quantity"`
	Unit           string  `json:"unit"`
	SortOrder      int     `json:"sort_order"`
}

func toRFQItemResponse(i domain.RFQItem) rfqItemResponse {
	return rfqItemResponse{
		ID: i.ID, SourcePRItemID: i.SourcePRItemID, WBSNodeID: i.WBSNodeID, CostCodeID: i.CostCodeID, BudgetLineID: i.BudgetLineID,
		Description: i.Description, Quantity: i.Quantity, Unit: i.Unit, SortOrder: i.SortOrder,
	}
}

type rfqSupplierResponse struct {
	ID             string `json:"id"`
	SupplierID     string `json:"supplier_id"`
	SupplierCode   string `json:"supplier_code"`
	SupplierName   string `json:"supplier_name"`
	InvitedAt      string `json:"invited_at"`
	ResponseStatus string `json:"response_status"`
}

func toRFQSupplierResponse(r domain.RFQSupplier) rfqSupplierResponse {
	return rfqSupplierResponse{
		ID: r.ID, SupplierID: r.SupplierID, SupplierCode: r.SupplierCode, SupplierName: r.SupplierName,
		InvitedAt: r.InvitedAt.Format(rfc3339), ResponseStatus: r.ResponseStatus,
	}
}

type rfqItemRequest struct {
	WBSNodeID    string  `json:"wbs_node_id"`
	CostCodeID   string  `json:"cost_code_id"`
	BudgetLineID string  `json:"budget_line_id"`
	Description  string  `json:"description"`
	Quantity     float64 `json:"quantity"`
	Unit         string  `json:"unit"`
}

type rfqRequest struct {
	Title             string           `json:"title"`
	PurchaseRequestID string           `json:"purchase_request_id"`
	IssueDate         string           `json:"issue_date"`
	DueDate           *string          `json:"due_date"`
	Notes             string           `json:"notes"`
	SupplierIDs       []string         `json:"supplier_ids"`
	Items             []rfqItemRequest `json:"items"`
}

func (req rfqRequest) toInput(userID string) service.RFQInput {
	items := make([]service.RFQItemInput, len(req.Items))
	for i, it := range req.Items {
		items[i] = service.RFQItemInput{
			WBSNodeID: it.WBSNodeID, CostCodeID: it.CostCodeID, BudgetLineID: it.BudgetLineID,
			Description: it.Description, Quantity: it.Quantity, Unit: it.Unit,
		}
	}
	in := service.RFQInput{
		Title: req.Title, PurchaseRequestID: req.PurchaseRequestID, DueDate: parseDateParam(req.DueDate),
		Notes: req.Notes, SupplierIDs: req.SupplierIDs, Items: items, UserID: userID,
	}
	return in
}

// toInputWithDates, toInput'a zorunlu RFQ tarihini ekler; tarih
// çözülemezse 400 yazar ve false döner.
func (req rfqRequest) toInputWithDates(w http.ResponseWriter, userID string) (service.RFQInput, bool) {
	in := req.toInput(userID)
	issueDate, ok := requestDate(w, req.IssueDate)
	in.IssueDate = issueDate
	return in, ok
}

func (h *ProjectHandler) ListRFQs(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListRFQs(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]rfqResponse, len(rows))
	for i, r2 := range rows {
		out[i] = toRFQResponse(r2)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"rfqs": out})
}

func (h *ProjectHandler) CreateRFQ(w http.ResponseWriter, r *http.Request) {
	var req rfqRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	in, ok := req.toInputWithDates(w, userID)
	if !ok {
		return
	}
	rfq, err := h.svc.CreateRFQ(r.Context(), chi.URLParam(r, "id"), orgID, in)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toRFQResponse(*rfq))
}

func (h *ProjectHandler) GetRFQ(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rfq, err := h.svc.GetRFQ(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "rfqId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	items, err := h.svc.ListRFQItems(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "rfqId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	suppliers, err := h.svc.ListRFQSuppliers(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "rfqId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	itemsOut := make([]rfqItemResponse, len(items))
	for i, it := range items {
		itemsOut[i] = toRFQItemResponse(it)
	}
	suppliersOut := make([]rfqSupplierResponse, len(suppliers))
	for i, s := range suppliers {
		suppliersOut[i] = toRFQSupplierResponse(s)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"rfq": toRFQResponse(*rfq), "items": itemsOut, "suppliers": suppliersOut})
}

func (h *ProjectHandler) UpdateRFQ(w http.ResponseWriter, r *http.Request) {
	var req rfqRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	in, ok := req.toInputWithDates(w, userID)
	if !ok {
		return
	}
	rfq, err := h.svc.UpdateRFQDraft(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "rfqId"), orgID, in)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toRFQResponse(*rfq))
}

func (h *ProjectHandler) IssueRFQ(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	rfq, err := h.svc.IssueRFQ(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "rfqId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toRFQResponse(*rfq))
}

func (h *ProjectHandler) CloseRFQ(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	rfq, err := h.svc.CloseRFQ(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "rfqId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toRFQResponse(*rfq))
}

func (h *ProjectHandler) CancelRFQ(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	rfq, err := h.svc.CancelRFQ(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "rfqId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toRFQResponse(*rfq))
}

type awardRFQRequest struct {
	QuotationID string `json:"quotation_id"`
	Notes       string `json:"notes"`
}

func (h *ProjectHandler) AwardRFQ(w http.ResponseWriter, r *http.Request) {
	var req awardRFQRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	rfq, err := h.svc.AwardRFQ(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "rfqId"), orgID, userID, req.QuotationID, req.Notes)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toRFQResponse(*rfq))
}

// ---------- Tedarikçi Teklifleri (Supplier Quotations) ----------

type quotationResponse struct {
	ID              string  `json:"id"`
	RFQID           string  `json:"rfq_id"`
	SupplierID      string  `json:"supplier_id"`
	SupplierCode    string  `json:"supplier_code,omitempty"`
	SupplierName    string  `json:"supplier_name,omitempty"`
	QuotationNumber string  `json:"quotation_number"`
	QuotationDate   string  `json:"quotation_date"`
	ValidUntil      *string `json:"valid_until,omitempty"`
	Currency        string  `json:"currency"`
	Subtotal        float64 `json:"subtotal"`
	Discount        float64 `json:"discount"`
	TaxRate         float64 `json:"tax_rate"`
	Tax             float64 `json:"tax"`
	Total           float64 `json:"total"`
	DeliveryDays    *int    `json:"delivery_days,omitempty"`
	PaymentTerms    string  `json:"payment_terms"`
	Notes           string  `json:"notes"`
	CreatedAt       string  `json:"created_at"`
	UpdatedAt       string  `json:"updated_at"`
}

func toQuotationResponse(q domain.SupplierQuotation) quotationResponse {
	return quotationResponse{
		ID: q.ID, RFQID: q.RFQID, SupplierID: q.SupplierID,
		QuotationNumber: q.QuotationNumber, QuotationDate: q.QuotationDate.Format(dateLayout), ValidUntil: dateStrPtr(q.ValidUntil),
		Currency: q.Currency, Subtotal: q.Subtotal, Discount: q.Discount, TaxRate: q.TaxRate, Tax: q.Tax, Total: q.Total,
		DeliveryDays: q.DeliveryDays, PaymentTerms: q.PaymentTerms, Notes: q.Notes,
		CreatedAt: q.CreatedAt.Format(rfc3339), UpdatedAt: q.UpdatedAt.Format(rfc3339),
	}
}

func toQuotationDetailedResponse(q repository.SupplierQuotationDetailed) quotationResponse {
	resp := toQuotationResponse(q.SupplierQuotation)
	resp.SupplierCode = q.SupplierCode
	resp.SupplierName = q.SupplierName
	return resp
}

type quotationItemResponse struct {
	ID        string  `json:"id"`
	RFQItemID string  `json:"rfq_item_id"`
	Quantity  float64 `json:"quantity"`
	UnitPrice float64 `json:"unit_price"`
	LineTotal float64 `json:"line_total"`
	Notes     string  `json:"notes"`
}

func toQuotationItemResponse(i domain.QuotationItem) quotationItemResponse {
	return quotationItemResponse{ID: i.ID, RFQItemID: i.RFQItemID, Quantity: i.Quantity, UnitPrice: i.UnitPrice, LineTotal: i.LineTotal, Notes: i.Notes}
}

type quotationItemRequest struct {
	RFQItemID string  `json:"rfq_item_id"`
	Quantity  float64 `json:"quantity"`
	UnitPrice float64 `json:"unit_price"`
	Notes     string  `json:"notes"`
}

type quotationRequest struct {
	SupplierID      string                 `json:"supplier_id"`
	QuotationNumber string                 `json:"quotation_number"`
	QuotationDate   string                 `json:"quotation_date"`
	ValidUntil      *string                `json:"valid_until"`
	Discount        float64                `json:"discount"`
	TaxRate         float64                `json:"tax_rate"`
	DeliveryDays    *int                   `json:"delivery_days"`
	PaymentTerms    string                 `json:"payment_terms"`
	Notes           string                 `json:"notes"`
	Items           []quotationItemRequest `json:"items"`
}

func (req quotationRequest) toInput(userID string) service.QuotationInput {
	items := make([]service.QuotationItemInput, len(req.Items))
	for i, it := range req.Items {
		items[i] = service.QuotationItemInput{RFQItemID: it.RFQItemID, Quantity: it.Quantity, UnitPrice: it.UnitPrice, Notes: it.Notes}
	}
	in := service.QuotationInput{
		SupplierID: req.SupplierID, QuotationNumber: req.QuotationNumber, ValidUntil: parseDateParam(req.ValidUntil),
		Discount: req.Discount, TaxRate: req.TaxRate, DeliveryDays: req.DeliveryDays, PaymentTerms: req.PaymentTerms,
		Notes: req.Notes, Items: items, UserID: userID,
	}
	return in
}

// toInputWithDates, toInput'a zorunlu teklif tarihini ekler; tarih
// çözülemezse 400 yazar ve false döner.
func (req quotationRequest) toInputWithDates(w http.ResponseWriter, userID string) (service.QuotationInput, bool) {
	in := req.toInput(userID)
	quotationDate, ok := requestDate(w, req.QuotationDate)
	in.QuotationDate = quotationDate
	return in, ok
}

func (h *ProjectHandler) ListQuotations(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListQuotations(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "rfqId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]quotationResponse, len(rows))
	for i, q := range rows {
		out[i] = toQuotationDetailedResponse(q)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"quotations": out})
}

func (h *ProjectHandler) CreateQuotation(w http.ResponseWriter, r *http.Request) {
	var req quotationRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	in, ok := req.toInputWithDates(w, userID)
	if !ok {
		return
	}
	q, err := h.svc.CreateQuotation(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "rfqId"), orgID, in)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toQuotationResponse(*q))
}

func (h *ProjectHandler) GetQuotation(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	q, err := h.svc.GetQuotation(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "quotationId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	items, err := h.svc.ListQuotationItems(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "quotationId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	itemsOut := make([]quotationItemResponse, len(items))
	for i, it := range items {
		itemsOut[i] = toQuotationItemResponse(it)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"quotation": toQuotationResponse(*q), "items": itemsOut})
}

func (h *ProjectHandler) UpdateQuotation(w http.ResponseWriter, r *http.Request) {
	var req quotationRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	in, ok := req.toInputWithDates(w, userID)
	if !ok {
		return
	}
	q, err := h.svc.UpdateQuotation(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "quotationId"), orgID, in)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toQuotationResponse(*q))
}

func (h *ProjectHandler) DeleteQuotation(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.DeleteQuotation(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "quotationId"), orgID, userID); err != nil {
		h.writeError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- Teklif Karşılaştırma ----------

type bidComparisonCellResponse struct {
	SupplierID string  `json:"supplier_id"`
	Quantity   float64 `json:"quantity"`
	UnitPrice  float64 `json:"unit_price"`
	LineTotal  float64 `json:"line_total"`
	Notes      string  `json:"notes"`
}

type bidComparisonRowResponse struct {
	Item  rfqItemResponse                      `json:"item"`
	Cells map[string]bidComparisonCellResponse `json:"cells"`
}

func (h *ProjectHandler) GetBidComparison(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	cmp, err := h.svc.GetBidComparison(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "rfqId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	rows := make([]bidComparisonRowResponse, len(cmp.Rows))
	for i, row := range cmp.Rows {
		cells := make(map[string]bidComparisonCellResponse, len(row.Cells))
		for sid, c := range row.Cells {
			cells[sid] = bidComparisonCellResponse{SupplierID: c.SupplierID, Quantity: c.Quantity, UnitPrice: c.UnitPrice, LineTotal: c.LineTotal, Notes: c.Notes}
		}
		rows[i] = bidComparisonRowResponse{Item: toRFQItemResponse(row.RFQItem), Cells: cells}
	}
	suppliers := make([]quotationResponse, len(cmp.Suppliers))
	for i, s := range cmp.Suppliers {
		suppliers[i] = toQuotationDetailedResponse(s)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"rows": rows, "quotations": suppliers})
}
