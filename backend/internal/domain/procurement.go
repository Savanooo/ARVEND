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
	// Onaylı talebin "proje maliyetine eklensin mi" kararı (ya da tahmini
	// tutarı) sonradan değişti (migration 0078).
	ProjectEventPurchaseRequestCostDecision = "purchase_request_cost_decision"
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

	// Satın alma proje maliyetine girer (migration 0078): onaylayan "proje
	// maliyetine eklensin mi" diye karar verir (varsayılan evet; depo/stok ya
	// da genel kullanım için hayır). CostEstimate onayda girilen tahmini
	// tutardır (kalemlerde fiyat yokken); nil ise maliyete EstimatedTotal girer.
	IncludeInProjectCost bool
	CostEstimate         *float64

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

	ProjectEventPurchaseReceiptRecorded = "purchase_receipt_recorded"
	ProjectEventPurchaseReceiptVoided   = "purchase_receipt_voided"

	// Siparişin "proje maliyetine eklensin mi" kararı değişti (migration 0078).
	ProjectEventPurchaseOrderCostDecision = "purchase_order_cost_decision"
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
	// PurchaseRequestID: siparişin talebi (migration 0078). Talepten açılan
	// sipariş, onaylanınca talebin tahmini tutarının YERİNE maliyete girer ve
	// talebin "maliyete eklensin mi" kararını devralır.
	PurchaseRequestID    *string
	IncludeInProjectCost bool

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

// ---------- Siparişten teslim alma (migration 0074) ----------

const (
	ReceiptDestinationSite      = "site"
	ReceiptDestinationWarehouse = "warehouse"

	// Siparişin teslim durumu: hiç teslim yok / kısmi / her kalem tamam
	// (bekleyen = sipariş - kabul - red sıfır).
	ReceiptStatusNone     = "none"
	ReceiptStatusPartial  = "partial"
	ReceiptStatusComplete = "complete"
)

// PurchaseReceipt: bir teslim (irsaliye). Değişmez; yanlışsa iptal edilir.
type PurchaseReceipt struct {
	ID              string
	ProjectID       string
	PurchaseOrderID string
	SequenceNo      int
	ReceivedDate    time.Time
	DeliveryNoteNo  string
	Destination     string
	WarehouseID     *string
	WarehouseName   string
	Notes           string
	CreatedBy       *string
	CreatedByName   string
	CreatedAt       time.Time
	VoidedAt        *time.Time
	VoidReason      string
	Items           []PurchaseReceiptItem
}

type PurchaseReceiptItem struct {
	PurchaseOrderItemID string
	AcceptedQuantity    float64
	RejectedQuantity    float64
	RejectionReason     string
}

// PurchaseOrderItemReceipt: sipariş kalemi başına iptal edilmemiş
// teslimlerin toplamı. Bekleyen = sipariş - kabul - red (sıfırın altına inmez).
type PurchaseOrderItemReceipt struct {
	AcceptedQuantity float64
	RejectedQuantity float64
	WaitingQuantity  float64
}

// PurchaseOrderReceiptSummary: siparişin teslim özeti. AcceptedGross
// kabul edilen malın KDV dahil değeri; Costed siparişe bağlı onaylı
// masraflar (fatura); ReceivedNotCosted = max(AcceptedGross - Costed, 0).
type PurchaseOrderReceiptSummary struct {
	Status            string
	AcceptedNet       float64
	AcceptedGross     float64
	Costed            float64
	ReceivedNotCosted float64
}

// ---------- Satın almanın proje maliyetine katkısı (migration 0078) ----------

// PurchaseCost kaynakları: maliyete ne giriyor.
const (
	PurchaseCostSourceNone     = "none"     // henüz maliyete girmez (taslak/gönderilmiş/iptal)
	PurchaseCostSourceEstimate = "estimate" // onaylı talebin tahmini tutarı
	PurchaseCostSourceOrders   = "orders"   // talebin onaylı siparişleri (tahminin yerine)
	PurchaseCostSourceOrder    = "order"    // siparişin tutarı
	PurchaseCostSourceInvoices = "invoices" // siparişe bağlı faturalar sipariş tutarını aştı
)

// PurchaseCostNoPriceWarning: onaylanacak/onaylı talebin maliyete girecek
// tutarı 0 (kalemlerde fiyat yok) -- onaylayan tahmini tutar girebilir.
const PurchaseCostNoPriceWarning = "Bu talepte fiyat yok; maliyete 0 TL girer."

// PurchaseCost, bir talebin ya da siparişin proje maliyetine katkısı
// (purchase_request_cost_basis / purchase_order_cost_basis görünümleri).
// Amount bugün maliyete giren tutardır; Potential "maliyete eklenseydi"
// tutarıdır (karar ekranında "maliyete eklenecek: X" ve "Maliyete
// eklenmedi" durumunda gösterilen). Tutarlar KDV dahildir.
type PurchaseCost struct {
	Included  bool
	Amount    float64
	Potential float64
	Source    string
	// Yalnızca siparişte: sipariş tutarı (kısa kapatılmışsa teslim alınan
	// değer) ve siparişe bağlı onaylı faturalar.
	OrderAmount    float64
	InvoicedAmount float64
	// UnpricedItems: talepte fiyatı girilmemiş kalem sayısı.
	UnpricedItems int
	Warning       string
}
