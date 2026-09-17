package domain

import "time"

// ARVEND V2 — Sprint 5: Taşeron Yönetimi (Subcontractor Management).
// Subcontract (SOV/yaşam döngüsü/baseline kilitleme) + Subcontract Change
// Order + Progress Claim (Hakediş, retention/avans/kesinti) + Cost Control
// commitment entegrasyonu (bkz. migration 0038, docs/subcontracts.md).
//
// KRİTİK: bu, migration 0024'ten kalma "project_subcontractors" (düz
// taşeron kaydı + ödeme defteri, hâlâ canlı, web'de "Finans" sekmesinde
// KULLANILIYOR) İLE KARIŞTIRILMAMALI — o sistem BAĞIMSIZDIR, bu sprintte
// DEĞİŞTİRİLMEMİŞTİR (bkz. docs/subcontracts.md "Legacy Taşeron Sistemi").
//
// Zincir: Supplier (Sprint 4, vendor master YENİDEN KULLANILIR) -> Subcontract
// -> SOV (SubcontractItem) -> Activation (Cost Control commitment
// OLUŞTURUR, source_type='subcontract') -> Subcontract Change Order
// (onaylanınca commitment'ları YENİDEN SENKRONİZE eder) -> Progress Claim
// (retention/advance/deductions, backend-authoritative) -> Termination
// (sertifikalı tutar KORUNUR, kalan taahhüt SERBEST BIRAKILIR).
//
// Customer Contract/Change Order (Sprint 3, GELİR tarafı) İLE
// KARIŞTIRILMAMALI — bu MALİYET tarafıdır, aralarında otomatik bağlantı
// YOKTUR.

// ---------- Subcontract ----------

const (
	SubcontractStatusDraft      = "draft"
	SubcontractStatusActive     = "active"
	SubcontractStatusCompleted  = "completed"
	SubcontractStatusCancelled  = "cancelled"
	SubcontractStatusTerminated = "terminated"
)

var validSubcontractStatuses = map[string]bool{
	SubcontractStatusDraft: true, SubcontractStatusActive: true, SubcontractStatusCompleted: true,
	SubcontractStatusCancelled: true, SubcontractStatusTerminated: true,
}

func ValidSubcontractStatus(s string) bool { return validSubcontractStatuses[s] }

const (
	ProjectEventSubcontractCreated    = "subcontract_created"
	ProjectEventSubcontractUpdated    = "subcontract_updated"
	ProjectEventSubcontractActivated  = "subcontract_activated"
	ProjectEventSubcontractCompleted  = "subcontract_completed"
	ProjectEventSubcontractCancelled  = "subcontract_cancelled"
	ProjectEventSubcontractTerminated = "subcontract_terminated"
)

// Subcontract, project_subcontracts satırının domain karşılığıdır.
//
// Durum makinesi: draft -> active (ticari taban KİLİTLENİR, her SOV kalemi
// için Cost Control commitment OLUŞTURULUR) -> completed (normal tamamlanma,
// commitment'a DOKUNMAZ — PO'nun "closed" durumuyla AYNI ilke) ;
// draft -> cancelled (henüz commitment yok, no-op) ;
// active -> terminated (gerekçe zorunlu, commitment'lar sertifikalı tutara
// göre YENİDEN SENKRONİZE edilir — kazanılan/sertifikalı kısım KORUNUR,
// kalan/gerçekleşmemiş taahhüt SERBEST BIRAKILIR, bkz. docs/subcontracts.md).
type Subcontract struct {
	ID             string
	OrganizationID string
	ProjectID      string
	SubcontractNo  string
	SupplierID     string

	Title          string
	ScopeSummary   string
	OriginalAmount float64
	Currency       string
	Status         string

	EffectiveDate         *time.Time
	StartDate             *time.Time
	PlannedCompletionDate *time.Time
	RetentionPercent      *float64
	AdvanceAmount         *float64
	PaymentTerms          string
	Notes                 string

	CreatedBy *string

	ActivatedAt *time.Time
	ActivatedBy *string

	CompletedAt *time.Time
	CompletedBy *string

	CancelledAt  *time.Time
	CancelledBy  *string
	CancelReason string

	TerminatedAt      *time.Time
	TerminatedBy      *string
	TerminationReason string

	CreatedAt time.Time
	UpdatedAt time.Time
}

// SubcontractItem, subcontract_items (Schedule of Values / SOV) satırının
// domain karşılığıdır.
type SubcontractItem struct {
	ID             string
	OrganizationID string
	ProjectID      string
	SubcontractID  string
	WBSNodeID      *string
	CostCodeID     string
	BudgetLineID   *string
	Description    string
	Quantity       *float64
	Unit           string
	UnitPrice      *float64
	OriginalAmount float64
	SortOrder      int
}

// ---------- Subcontract Change Order ----------

const (
	SubcontractChangeOrderStatusDraft     = "draft"
	SubcontractChangeOrderStatusSubmitted = "submitted"
	SubcontractChangeOrderStatusApproved  = "approved"
	SubcontractChangeOrderStatusRejected  = "rejected"
	SubcontractChangeOrderStatusCancelled = "cancelled"
)

