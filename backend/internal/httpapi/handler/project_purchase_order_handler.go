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

// ARVEND V2 — Sprint 4: Procurement Foundation, Purchase Order uçları.

type purchaseOrderResponse struct {
	ID                   string  `json:"id"`
	PONo                 string  `json:"po_no"`
	SupplierID           string  `json:"supplier_id"`
	SupplierCode         string  `json:"supplier_code,omitempty"`
	SupplierName         string  `json:"supplier_name,omitempty"`
	SourceRFQID          *string `json:"source_rfq_id,omitempty"`
	SourceQuotationID    *string `json:"source_quotation_id,omitempty"`
	Currency             string  `json:"currency"`
	Status               string  `json:"status"`
	IssueDate            string  `json:"issue_date"`
	ExpectedDeliveryDate *string `json:"expected_delivery_date,omitempty"`
	PaymentTerms         string  `json:"payment_terms"`
	DeliveryAddress      string  `json:"delivery_address"`
	Notes                string  `json:"notes"`
	Subtotal             float64 `json:"subtotal"`
	TaxRate              float64 `json:"tax_rate"`
	Tax                  float64 `json:"tax"`
	Total                float64 `json:"total"`
	ApprovedAt           *string `json:"approved_at,omitempty"`
	ApprovedBy           *string `json:"approved_by,omitempty"`
	CancelledAt          *string `json:"cancelled_at,omitempty"`
	CancelledBy          *string `json:"cancelled_by,omitempty"`
	CancelReason         string  `json:"cancel_reason,omitempty"`
	ClosedAt             *string `json:"closed_at,omitempty"`
	ClosedBy             *string `json:"closed_by,omitempty"`
	CreatedAt            string  `json:"created_at"`
	UpdatedAt            string  `json:"updated_at"`
	// Teslim alma (migration 0074): none | partial | complete ve teslim
	// alınmış ama siparişe bağlı onaylı masrafı (faturası) girilmemiş tutar
	// (KDV dahil). Liste ve detayda dolu; tekil yazma yanıtlarında yok.
	ReceiptStatus     string   `json:"receipt_status,omitempty"`
	ReceivedNotCosted *float64 `json:"received_not_costed,omitempty"`
}

func withReceiptSummary(resp purchaseOrderResponse, sum domain.PurchaseOrderReceiptSummary, ok bool) purchaseOrderResponse {
	if !ok {
		sum = domain.PurchaseOrderReceiptSummary{Status: domain.ReceiptStatusNone}
	}
	resp.ReceiptStatus = sum.Status
	v := sum.ReceivedNotCosted
	resp.ReceivedNotCosted = &v
	return resp
}

func toPurchaseOrderResponse(p domain.PurchaseOrder) purchaseOrderResponse {
	return purchaseOrderResponse{
		ID: p.ID, PONo: p.PONo, SupplierID: p.SupplierID,
		SourceRFQID: p.SourceRFQID, SourceQuotationID: p.SourceQuotationID,
		Currency: p.Currency, Status: p.Status,
		IssueDate: p.IssueDate.Format(dateLayout), ExpectedDeliveryDate: dateStrPtr(p.ExpectedDeliveryDate),
		PaymentTerms: p.PaymentTerms, DeliveryAddress: p.DeliveryAddress, Notes: p.Notes,
		Subtotal: p.Subtotal, TaxRate: p.TaxRate, Tax: p.Tax, Total: p.Total,
		ApprovedAt: tsStrPtr(p.ApprovedAt), ApprovedBy: p.ApprovedBy,
		CancelledAt: tsStrPtr(p.CancelledAt), CancelledBy: p.CancelledBy, CancelReason: p.CancelReason,
		ClosedAt: tsStrPtr(p.ClosedAt), ClosedBy: p.ClosedBy,
		CreatedAt: p.CreatedAt.Format(rfc3339), UpdatedAt: p.UpdatedAt.Format(rfc3339),
	}
}

func toPurchaseOrderDetailedResponse(p repository.PurchaseOrderDetailed) purchaseOrderResponse {
	resp := toPurchaseOrderResponse(p.PurchaseOrder)
	resp.SupplierCode = p.SupplierCode
	resp.SupplierName = p.SupplierName
	return resp
}

