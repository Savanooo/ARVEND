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
	ProjectEventCreated       = "project_created"
	ProjectEventUpdated       = "project_updated"
	ProjectEventStatusChanged = "project_status_changed"
	// Proje silme talebi (migration 0070). Onay projeyi sildiği için
	// "onaylandı" olayı yazılmaz (organization_events'e project_deleted).
	ProjectEventDeleteRequested          = "project_delete_requested"
	ProjectEventDeleteRejected           = "project_delete_rejected"
	ProjectEventDeleteWithdrawn          = "project_delete_withdrawn"
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
	ProjectEventSubcontractorAdvanceUsed = "subcontractor_advance_offset"
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
	// PurchaseOrderID (migration 0074): masraf bir satın alma siparişinin
	// faturasıysa o sipariş -- "teslim alınmış, maliyeti girilmemiş" tutar
	// bundan düşer.
	PurchaseOrderID *string
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
	// Attachments: fiş / belge ekleri (migration 0076). Yalnızca listeler
	// (Finans, Masraflarım, Masraflar) ve düzenleme yanıtı doldurur; nil =
	// "yüklenmedi" (yanıtta alan hiç yok), boş dilim = "eki yok".
	Attachments []ExpenseAttachment
}

// ExpenseAttachment: masrafın fişi, faturası ya da başka belgesi (migration
// 0076). İçerik depoda (storage.Store); okuma masrafın okuma kuralıyla.
type ExpenseAttachment struct {
	ID           string
	ExpenseID    string
	OriginalName string
	MIMEType     string
	SizeBytes    int64
	SHA256       string
	UploadedBy   *string
	CreatedAt    time.Time
}

// ExpenseAttachmentsMax: bir masrafa en fazla bu kadar belge. Bir fişin
// birkaç sayfası ve faturası sığar; sınırsız yükleme telefonda yanlışlıkla
// seçilen bir galerinin tamamını masrafa bağlardı.
const ExpenseAttachmentsMax = 10

// ExpenseAttachmentMIMETypes: kabul edilen içerik türleri (içerikten tespit
// edilir, istemcinin beyanına bakılmaz). Telefon kamerası/galerisi JPEG
// gönderir (uygulama HEIC'i JPEG'e çevirir); HEIC/HEIF yine de kabul edilir
// ki başka bir istemcinin doğrudan yüklediği iPhone fotoğrafı reddedilmesin.
var ExpenseAttachmentMIMETypes = map[string]bool{
	"image/jpeg":      true,
	"image/png":       true,
	"image/webp":      true,
	"image/heic":      true,
	"image/heif":      true,
	"application/pdf": true,
}

// ExpenseApproverRecentDays: finans okuma izni olmayan onaylayıcı "Masraflar"
// listesinde onay bekleyenlerin yanında son bu kadar günde karara bağlanmış
// masrafları da görür (kendi verdiği/arkadaşının verdiği kararı izleyebilsin);
// daha eskisi finans okuma ister.
const ExpenseApproverRecentDays = 30

// MyExpense: "Masraflarım" satırı (GET /expenses/mine) -- kişinin kendi
// masrafı ve hangi projeye girildiği. Proje durumu, istemcinin kapalı
// projede Düzenle/Geri çek göstermemesi içindir (sunucu yine reddeder).
type MyExpense struct {
	Expense
	// Genel (projesiz) masrafta (migration 0068) proje alanları boştur.
	ProjectName   string
	ProjectNo     string
	ProjectStatus string
	// CreatedByName: "Masraflar" listesinde (GET /expenses) masrafı giren.
	CreatedByName string
}

// IsGeneral: projeye bağlı olmayan (firma genel gideri) masraf.
func (e Expense) IsGeneral() bool { return e.ProjectID == "" }

// ExpensesListLimit: "Masraflar" ekranı (GET /expenses) en fazla bu kadar
// satır döner; toplamlar bu satırlardan hesaplanır (limit dolduysa yanıt
// "truncated" der).
const ExpensesListLimit = 500

// MyExpensesLimit: "Masraflarım" en yeni bu kadar girişi döner -- kişinin
// takip ettiği şey son girdikleridir; eski, kapanmış kayıtlar Finans'ta.
const MyExpensesLimit = 200

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
	ID             string
	OrganizationID string
	ProjectID      string
	// SupplierID: bağlı olduğu Taşeronlar kartı (migration 0069).
	SupplierID      *string
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

// Basit taşeron ödemesinin türü (migration 0073): iş karşılığı ödeme
// gerçekleşen maliyettir; avans "İşe say" ile maliyete geçene kadar değildir.
const (
	SubcontractorPaymentKindWork    = "work"
	SubcontractorPaymentKindAdvance = "advance"
)

