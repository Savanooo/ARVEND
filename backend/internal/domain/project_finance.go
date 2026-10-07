package domain

import (
	"math"
	"time"
)

// --- Ödeme planı kalemi durumları ---
//
// SAKLANAN yalnızca "pending" ve "cancelled"dır (manuel niyet).
// partial/paid/overdue, tahsilat toplamı ve due_date'ten OKUMA ANINDA
// türetilir -- hiçbir zaman kolonda tutulmaz, dolayısıyla bayatlayamaz.
const (
	PlanItemPending   = "pending"
	PlanItemPartial   = "partial"
	PlanItemPaid      = "paid"
	PlanItemOverdue   = "overdue"
	PlanItemCancelled = "cancelled"
)

// Masraf kategorileri. 'subcontractor' BİLİNÇLİ olarak yoktur: taşerona
// ödenen para yalnızca taşeron ödemeleri üzerinden girilir, aksi halde
// aynı tutar hem masraf hem taşeron ödemesi olarak iki kez sayılabilirdi.
const (
	ExpenseMaterial      = "material"
	ExpensePersonnel     = "personnel"
	ExpenseTransport     = "transport"
	ExpenseAccommodation = "accommodation"
	ExpenseFood          = "food"
	ExpenseEquipment     = "equipment"
	ExpenseOther         = "other"
)

var validExpenseCategories = map[string]bool{
	ExpenseMaterial: true, ExpensePersonnel: true, ExpenseTransport: true,
	ExpenseAccommodation: true, ExpenseFood: true, ExpenseEquipment: true, ExpenseOther: true,
}

func ValidExpenseCategory(s string) bool { return validExpenseCategories[s] }

// Masraf onay durumları (bkz. migration 0060). Her yeni/düzenlenen masraf
// pending başlar; para toplamlarına YALNIZCA approved girer (iptal
// edilmemişse). Listeler her durumu gösterir.
const (
	ExpenseApprovalPending  = "pending"
	ExpenseApprovalApproved = "approved"
	ExpenseApprovalRejected = "rejected"
)

// ValidExpenseVATRate: masrafın KDV oranı (%) 0-100 arasında olmalı; nil =
// "belirtilmedi" (migration 0065) ve her zaman geçerlidir.
func ValidExpenseVATRate(rate *float64) bool {
	return rate == nil || (*rate >= 0 && *rate <= 100)
}

// ExpenseDecisionNoteMaxLen, ret gerekçesinin kolon sınırıdır
// (decision_note varchar(500)) -- aşan metin DB hatası yerine Türkçe bir
// doğrulama hatasıyla döner.
const ExpenseDecisionNoteMaxLen = 500

const (
	InvoiceTypeSales    = "sales"
	InvoiceTypePurchase = "purchase"
)

const (
	InvoiceDraft     = "draft"
	InvoiceIssued    = "issued"
	InvoiceSent      = "sent"
	InvoicePaid      = "paid"
	InvoiceCancelled = "cancelled"
)

var validInvoiceStatuses = map[string]bool{
	InvoiceDraft: true, InvoiceIssued: true, InvoiceSent: true,
	InvoicePaid: true, InvoiceCancelled: true,
}

func ValidInvoiceStatus(s string) bool { return validInvoiceStatuses[s] }

func ValidInvoiceType(s string) bool {
	return s == InvoiceTypeSales || s == InvoiceTypePurchase
}

const (
	SubcontractorPlanned   = "planned"
	SubcontractorActive    = "active"
	SubcontractorCompleted = "completed"
	SubcontractorCancelled = "cancelled"
)

var validSubcontractorStatuses = map[string]bool{
	SubcontractorPlanned: true, SubcontractorActive: true,
	SubcontractorCompleted: true, SubcontractorCancelled: true,
}

func ValidSubcontractorStatus(s string) bool { return validSubcontractorStatuses[s] }