type purchaseOrderItemResponse struct {
	ID           string  `json:"id"`
	WBSNodeID    *string `json:"wbs_node_id,omitempty"`
	CostCodeID   string  `json:"cost_code_id"`
	BudgetLineID *string `json:"budget_line_id,omitempty"`
	Description  string  `json:"description"`
	Quantity     float64 `json:"quantity"`
	Unit         string  `json:"unit"`
	UnitPrice    float64 `json:"unit_price"`
	LineTotal    float64 `json:"line_total"`
	SortOrder    int     `json:"sort_order"`
	// Teslim alma (migration 0074), yalnızca detayda: iptal edilmemiş
	// teslimlerin kabul / red toplamı; bekleyen = sipariş - kabul - red.
	AcceptedQuantity *float64 `json:"accepted_quantity,omitempty"`
	RejectedQuantity *float64 `json:"rejected_quantity,omitempty"`
	WaitingQuantity  *float64 `json:"waiting_quantity,omitempty"`
}

func toPurchaseOrderItemResponse(i domain.PurchaseOrderItem) purchaseOrderItemResponse {
	return purchaseOrderItemResponse{
		ID: i.ID, WBSNodeID: i.WBSNodeID, CostCodeID: i.CostCodeID, BudgetLineID: i.BudgetLineID,
		Description: i.Description, Quantity: i.Quantity, Unit: i.Unit, UnitPrice: i.UnitPrice, LineTotal: i.LineTotal, SortOrder: i.SortOrder,
	}
}

type purchaseReceiptItemResponse struct {
	PurchaseOrderItemID string  `json:"purchase_order_item_id"`
	AcceptedQuantity    float64 `json:"accepted_quantity"`
	RejectedQuantity    float64 `json:"rejected_quantity"`
	RejectionReason     string  `json:"rejection_reason"`
}

type purchaseReceiptResponse struct {
	ID              string                        `json:"id"`
	PurchaseOrderID string                        `json:"purchase_order_id"`
	SequenceNo      int                           `json:"sequence_no"`
	ReceivedDate    string                        `json:"received_date"`
	DeliveryNoteNo  string                        `json:"delivery_note_no"`
	Destination     string                        `json:"destination"`
	WarehouseID     *string                       `json:"warehouse_id"`
	WarehouseName   string                        `json:"warehouse_name"`
	Notes           string                        `json:"notes"`
	CreatedBy       *string                       `json:"created_by"`
	CreatedByName   string                        `json:"created_by_name"`
	CreatedAt       string                        `json:"created_at"`
	VoidedAt        *string                       `json:"voided_at"`
	VoidReason      string                        `json:"void_reason"`
	Items           []purchaseReceiptItemResponse `json:"items"`
}

func toPurchaseReceiptResponse(r domain.PurchaseReceipt) purchaseReceiptResponse {
	items := make([]purchaseReceiptItemResponse, len(r.Items))
	for i, it := range r.Items {
		items[i] = purchaseReceiptItemResponse{
			PurchaseOrderItemID: it.PurchaseOrderItemID, AcceptedQuantity: it.AcceptedQuantity,
			RejectedQuantity: it.RejectedQuantity, RejectionReason: it.RejectionReason,
		}
	}
	return purchaseReceiptResponse{
		ID: r.ID, PurchaseOrderID: r.PurchaseOrderID, SequenceNo: r.SequenceNo,
		ReceivedDate: r.ReceivedDate.Format(dateLayout), DeliveryNoteNo: r.DeliveryNoteNo,
		Destination: r.Destination, WarehouseID: r.WarehouseID, WarehouseName: r.WarehouseName, Notes: r.Notes,
		CreatedBy: r.CreatedBy, CreatedByName: r.CreatedByName, CreatedAt: r.CreatedAt.Format(rfc3339),
		VoidedAt: tsStrPtr(r.VoidedAt), VoidReason: r.VoidReason, Items: items,
	}
}

// receiptSummaryResponse: siparişin teslim özeti (KDV dahil tutarlar).
type receiptSummaryResponse struct {
	Status            string  `json:"status"`
	AcceptedTotal     float64 `json:"accepted_total"`
	CostedTotal       float64 `json:"costed_total"`
	ReceivedNotCosted float64 `json:"received_not_costed"`
}