var validSubcontractChangeOrderStatuses = map[string]bool{
	SubcontractChangeOrderStatusDraft: true, SubcontractChangeOrderStatusSubmitted: true,
	SubcontractChangeOrderStatusApproved: true, SubcontractChangeOrderStatusRejected: true,
	SubcontractChangeOrderStatusCancelled: true,
}

func ValidSubcontractChangeOrderStatus(s string) bool { return validSubcontractChangeOrderStatuses[s] }

const (
	SubcontractChangeTypeAddition  = "addition"
	SubcontractChangeTypeDeduction = "deduction"
)

const (
	ProjectEventSubcontractChangeOrderCreated   = "subcontract_change_order_created"
	ProjectEventSubcontractChangeOrderUpdated   = "subcontract_change_order_updated"
	ProjectEventSubcontractChangeOrderSubmitted = "subcontract_change_order_submitted"
	ProjectEventSubcontractChangeOrderApproved  = "subcontract_change_order_approved"
	ProjectEventSubcontractChangeOrderRejected  = "subcontract_change_order_rejected"
	ProjectEventSubcontractChangeOrderCancelled = "subcontract_change_order_cancelled"
)

// SubcontractChangeOrder, subcontract_change_orders satırının domain
// karşılığıdır. Customer Change Order (Sprint 3) tablosuyla HİÇBİR İLİŞKİSİ
// YOKTUR — MALİYET tarafına özgü, bağımsız bir domaindir.
//
// Durum makinesi: draft -> submitted -> {approved, rejected} ;
// {draft,submitted} -> cancelled. Yalnızca APPROVED durumu
// current_subcontract_value ve commitment'ları etkiler (bkz.
// SignedEffect).
type SubcontractChangeOrder struct {
	ID             string
	OrganizationID string
	ProjectID      string
	SubcontractID  string
	Number         string

	Title       string
	Description string
	ChangeType  string
	Amount      float64
	Status      string
	Reason      string

	RequestedAt *time.Time

	ApprovedAt *time.Time
	ApprovedBy *string

	RejectedAt      *time.Time
	RejectedBy      *string
	RejectionReason string

	CancelledAt *time.Time
	CancelledBy *string

	CreatedBy *string
	CreatedAt time.Time
	UpdatedAt time.Time
}

// SignedEffect, onaylı bir değişikliğin current_subcontract_value'ya net
// etkisini döner (addition -> +Amount, deduction -> -Amount) — yalnızca
// status='approved' iken anlamlıdır (Sprint 3 ChangeOrder.SignedEffect
// İLE AYNI ilke).
func (co SubcontractChangeOrder) SignedEffect() float64 {
	if co.ChangeType == SubcontractChangeTypeDeduction {
		return -co.Amount
	}
	return co.Amount
}

// SubcontractChangeOrderItem, subcontract_change_order_items satırının
// domain karşılığıdır.
type SubcontractChangeOrderItem struct {
	ID             string
	OrganizationID string
	ProjectID      string
	ChangeOrderID  string
	WBSNodeID      *string
	CostCodeID     string
	BudgetLineID   *string
	Description    string
	Amount         float64
	SortOrder      int
}

// ---------- Subcontract Progress Claim (Hakediş) ----------

const (
	ProgressClaimStatusDraft     = "draft"
	ProgressClaimStatusSubmitted = "submitted"
	ProgressClaimStatusCertified = "certified"
	ProgressClaimStatusRejected  = "rejected"
	ProgressClaimStatusCancelled = "cancelled"
)

var validProgressClaimStatuses = map[string]bool{
	ProgressClaimStatusDraft: true, ProgressClaimStatusSubmitted: true, ProgressClaimStatusCertified: true,
	ProgressClaimStatusRejected: true, ProgressClaimStatusCancelled: true,
}

func ValidProgressClaimStatus(s string) bool { return validProgressClaimStatuses[s] }

const (
	ProjectEventProgressClaimCreated   = "subcontract_progress_claim_created"
	ProjectEventProgressClaimUpdated   = "subcontract_progress_claim_updated"
	ProjectEventProgressClaimSubmitted = "subcontract_progress_claim_submitted"
	ProjectEventProgressClaimCertified = "subcontract_progress_claim_certified"
	ProjectEventProgressClaimRejected  = "subcontract_progress_claim_rejected"
	ProjectEventProgressClaimCancelled = "subcontract_progress_claim_cancelled"
)