type SubcontractorPayment struct {
	ID              string
	OrganizationID  string
	ProjectID       string
	SubcontractorID string
	Amount          float64
	Currency        string
	PaidDate        time.Time
	Description     string
	PaymentKind     string
	// OffsetAt: avans işe sayıldıysa ne zaman (PaymentKind artık "work").
	OffsetAt   *time.Time
	CreatedBy  *string
	CreatedAt  time.Time
	VoidedAt   *time.Time
	VoidedBy   *string
	VoidReason string
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
	// SubcontractorPaid basit taşerona ödenen her şeydir (nakit; avans
	// dahil). Maliyete yalnızca İŞ ödemesi girer; avans "İşe say" ile
	// maliyete geçene kadar SubcontractorAdvanceOpen'da bekler.
	SubcontractorPaid        float64
	SubcontractorWorkPaid    float64
	SubcontractorAdvanceOpen float64
	SubcontractorRemaining   float64
	// Sprint 5 follow-up: legacy taşeron ödemelerinin (yukarıda) AYRI,
	// paralel kaynağı -- yeni "project_subcontracts" (Sprint 5) sözleşmelerine
	// yapılan GERÇEK ödemeler (bkz. migration 0039). Fiziksel olarak farklı
	// tablolara bağlı oldukları için RealizedCost/CommittedCost'a SAF TOPLAMA
	// ile katılırlar, çift sayım riski yoktur (bkz. docs/subcontracts.md).
	NewSubcontractPaid      float64
	NewSubcontractRemaining float64
	// Sözleşmeli taşeron, tahakkuk esaslı (project_cost_basis, migration
	// 0073): Accrued gerçekleşen iş (onaylı hakedişin brüt tutarı; ödenmemiş
	// ve teminatta tutulan dahil), AdvanceOpen mahsup edilmemiş avans,
	// Payable onaylı hakedişten henüz ödenmeyen net tutar, Retention onaylı
	// hakedişlerden kesilen teminat, PendingClaims onaya sunulmuş hakedişler.
	NewSubcontractAccrued       float64
	NewSubcontractAdvanceOpen   float64
	NewSubcontractPayable       float64
	NewSubcontractRetention     float64
	NewSubcontractPendingClaims float64
	// PendingExpenses: onay bekleyen masraflar (maliyete girmez, ayrıca gösterilir).
	PendingExpenses    float64
	IssuedInvoiceTotal float64
	PaidInvoiceTotal   float64
	// RealizedCost: masraflar + onaylı satın almalar + basit taşeronun iş
	// ödemeleri + sözleşmeli taşeronun gerçekleşen işi
	// (docs/maliyet-tanimlari.md). TotalExpenses BÜTÜN onaylı masraflardır
	// (nakit); maliyetin masraf satırı ExpenseCost'tur -- satın almaya ait
	// faturalar (siparişe bağlı masraflar) PurchaseCost'un içindedir.
	RealizedCost float64
	// Gerçekleşen maliyetin kırılımı (migration 0078):
	//   RealizedCost = ExpenseCost + PurchaseCost + SubcontractorWorkPaid + NewSubcontractAccrued
	// PurchaseCost "Satın almalar (onaylı)": onaylı talebin tahmini, onaylı
	// siparişin tutarı ya da (aşarsa) bağlı faturaları; PurchaseCostVAT
	// bunun içindeki bilinen KDV (sipariş KDV'si; talep tahmininin KDV'si
	// bilinmez). PurchaseCostUncoded maliyet koduna bağlı olmayan satın
	// alma (Maliyet Kontrolü'nün göremediği -- bütçe bazlı tahmine ayrıca
	// eklenir). PurchaseExcluded "maliyete eklenmesin" denmiş satın almalar
	// (bilgi; maliyete girmez).
	ExpenseCost         float64
	PurchaseCost        float64
	PurchaseCostVAT     float64
	PurchaseCostUncoded float64
	PurchaseExcluded    float64
	// RealizedCostVAT: gerçekleşen maliyetin içindeki bilinen KDV (masraf
	// satırı + satın almalar); *CostNet bundan türetilir.
	RealizedCostVAT float64
	// PaidCost: onaylı masraflar + bütün taşeron ödemeleri (nakit, avans dahil).
	PaidCost float64
	// AdvanceOpen: mahsup edilmemiş taşeron avansları (maliyet değil).
	AdvanceOpen float64
	// PendingCost: onay bekleyen masraflar + onaya sunulmuş hakedişler.
	PendingCost float64
	// ReceivedNotCosted: maliyete eklenen siparişlerde teslim alınmış
	// (kabul edilmiş) ama siparişe bağlı onaylı faturası girilmemiş tutar,
	// KDV dahil. Migration 0078'den beri sipariş tutarıyla maliyetin
	// İÇİNDEDİR; "faturası bekleniyor" bilgisi olarak ayrıca gösterilir.
	ReceivedNotCosted float64
	// CommittedCost: gerçekleşen + taşeron sözleşmelerinin (legacy+yeni) kalan taahhüdü.
	CommittedCost          float64
	RealizedGrossProfit    float64
	EstimatedGrossProfit   float64
	RealizedMarginPercent  float64
	EstimatedMarginPercent float64

	// KDV: yukarıdaki bedel, maliyet ve kârlar KDV DAHİLDİR (sözleşme bedeli
	// teklifin KDV dahil genel toplamı; maliyetler girildiği gibi). Ürün
	// sahibi kararı (2026-10-06): KDV hariç kâr da gösterilir.
	//
	// Maliyetlerin KDV hariç karşılığı (2026-10-07): ExpenseVATTotal, onaylı
	// ve iptal edilmemiş masrafların içindeki KDV'dir (KDV'si belirtilmemiş
	// masraf tutarının tamamıyla maliyettir). Migration 0078'den beri
	// *CostNet = maliyet - RealizedCostVAT (gerçekleşen maliyetin içindeki
	// KDV: masraf satırı + satın almalar; satın almanın içindeki fatura
	// sipariş KDV'siyle bir kez sayılır). Taşeron ödemeleri KDV bilgisi
	// taşımaz, oldukları gibi kalır.
	//
	// ContractVATKnown=false ise proje tekliften açılmamıştır, sözleşmenin
	// KDV'si bilinmez: KDV hariç kâr hesaplanamaz ve kâr/marj "net" alanları
	// KDV dahil değerlerle aynıdır (web bu durumda forecast_profit_net'i
	// "Tahmini Kâr" diye gösterir). *CostNet alanları yine gerçek KDV hariç
	// maliyettir.
	ContractVATAmount         float64
	ContractVATKnown          bool
	CurrentContractValueNet   float64
	ExpenseVATTotal           float64
	RealizedCostNet           float64
	CommittedCostNet          float64
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
	ForecastCostNet          float64
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

// ---------- KDV hariç bedel / maliyet / kâr -- TEK kural ----------
//
// Ürün sahibi kararları (2026-10-06/07, finans özeti): bedeller (sözleşme,
// ek iş) KDV DAHİL tutulur ve içlerindeki KDV ayrıca bilinir; masraf tutarı
// ödenen (KDV dahil) tutardır, oranı girilmişse içindeki KDV (vat_amount)
// bilinir. Kâr ya da gerçekleşen maliyet hesaplayan HER yüzey -- finans
// özeti, proje listesi, Maliyet Kontrolü, ek iş kârlılığı, ana sayfa --
// KDV hariç karşılığı bu yardımcılarla türetir; KDV dahil (brüt) alanlar
// olduğu gibi kalır. SQL tarafındaki tek girdi "onaylı, iptal edilmemiş
// masrafların içindeki KDV"dir: sum(vat_amount), oranı belirtilmemiş
// masrafta NULL olduğundan sayılmaz (tutarın tamamı maliyettir). Taşeron
// ödemeleri KDV bilgisi taşımaz, olduğu gibi maliyettir.

// VATBasis: KDV dahil bir bedel (Value) ve içindeki KDV (VAT). Known=false
// ise bedelin KDV'si bilinmiyor (proje tekliften açılmamış): KDV hariç kâr
// hesaplanamaz, kâr "net"i KDV dahil maliyetle hesaplanır -- KDV dahil
// bedelden KDV hariç maliyet çıkarmak kârı şişirirdi.
type VATBasis struct {
	Value float64
	VAT   float64
	Known bool
}

// Net: KDV hariç bedel.
func (b VATBasis) Net() float64 { return roundKurus(b.Value - b.VAT) }

// ProfitNet: KDV hariç kâr = KDV hariç bedel - KDV hariç maliyet (costNet,
// costGross'un KDV hariç karşılığıdır; bkz. CostNet). Bedelin KDV'si
// bilinmiyorsa costGross kullanılır (bkz. VATBasis).
func (b VATBasis) ProfitNet(costGross, costNet float64) float64 {
	cost := costNet
	if !b.Known {
		cost = costGross
	}
	return roundKurus(b.Net() - cost)
}

// CostNet: KDV hariç maliyet = maliyet - içindeki masraf KDV'si.
func CostNet(cost, expenseVAT float64) float64 { return roundKurus(cost - expenseVAT) }

// RoundKurus, kuruşa yuvarlar. Go'da toplanan tutarlar (ör. proje
// listesinin gerçekleşen maliyeti) bununla SQL numeric toplamının
// float64 karşılığıyla BİREBİR aynı olur.
func RoundKurus(v float64) float64 { return roundKurus(v) }

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