type purchaseOrderItemRequest struct {
	WBSNodeID    string  `json:"wbs_node_id"`
	CostCodeID   string  `json:"cost_code_id"`
	BudgetLineID string  `json:"budget_line_id"`
	Description  string  `json:"description"`
	Quantity     float64 `json:"quantity"`
	Unit         string  `json:"unit"`
	UnitPrice    float64 `json:"unit_price"`
}

type purchaseOrderRequest struct {
	SupplierID           string                     `json:"supplier_id"`
	SourceRFQID          string                     `json:"source_rfq_id"`
	SourceQuotationID    string                     `json:"source_quotation_id"`
	IssueDate            string                     `json:"issue_date"`
	ExpectedDeliveryDate *string                    `json:"expected_delivery_date"`
	PaymentTerms         string                     `json:"payment_terms"`
	DeliveryAddress      string                     `json:"delivery_address"`
	Notes                string                     `json:"notes"`
	TaxRate              float64                    `json:"tax_rate"`
	Items                []purchaseOrderItemRequest `json:"items"`
}

func (req purchaseOrderRequest) toInput(userID string) service.PurchaseOrderInput {
	items := make([]service.PurchaseOrderItemInput, len(req.Items))
	for i, it := range req.Items {
		items[i] = service.PurchaseOrderItemInput{
			WBSNodeID: it.WBSNodeID, CostCodeID: it.CostCodeID, BudgetLineID: it.BudgetLineID,
			Description: it.Description, Quantity: it.Quantity, Unit: it.Unit, UnitPrice: it.UnitPrice,
		}
	}
	in := service.PurchaseOrderInput{
		SupplierID: req.SupplierID, SourceRFQID: req.SourceRFQID, SourceQuotationID: req.SourceQuotationID,
		ExpectedDeliveryDate: parseDateParam(req.ExpectedDeliveryDate), PaymentTerms: req.PaymentTerms,
		DeliveryAddress: req.DeliveryAddress, Notes: req.Notes, TaxRate: req.TaxRate, Items: items, UserID: userID,
	}
	return in
}

// toInputWithDates, toInput'a zorunlu sipariş tarihini ekler; tarih
// çözülemezse 400 yazar ve false döner.
func (req purchaseOrderRequest) toInputWithDates(w http.ResponseWriter, userID string) (service.PurchaseOrderInput, bool) {
	in := req.toInput(userID)
	issueDate, ok := requestDate(w, req.IssueDate)
	in.IssueDate = issueDate
	return in, ok
}

func (h *ProjectHandler) ListPurchaseOrders(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListPurchaseOrders(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	sums, err := h.svc.PurchaseOrderReceiptSummaries(r.Context(), chi.URLParam(r, "id"), "", orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]purchaseOrderResponse, len(rows))
	for i, p := range rows {
		sum, ok := sums[p.ID]
		out[i] = withReceiptSummary(toPurchaseOrderDetailedResponse(p), sum, ok)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"purchase_orders": out})
}

func (h *ProjectHandler) CreatePurchaseOrder(w http.ResponseWriter, r *http.Request) {
	var req purchaseOrderRequest
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
	p, err := h.svc.CreatePurchaseOrder(r.Context(), chi.URLParam(r, "id"), orgID, in)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toPurchaseOrderResponse(*p))
}