// Proje olay tipleri (project_events).
const (
	ProjectEventCreated                  = "project_created"
	ProjectEventUpdated                  = "project_updated"
	ProjectEventStatusChanged            = "project_status_changed"
	ProjectEventPaymentPlanCreated       = "payment_plan_created"
	ProjectEventPaymentPlanUpdated       = "payment_plan_updated"
	ProjectEventPaymentPlanCancelled     = "payment_plan_cancelled"
	ProjectEventCollectionReceived       = "collection_received"
	ProjectEventCollectionVoided         = "collection_voided"
	ProjectEventExpenseAdded             = "expense_added"
	ProjectEventExpenseUpdated           = "expense_updated"
	ProjectEventExpenseVoided            = "expense_voided"
	ProjectEventExpenseApproved          = "expense_approved"
	ProjectEventExpenseRejected          = "expense_rejected"
	ProjectEventInvoiceCreated           = "invoice_created"
	ProjectEventInvoiceStatusChanged     = "invoice_status_changed"
	ProjectEventSubcontractorAdded       = "subcontractor_added"
	ProjectEventSubcontractorUpdated     = "subcontractor_updated"
	ProjectEventSubcontractorPaymentMade = "subcontractor_payment_added"
	ProjectEventSubcontractorPaymentVoid = "subcontractor_payment_voided"
)

type PaymentPlanItem struct {
	ID              string
	OrganizationID  string
	ProjectID       string
	SortOrder       int
	Name            string
	Percentage      *float64
	PlannedAmount   float64
	DueDate         *time.Time
	Notes           string
	CreatedAt       time.Time
	UpdatedAt       time.Time
	CollectedAmount float64
	// Status, türetilmiş (efektif) durumdur; iptal dışındaki değerler
	// tahsilat toplamı ve due_date'ten hesaplanır.
	Status string
}

// IsPastDue, dueDate'in "bugün"den (now'un takvim günü) önce olup
// olmadığını söyler -- vade GÜNÜNÜN kendisi henüz gecikmiş sayılmaz.
// dueDate bir "date" kolonundan gelir (saat bileşeni anlamsızdır); bu
// yüzden karşılaştırma iki zaman DAMGASI değil, iki TAKVİM GÜNÜ arasında
// yapılır. SQL tarafındaki "due_date < CURRENT_DATE" kuralıyla birebir
// aynı semantiği taşır (bkz. project_operations.sql CountProjectTaskStats).
func IsPastDue(dueDate *time.Time, now time.Time) bool {
	if dueDate == nil {
		return false
	}
	dy, dm, dd := dueDate.Date()
	ny, nm, nd := now.Date()
	due := time.Date(dy, dm, dd, 0, 0, 0, 0, time.UTC)
	today := time.Date(ny, nm, nd, 0, 0, 0, 0, time.UTC)
	return due.Before(today)
}

// EffectivePlanItemStatus, kalemin gerçek durumunu tahsilat toplamına ve
// vade tarihine göre türetir. storedStatus yalnızca "cancelled" ise
// belirleyicidir.
func EffectivePlanItemStatus(storedStatus string, planned, collected float64, dueDate *time.Time, now time.Time) string {
	if storedStatus == PlanItemCancelled {
		return PlanItemCancelled
	}
	switch {
	case collected >= planned:
		return PlanItemPaid
	case collected > 0:
		// Kısmen tahsil edilmiş ama vadesi geçmişse gecikme daha önemli
		// bilgidir.
		if IsPastDue(dueDate, now) {
			return PlanItemOverdue
		}
		return PlanItemPartial
	default:
		if IsPastDue(dueDate, now) {
			return PlanItemOverdue
		}
		return PlanItemPending
	}
}

type Collection struct {
	ID                string
	OrganizationID    string
	ProjectID         string
	PaymentPlanItemID *string
	// InvoiceID: satış faturası "ödendi" yapılınca otomatik açılan tahsilatta
	// fatura (bkz. migration 0050); elle girilende nil.
	InvoiceID     *string
	Amount        float64
	Currency      string
	ReceivedDate  time.Time
	PaymentMethod string
	Description   string
	ReferenceNo   string
	CreatedBy     *string
	CreatedAt     time.Time
	VoidedAt      *time.Time
	VoidedBy      *string
	VoidReason    string
}

