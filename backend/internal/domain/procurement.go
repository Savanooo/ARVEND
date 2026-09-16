package domain

import "time"

// ARVEND V2 — Sprint 4: Procurement Foundation. Suppliers (bkz.
// supplier.go) + Purchase Request + RFQ + Supplier Quotations + Bid
// Comparison + Purchase Order + Cost Control entegrasyonu (bkz. migration
// 0037, docs/procurement.md).
//
// Zincir: Purchase Request (proje ihtiyacı) -> RFQ (bir veya daha fazla
// tedarikçiye teklif talebi, PR kaleminden SNAPSHOT alır) -> Supplier
// Quotation (manuel girilen tedarikçi teklifi) -> Award (kazananın
// SEÇİLMESİ, tek doğruluk kaynağı rfqs.awarded_quotation_id'dir) ->
// Purchase Order (approval'da Cost Control'e commitment OLUŞTURUR).
//
// Contract/Change Order (Sprint 3) İLE KARIŞTIRILMAMALI: o zincir
// GELİR (müşteriyle) tarafıdır, bu zincir MALİYET (tedarikçiyle)
// tarafıdır -- ikisi arasında hiçbir otomatik bağlantı YOKTUR.

// ---------- Purchase Request ----------

const (
	PurchaseRequestStatusDraft     = "draft"
	PurchaseRequestStatusSubmitted = "submitted"
	PurchaseRequestStatusApproved  = "approved"
	PurchaseRequestStatusRejected  = "rejected"
	PurchaseRequestStatusCancelled = "cancelled"
)

var validPurchaseRequestStatuses = map[string]bool{
	PurchaseRequestStatusDraft: true, PurchaseRequestStatusSubmitted: true, PurchaseRequestStatusApproved: true,
	PurchaseRequestStatusRejected: true, PurchaseRequestStatusCancelled: true,
}

func ValidPurchaseRequestStatus(s string) bool { return validPurchaseRequestStatuses[s] }

const (
	ProjectEventPurchaseRequestCreated   = "purchase_request_created"
	ProjectEventPurchaseRequestUpdated   = "purchase_request_updated"
	ProjectEventPurchaseRequestSubmitted = "purchase_request_submitted"
	ProjectEventPurchaseRequestWithdrawn = "purchase_request_withdrawn"
	ProjectEventPurchaseRequestApproved  = "purchase_request_approved"
	ProjectEventPurchaseRequestRejected  = "purchase_request_rejected"
	ProjectEventPurchaseRequestCancelled = "purchase_request_cancelled"
)

// PurchaseRequest, purchase_requests satırının domain karşılığıdır.
type PurchaseRequest struct {
	ID             string
	OrganizationID string
	ProjectID      string
	PRNo           string

	Title          string
	Description    string
	NeededBy       *time.Time
	Status         string
	EstimatedTotal float64

	RequestedBy *string

	SubmittedAt *time.Time

	ApprovedAt *time.Time
	ApprovedBy *string

	RejectedAt      *time.Time
	RejectedBy      *string
	RejectionReason string

	CancelledAt  *time.Time
	CancelledBy  *string
	CancelReason string

	CreatedAt time.Time
	UpdatedAt time.Time
}

// PurchaseRequestItem, purchase_request_items satırının domain karşılığıdır.
type PurchaseRequestItem struct {
	ID                string
	OrganizationID    string
	ProjectID         string
	PurchaseRequestID string
	WBSNodeID         *string
	CostCodeID        *string
	BudgetLineID      *string
	Description       string
	Quantity          float64
	Unit              string
	EstimatedUnitCost *float64
	EstimatedTotal    float64
	Notes             string
	SortOrder         int
}

// ---------- RFQ ----------

const (
	RFQStatusDraft     = "draft"
	RFQStatusIssued    = "issued"
	RFQStatusClosed    = "closed"
	RFQStatusCancelled = "cancelled"
)

var validRFQStatuses = map[string]bool{
	RFQStatusDraft: true, RFQStatusIssued: true, RFQStatusClosed: true, RFQStatusCancelled: true,
}

func ValidRFQStatus(s string) bool { return validRFQStatuses[s] }

const (
	RFQSupplierResponsePending   = "pending"
	RFQSupplierResponseResponded = "responded"
	RFQSupplierResponseDeclined  = "declined"
)

const (
	ProjectEventRFQCreated   = "rfq_created"
	ProjectEventRFQUpdated   = "rfq_updated"
	ProjectEventRFQIssued    = "rfq_issued"
	ProjectEventRFQClosed    = "rfq_closed"
	ProjectEventRFQCancelled = "rfq_cancelled"
	ProjectEventRFQAwarded   = "rfq_awarded"
)

// RFQ, rfqs satırının domain karşılığıdır.
type RFQ struct {
	ID                string
	OrganizationID    string
	ProjectID         string
	RFQNo             string
	PurchaseRequestID *string

	Title     string
	IssueDate time.Time
	DueDate   *time.Time
	Status    string
	Notes     string

	AwardedQuotationID *string
	AwardedAt          *time.Time
	AwardedBy          *string
	AwardNotes         string

	CreatedBy *string
	CreatedAt time.Time
	UpdatedAt time.Time
}