func (h *ProjectHandler) GetPurchaseOrder(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	p, err := h.svc.GetPurchaseOrder(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "poId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	items, err := h.svc.ListPurchaseOrderItems(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "poId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	commitments, err := h.svc.ListCommitmentsForPurchaseOrder(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "poId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	projectID, poID := chi.URLParam(r, "id"), chi.URLParam(r, "poId")
	received, err := h.svc.PurchaseOrderItemReceipts(r.Context(), projectID, poID, orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	sums, err := h.svc.PurchaseOrderReceiptSummaries(r.Context(), projectID, poID, orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	receipts, err := h.svc.ListPurchaseReceipts(r.Context(), projectID, poID, orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	itemsOut := make([]purchaseOrderItemResponse, len(items))
	for i, it := range items {
		itemsOut[i] = toPurchaseOrderItemResponse(it)
		if rc, ok := received[it.ID]; ok {
			itemsOut[i].AcceptedQuantity, itemsOut[i].RejectedQuantity, itemsOut[i].WaitingQuantity =
				&rc.AcceptedQuantity, &rc.RejectedQuantity, &rc.WaitingQuantity
		}
	}
	commitmentsOut := make([]commitmentResponse, len(commitments))
	for i, c := range commitments {
		commitmentsOut[i] = toCommitmentResponse(c)
	}
	receiptsOut := make([]purchaseReceiptResponse, len(receipts))
	for i, rc := range receipts {
		receiptsOut[i] = toPurchaseReceiptResponse(rc)
	}
	sum, ok := sums[p.ID]
	if !ok {
		sum = domain.PurchaseOrderReceiptSummary{Status: domain.ReceiptStatusNone}
	}
	httpjson.Write(w, http.StatusOK, map[string]any{
		"purchase_order": withReceiptSummary(toPurchaseOrderResponse(*p), sum, true), "items": itemsOut,
		"commitments": commitmentsOut, "receipts": receiptsOut,
		"receipt_summary": receiptSummaryResponse{
			Status: sum.Status, AcceptedTotal: sum.AcceptedGross, CostedTotal: sum.Costed, ReceivedNotCosted: sum.ReceivedNotCosted,
		},
	})
}

type purchaseReceiptItemRequest struct {
	PurchaseOrderItemID string  `json:"purchase_order_item_id"`
	AcceptedQuantity    float64 `json:"accepted_quantity"`
	RejectedQuantity    float64 `json:"rejected_quantity"`
	RejectionReason     string  `json:"rejection_reason"`
}

type purchaseReceiptRequest struct {
	ReceivedDate   string                       `json:"received_date"`
	DeliveryNoteNo string                       `json:"delivery_note_no"`
	Destination    string                       `json:"destination"`
	WarehouseID    string                       `json:"warehouse_id"`
	Notes          string                       `json:"notes"`
	IdempotencyKey string                       `json:"idempotency_key"`
	Items          []purchaseReceiptItemRequest `json:"items"`
}

// CreatePurchaseReceipt: POST /projects/{id}/purchase-orders/{poId}/receipts
// (projects.procurement.receive) -- teslim (irsaliye) girer.
func (h *ProjectHandler) CreatePurchaseReceipt(w http.ResponseWriter, r *http.Request) {
	var req purchaseReceiptRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	received, ok := requestDate(w, req.ReceivedDate)
	if !ok {
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	in := service.PurchaseReceiptInput{
		ReceivedDate: received, DeliveryNoteNo: req.DeliveryNoteNo, Destination: req.Destination,
		WarehouseID: req.WarehouseID, Notes: req.Notes, IdempotencyKey: req.IdempotencyKey, UserID: userID,
	}
	for _, it := range req.Items {
		in.Items = append(in.Items, service.PurchaseReceiptItemInput{
			PurchaseOrderItemID: it.PurchaseOrderItemID, AcceptedQuantity: it.AcceptedQuantity,
			RejectedQuantity: it.RejectedQuantity, RejectionReason: it.RejectionReason,
		})
	}
	rc, err := h.svc.CreatePurchaseReceipt(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "poId"), orgID, in)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toPurchaseReceiptResponse(*rc))
}

// VoidPurchaseReceipt: POST /projects/{id}/purchase-receipts/{receiptId}/void {reason}
// (projects.procurement.receive).
func (h *ProjectHandler) VoidPurchaseReceipt(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	_ = httpjson.Decode(r, &req)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	rc, err := h.svc.VoidPurchaseReceipt(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "receiptId"), orgID, userID, req.Reason)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPurchaseReceiptResponse(*rc))
}

func (h *ProjectHandler) UpdatePurchaseOrder(w http.ResponseWriter, r *http.Request) {
	var req purchaseOrderRequest
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
	p, err := h.svc.UpdatePurchaseOrderDraft(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "poId"), orgID, in)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPurchaseOrderResponse(*p))
}

func (h *ProjectHandler) ApprovePurchaseOrder(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.ApprovePurchaseOrder(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "poId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPurchaseOrderResponse(*p))
}

func (h *ProjectHandler) CancelPurchaseOrder(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	_ = httpjson.Decode(r, &req)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.CancelPurchaseOrder(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "poId"), orgID, userID, req.Reason)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPurchaseOrderResponse(*p))
}

func (h *ProjectHandler) ClosePurchaseOrder(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.ClosePurchaseOrder(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "poId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPurchaseOrderResponse(*p))
}