// SubcontractProgressClaim, subcontract_progress_claims satırının domain
// karşılığıdır — müşteri hakedişi DEĞİLDİR (Sprint 6'ya bırakıldı), Supplier
// Invoice DEĞİLDİR (bu sprintte yok), Payment DEĞİLDİR (net_payable bir
// YÜKÜMLÜLÜK tutarıdır, gerçek ödeme ayrı bir gelecek-sprint olayıdır).
//
// Durum makinesi: draft -> submitted -> {certified, rejected} ;
// {draft,submitted} -> cancelled. CERTIFIED terminal ve İMMUTABLE'dır —
// düzeltme gerekiyorsa yeni bir hakediş (revizyon/ters kayıt) oluşturulur,
// sertifikalı bir kayıt SESSİZCE düzenlenmez.
//
// ÖNEMLİ (spec §23 kararı, bkz. docs/subcontracts.md): sertifikalı bir
// hakediş Cost Control'ün Actual'ına GİRMEZ bu sprintte — yalnızca ticari/
// operasyonel bir sertifikasyon kaydıdır. Actual, gelecekte Tedarikçi
// Faturası/AP entegrasyonundan gelecektir (project_expenses'in "tek
// finansal kaynak" ilkesiyle AYNI, migration 0024 gerekçesi).
type SubcontractProgressClaim struct {
	ID             string
	OrganizationID string
	ProjectID      string
	SubcontractID  string
	ClaimNumber    string

	PeriodStart *time.Time
	PeriodEnd   time.Time
	Status      string

	GrossWorkAmount          float64
	RetentionPercentSnapshot float64
	RetentionAmount          float64
	AdvanceRecoveryAmount    float64
	OtherDeductions          float64
	PreviousCertifiedAmount  float64
	CurrentCertifiedAmount   float64
	NetPayable               float64

	SubmittedAt *time.Time

	CertifiedAt *time.Time
	CertifiedBy *string

	RejectedAt      *time.Time
	RejectedBy      *string
	RejectionReason string

	CancelledAt *time.Time
	CancelledBy *string

	Notes     string
	CreatedBy *string
	CreatedAt time.Time
	UpdatedAt time.Time
}

// SubcontractProgressClaimItem, subcontract_progress_claim_items satırının
// domain karşılığıdır. ProgressPercent/RemainingAmount KASITLI OLARAK
// STORED DEĞİLDİR — repository katmanında ScheduledValue/
// CumulativeProgressAmount'tan HER ZAMAN canlı türetilir (tek
// source-of-truth, bkz. docs/subcontracts.md §Hakediş).
type SubcontractProgressClaimItem struct {
	ID                       string
	OrganizationID           string
	ProjectID                string
	ProgressClaimID          string
	SubcontractItemID        string
	ScheduledValue           float64
	PreviousProgressAmount   float64
	CurrentProgressAmount    float64
	CumulativeProgressAmount float64
	SortOrder                int

	// Join-only alanlar (subcontract_items'tan) — persist edilmez, hakediş
	// UI'ının SOV kalemi açıklamasını/birimini AYRI bir sorgu yapmadan
	// göstermesi için.
	ItemDescription string
	ItemUnit        string
}

// ProgressPercent, %100 üstüne KESİNLİKLE geçmeyen (DB CHECK'i ile de
// garanti edilen) ilerleme yüzdesini döner.
func (i SubcontractProgressClaimItem) ProgressPercent() float64 {
	if i.ScheduledValue <= 0 {
		return 0
	}
	return round2(i.CumulativeProgressAmount * 100 / i.ScheduledValue)
}

// RemainingAmount, bu SOV kaleminin bu hakedişe kadar HENÜZ sertifika
// edilmemiş kısmını döner.
func (i SubcontractProgressClaimItem) RemainingAmount() float64 {
	r := i.ScheduledValue - i.CumulativeProgressAmount
	if r < 0 {
		return 0
	}
	return round2(r)
}

func round2(v float64) float64 {
	return float64(int64(v*100+0.5)) / 100
}

// ---------- Subcontract Payment (Gerçek Ödeme) ----------

const (
	ProjectEventSubcontractPaymentMade = "subcontract_payment_made"
	ProjectEventSubcontractPaymentVoid = "subcontract_payment_void"
)

// SubcontractPayment, subcontract_payments satırının domain karşılığıdır —
// GERÇEK nakit çıkışıdır. Progress Claim'in NetPayable'ı bir YÜKÜMLÜLÜK,
// bu ise ÖDEME olayıdır (bkz. SubcontractProgressClaim yorumu). Sertifikasyon
// ile ödeme BİRBİRİNDEN BAĞIMSIZDIR — bir hakediş hiç ödenmeden sertifika
// edilebilir, bir ödeme de hiçbir hakedişe bağlı olmadan (avans/mobilizasyon)
// yapılabilir. Bu yüzden ProgressClaimID OPSİYONELDİR (Collection'ın
// PaymentPlanItemID İLE AYNI ilke). Durum makinesi YOKTUR — Collection/
// Expense İLE AYNI create+void deseni.
type SubcontractPayment struct {
	ID              string
	OrganizationID  string
	ProjectID       string
	SubcontractID   string
	ProgressClaimID *string
	Amount          float64
	Currency        string
	PaidDate        time.Time
	PaymentMethod   string
	ReferenceNo     string
	Description     string
	CreatedBy       *string
	CreatedAt       time.Time
	VoidedAt        *time.Time
	VoidedBy        *string
	VoidReason      string
}