type Expense struct {
	ID             string
	OrganizationID string
	ProjectID      string
	Category       string
	Description    string
	Amount         float64
	Currency       string
	ExpenseDate    time.Time
	SupplierName   string
	InvoiceNo      string
	Notes          string
	CreatedBy      *string
	CreatedAt      time.Time
	VoidedAt       *time.Time
	VoidedBy       *string
	VoidReason     string
	// ChangeOrderID, OPSİYONELDİR: bu masrafı bir ek işe etiketler (Faz 8
	// kârlılık filtrelemesi). NULL ise ana sözleşme kapsamındadır.
	ChangeOrderID *string
	// CostCodeID/BudgetLineID, Cost Control (Sprint 2) alanlarıdır --
	// İKİSİ de OPSİYONELDİR, eski masraflarda NULL kalır (bkz. migration
	// 0035 backward-compat notu). BudgetLineID doluysa maliyet kontrolü
	// bu satırı "bütçeli" (budgeted) olarak sayar; yalnızca CostCodeID
	// doluysa "bütçe dışı" (unbudgeted) olarak.
	CostCodeID   *string
	BudgetLineID *string
	// ApprovalStatus: pending | approved | rejected (bkz. ExpenseApproval*).
	// DecidedBy/DecidedAt/DecisionNote son kararın izidir; düzenleme onları
	// temizler. Onay akışından önceki masraflarda (approved) boştur.
	ApprovalStatus string
	DecidedBy      *string
	DecidedAt      *time.Time
	DecisionNote   string
	// VATRate: KDV oranı (%), nil = belirtilmedi (migration 0065) -- Amount
	// yine ödenen tutardır (oran verilmişse KDV dahil). VATAmount tutarın
	// içindeki KDV'dir, DB'de oranla birlikte üretilir (oran nil ise nil).
	VATRate   *float64
	VATAmount *float64
}

// NetAmount: KDV hariç tutar (kuruşa yuvarlı); KDV belirtilmemişse nil --
// bilinmeyen KDV'yi sıfır saymak "KDV hariç" diye yanlış bir rakam olurdu.
func (e Expense) NetAmount() *float64 {
	if e.VATAmount == nil {
		return nil
	}
	v := math.Round((e.Amount-*e.VATAmount)*100) / 100
	return &v
}

type ProjectInvoice struct {
	ID             string
	OrganizationID string
	ProjectID      string
	InvoiceNo      string
	InvoiceType    string
	InvoiceDate    time.Time
	DueDate        *time.Time
	Amount         float64
	Currency       string
	Status         string
	CustomerName   string
	Notes          string
	CreatedBy      *string
	CreatedAt      time.Time
}

type Subcontractor struct {
	ID              string
	OrganizationID  string
	ProjectID       string
	Name            string
	CompanyName     string
	Phone           string
	Email           string
	WorkDescription string
	ContractAmount  float64
	Currency        string
	StartDate       *time.Time
	EndDate         *time.Time
	Status          string
	Notes           string
	CreatedAt       time.Time
	// ChangeOrderID, OPSİYONELDİR (bkz. Expense.ChangeOrderID notu).
	ChangeOrderID *string
	// Ödeme kayıtlarından toplanır.
	PaidAmount      float64
	RemainingAmount float64
	// ProfitPercent: taşeron bedelinin üstüne müşteriye yansıtılan kâr
	// payımız (%). nil = girilmemiş. Tutarlar bundan hesaplanır, saklanmaz
	// (bkz. SubcontractorProfit).
	ProfitPercent *float64
	// CostCodeID, Cost Control (Sprint 2) alanıdır -- OPSİYONELDİR (bkz.
	// Expense.CostCodeID notu). Taşeron BUDGET_LINE_ID TAŞIMAZ (bkz.
	// migration 0035: taşeron taahhüdü yalnızca cost_code_id üzerinden
	// kırılım tablosuna "bütçe dışı" olarak katkı verir).
	CostCodeID *string
}

type SubcontractorPayment struct {
	ID              string
	OrganizationID  string
	ProjectID       string
	SubcontractorID string
	Amount          float64
	Currency        string
	PaidDate        time.Time
	Description     string
	CreatedBy       *string
	CreatedAt       time.Time
	VoidedAt        *time.Time
	VoidedBy        *string
	VoidReason      string
}