// RFQSupplier, rfq_suppliers satırının domain karşılığıdır.
type RFQSupplier struct {
	ID             string
	OrganizationID string
	RFQID          string
	SupplierID     string
	SupplierCode   string
	SupplierName   string
	InvitedAt      time.Time
	ResponseStatus string
}

// RFQItem, rfq_items satırının domain karşılığıdır.
type RFQItem struct {
	ID             string
	OrganizationID string
	ProjectID      string
	RFQID          string
	SourcePRItemID *string
	WBSNodeID      *string
	CostCodeID     *string
	BudgetLineID   *string
	Description    string
	Quantity       float64
	Unit           string
	SortOrder      int
}

// ---------- Supplier Quotation ----------

const (
	ProjectEventQuotationCreated = "quotation_created"
	ProjectEventQuotationUpdated = "quotation_updated"
	ProjectEventQuotationDeleted = "quotation_deleted"
)

// SupplierQuotation, supplier_quotations satırının domain karşılığıdır.
// Kasıtlı olarak KENDİ bir "status" alanı YOKTUR -- "kazanan" bilgisi tek
// doğruluk kaynağı olarak yalnızca RFQ.AwardedQuotationID'de tutulur (bkz.
// migration 0037 §5 gerekçesi).
type SupplierQuotation struct {
	ID             string
	OrganizationID string
	ProjectID      string
	RFQID          string
	SupplierID     string

	QuotationNumber string
	QuotationDate   time.Time
	ValidUntil      *time.Time
	Currency        string

	Subtotal float64
	Discount float64
	TaxRate  float64
	Tax      float64
	Total    float64

	DeliveryDays *int
	PaymentTerms string
	Notes        string

	CreatedBy *string
	CreatedAt time.Time
	UpdatedAt time.Time
}

// QuotationItem, quotation_items satırının domain karşılığıdır.
type QuotationItem struct {
	ID             string
	OrganizationID string
	ProjectID      string
	QuotationID    string
	RFQItemID      string
	Quantity       float64
	UnitPrice      float64
	LineTotal      float64
	Notes          string
}

// ---------- Purchase Order ----------

const (
	PurchaseOrderStatusDraft     = "draft"
	PurchaseOrderStatusApproved  = "approved"
	PurchaseOrderStatusCancelled = "cancelled"
	PurchaseOrderStatusClosed    = "closed"
)

var validPurchaseOrderStatuses = map[string]bool{
	PurchaseOrderStatusDraft: true, PurchaseOrderStatusApproved: true,
	PurchaseOrderStatusCancelled: true, PurchaseOrderStatusClosed: true,
}

func ValidPurchaseOrderStatus(s string) bool { return validPurchaseOrderStatuses[s] }

const (
	ProjectEventPurchaseOrderCreated   = "purchase_order_created"
	ProjectEventPurchaseOrderUpdated   = "purchase_order_updated"
	ProjectEventPurchaseOrderApproved  = "purchase_order_approved"
	ProjectEventPurchaseOrderCancelled = "purchase_order_cancelled"
	ProjectEventPurchaseOrderClosed    = "purchase_order_closed"
)

// PurchaseOrder, purchase_orders satırının domain karşılığıdır.
//
// Durum makinesi: draft -> approved (Cost Control'e commitment OLUŞTURUR,
// bkz. docs/procurement.md §Cost Control Entegrasyonu) ; {draft,approved}
// -> cancelled (gerekçe zorunlu, approved'tan cancel BAĞLI commitment'ları
// voider) ; approved -> closed (TERMİNAL arşiv işareti -- commitment'a
// DOKUNMAZ, bkz. migration yorumu).
type PurchaseOrder struct {
	ID             string
	OrganizationID string
	ProjectID      string
	PONo           string
	SupplierID     string

	SourceRFQID       *string
	SourceQuotationID *string

	Currency string
	Status   string

	IssueDate            time.Time
	ExpectedDeliveryDate *time.Time
	PaymentTerms         string
	DeliveryAddress      string
	Notes                string

	Subtotal float64
	TaxRate  float64
	Tax      float64
	Total    float64

	CreatedBy *string

	ApprovedBy *string
	ApprovedAt *time.Time

	CancelledBy  *string
	CancelledAt  *time.Time
	CancelReason string

	ClosedBy *string
	ClosedAt *time.Time

	CreatedAt time.Time
	UpdatedAt time.Time
}

// PurchaseOrderItem, purchase_order_items satırının domain karşılığıdır.
type PurchaseOrderItem struct {
	ID              string
	OrganizationID  string
	ProjectID       string
	PurchaseOrderID string
	WBSNodeID       *string
	CostCodeID      string
	BudgetLineID    *string
	Description     string
	Quantity        float64
	Unit            string
	UnitPrice       float64
	LineTotal       float64
	SortOrder       int
}