// ProjectFinancialSummary, projenin tüm finans tablosunu tek seferde
// taşır. Tüm değerler SQL tarafında numeric üzerinde hesaplanır.
type ProjectFinancialSummary struct {
	// BaseContractAmount, ana sözleşme bedelidir (projects.contract_amount
	// -- ASLA değişmez). ContractAmount alanı geriye dönük uyumluluk için
	// AYNI değeri taşımaya devam eder.
	BaseContractAmount float64
	ContractAmount     float64
	Currency           string

	// Faz 8: onaylı/bekleyen ek iş-eksiltme toplamları ve bunlardan
	// türetilen güncel/potansiyel proje bedeli. Hiçbiri bir kolon olarak
	// TUTULMAZ -- her okumada change order kayıtlarından aggregate edilir.
	ApprovedAdditions      float64
	ApprovedDeductions     float64
	CurrentContractValue   float64
	PendingAdditions       float64
	PendingDeductions      float64
	PotentialContractValue float64

	PlannedCollections           float64
	CollectedAmount              float64
	RemainingReceivable          float64
	TotalExpenses                float64
	TotalSubcontractorCommitment float64
	SubcontractorPaid            float64
	SubcontractorRemaining       float64
	// Sprint 5 follow-up: legacy taşeron ödemelerinin (yukarıda) AYRI,
	// paralel kaynağı -- yeni "project_subcontracts" (Sprint 5) sözleşmelerine
	// yapılan GERÇEK ödemeler (bkz. migration 0039). Fiziksel olarak farklı
	// tablolara bağlı oldukları için RealizedCost/CommittedCost'a SAF TOPLAMA
	// ile katılırlar, çift sayım riski yoktur (bkz. docs/subcontracts.md).
	NewSubcontractPaid      float64
	NewSubcontractRemaining float64
	IssuedInvoiceTotal      float64
	PaidInvoiceTotal        float64
	// RealizedCost: gerçekleşen masraflar + taşerona (legacy+yeni) GERÇEKTEN ödenen.
	RealizedCost float64
	// CommittedCost: gerçekleşen + taşeron sözleşmelerinin (legacy+yeni) kalan taahhüdü.
	CommittedCost          float64
	RealizedGrossProfit    float64
	EstimatedGrossProfit   float64
	RealizedMarginPercent  float64
	EstimatedMarginPercent float64

	// KDV: yukarıdaki bedel ve kârlar KDV DAHİLDİR (sözleşme bedeli teklifin
	// KDV dahil genel toplamı; maliyetler girildiği gibi). Ürün sahibi kararı
	// (2026-10-06): KDV hariç kâr da gösterilir. ContractVATKnown=false ise
	// proje tekliften açılmamıştır, KDV bilinmez ve "net" alanlar KDV dahil
	// değerlerle aynıdır.
	ContractVATAmount         float64
	ContractVATKnown          bool
	CurrentContractValueNet   float64
	RealizedGrossProfitNet    float64
	EstimatedGrossProfitNet   float64
	RealizedMarginPercentNet  float64
	EstimatedMarginPercentNet float64

	// Forecast*: "Tahmini" bölümünün TEK kaynağı -- bütçe varsa Maliyet
	// Kontrolü'nün EAC'si (ForecastBasis = "budget"), yoksa taahhüt bazlı
	// tahmin ("commitments"). Web ve mobil aynı rakamı göstersin diye seçim
	// sunucuda yapılır (önceden yalnızca mobil seçiyordu).
	ForecastBasis            string
	ForecastCost             float64
	ForecastProfit           float64
	ForecastProfitNet        float64
	ForecastMarginPercent    float64
	ForecastMarginPercentNet float64
}

// Tahmin kaynakları (ProjectFinancialSummary.ForecastBasis).
const (
	ForecastBasisBudget      = "budget"
	ForecastBasisCommitments = "commitments"
)

// MarginPercent: kâr / bedel × 100, kuruş hassasiyetinde; bedel <= 0 ise 0.
// SQL'deki marj ile AYNI bant (±99.999.999,99) -- veri hatasında taşmasın.
func MarginPercent(profit, base float64) float64 {
	if base <= 0 {
		return 0
	}
	m := math.Round(profit*100/base*100) / 100
	return math.Max(-99999999.99, math.Min(99999999.99, m))
}

// OverCollected, müşterinin sözleşme bedelinden fazla ödeme yaptığı
// tutarı döner (yoksa 0). Bakiye negatifse UI bunu "fazla tahsilat"
// olarak gösterir -- negatif değer gizlenmez.
func (s ProjectFinancialSummary) OverCollected() float64 {
	if s.RemainingReceivable < 0 {
		return -s.RemainingReceivable
	}
	return 0
}

type ProjectEvent struct {
	ID             string
	OrganizationID string
	ProjectID      string
	EventType      string
	UserID         *string
	Metadata       map[string]any
	CreatedAt      time.Time
}

// SubcontractorProfit: kâr payı girilmiş taşeronda (kârımız, müşteriye
// yansıyan tutar) -- kuruşa yuvarlı. Kâr payı yoksa ok=false.
func (s Subcontractor) SubcontractorProfit() (profit, customer float64, ok bool) {
	if s.ProfitPercent == nil {
		return 0, 0, false
	}
	profit = math.Round(s.ContractAmount*(*s.ProfitPercent)) / 100
	return profit, math.Round((s.ContractAmount+profit)*100) / 100, true
}
