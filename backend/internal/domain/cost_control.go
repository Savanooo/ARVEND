package domain

import "time"

// ARVEND V2 — Sprint 2: WBS + Cost Codes + Project Budget + Cost Control.
//
// ÖNEMLİ: bir proje bütçesi ASLA offer/contract_amount'tan otomatik
// TÜRETİLMEZ (bkz. docs/cost-control.md "Offer revenue neden otomatik
// cost budget değildir" -- denetim bulgusu: offers/calc zincirinde
// hiçbir noktada güvenilir bir maliyet alanı yoktur, yalnızca satış
// fiyatı taşınır). Yeni bir proje için bütçe her zaman boş bir draft
// olarak, kullanıcı tarafından elle oluşturulur.

// ---------- Durum sabitleri ----------

const (
	BudgetStatusDraft     = "draft"
	BudgetStatusBaselined = "baselined"
)

const (
	AdjustmentStatusDraft    = "draft"
	AdjustmentStatusApproved = "approved"
	AdjustmentStatusRejected = "rejected"
)

const (
	CommitmentStatusActive = "active"
	CommitmentStatusVoided = "voided"
)

const (
	CommitmentSourceManual        = "manual"
	CommitmentSourcePurchaseOrder = "purchase_order"
	CommitmentSourceSubcontract   = "subcontract"
)

func ValidBudgetStatus(s string) bool {
	return s == BudgetStatusDraft || s == BudgetStatusBaselined
}

func ValidAdjustmentDecision(s string) bool {
	return s == AdjustmentStatusApproved || s == AdjustmentStatusRejected
}

func ValidCommitmentSourceType(s string) bool {
	return s == CommitmentSourceManual || s == CommitmentSourcePurchaseOrder || s == CommitmentSourceSubcontract
}

// ---------- Proje olayları (project_events -- mevcut altyapı, YENİ tablo YOK) ----------

const (
	ProjectEventWBSCreated         = "wbs_created"
	ProjectEventWBSUpdated         = "wbs_updated"
	ProjectEventWBSArchived        = "wbs_archived"
	ProjectEventBudgetCreated      = "budget_created"
	ProjectEventBudgetBaselined    = "budget_baselined"
	ProjectEventBudgetLineCreated  = "budget_line_created"
	ProjectEventBudgetLineUpdated  = "budget_line_updated"
	ProjectEventBudgetLineDeleted  = "budget_line_deleted"
	ProjectEventAdjustmentCreated  = "budget_adjustment_created"
	ProjectEventAdjustmentApproved = "budget_adjustment_approved"
	ProjectEventAdjustmentRejected = "budget_adjustment_rejected"
	ProjectEventCommitmentCreated  = "commitment_created"
	ProjectEventCommitmentVoided   = "commitment_voided"
	ProjectEventForecastUpdated    = "forecast_updated"
)

// ---------- Organizasyon olayları (organization_events -- YENİ, proje-
// bağımsız denetim tablosu; bkz. migration 0035 §8b gerekçesi) ----------

const (
	OrgEventCostCodeCreated  = "cost_code_created"
	OrgEventCostCodeUpdated  = "cost_code_updated"
	OrgEventCostCodeArchived = "cost_code_archived"
)

// ---------- Domain tipleri ----------

// OrganizationEvent, organization_events satırının domain karşılığıdır --
// domain.ProjectEvent İLE AYNI şekil, yalnızca proje-bağımsız (kuruluş
// seviyeli) olaylar için (bkz. migration 0035 §8b, cost-code CRUD).
type OrganizationEvent struct {
	ID             string
	OrganizationID string
	EventType      string
	UserID         *string
	Metadata       map[string]any
	CreatedAt      time.Time
}

type OrganizationCostCode struct {
	ID             string
	OrganizationID string
	Code           string
	Name           string
	Description    string
	Category       string
	IsActive       bool
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

type WBSNode struct {
	ID             string
	OrganizationID string
	ProjectID      string
	ParentID       *string
	Code           string
	Name           string
	SortOrder      int
	IsActive       bool
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

type ProjectBudget struct {
	ID             string
	OrganizationID string
	ProjectID      string
	Currency       string
	Status         string
	Version        int
	CreatedBy      *string
	CreatedAt      time.Time
	UpdatedAt      time.Time
	BaselinedAt    *time.Time
	BaselinedBy    *string
}

// BudgetLine, tek bir bütçe kalemidir. Quantity/UnitCost her ikisi de
// doluysa OriginalAmount SERVİS KATMANINDA SQL numeric ile (quantity *
// unit_cost, round(...,2)) hesaplanır -- istemcinin gönderdiği tutara
// GÜVENİLMEZ (bkz. docs/cost-control.md). WBSCode/-Name/CostCodeCode/
// -Name, YALNIZCA "detailed" liste uçlarında (ListBudgetLinesDetailed)
// doldurulur.
type BudgetLine struct {
	ID             string
	OrganizationID string
	ProjectID      string
	BudgetID       string
	WBSNodeID      *string
	CostCodeID     string
	Description    string
	Quantity       *float64
	Unit           string
	UnitCost       *float64
	OriginalAmount float64
	Notes          string
	CreatedAt      time.Time
	UpdatedAt      time.Time

	WBSCode      string
	WBSName      string
	CostCodeCode string
	CostCodeName string
}

type BudgetAdjustment struct {
	ID             string
	OrganizationID string
	ProjectID      string
	BudgetID       string
	BudgetLineID   string
	Amount         float64
	Reason         string
	Status         string
	CreatedBy      *string
	ApprovedBy     *string
	ApprovedAt     *time.Time
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

// Commitment, project_commitments satırının domain karşılığıdır --
// SourceType='manual' bu sprintte TEK üretilen türdür; 'purchase_order'/
// 'subcontract' gelecekteki Procurement/Subcontract modülleri içindir
// (bkz. docs/cost-control.md).
type Commitment struct {
	ID              string
	OrganizationID  string
	ProjectID       string
	BudgetLineID    *string
	CostCodeID      string
	SourceType      string
	SourceID        *string
	Description     string
	CommittedAmount float64
	Currency        string
	Status          string
	CommittedAt     time.Time
	CreatedBy       *string
	VoidedAt        *time.Time
	VoidedBy        *string
	VoidReason      string
	CreatedAt       time.Time
	UpdatedAt       time.Time

	CostCodeCode string
	CostCodeName string
}

// CostForecast, bir bütçe kalemi için MANUEL ETC override'ıdır. Satır
// YOKSA, servis katmanı varsayılan ETC'yi GREATEST(revised_budget -
// actual_cost, 0) olarak hesaplar (bkz. docs/cost-control.md).
type CostForecast struct {
	ID             string
	OrganizationID string
	ProjectID      string
	BudgetLineID   string
	ETCAmount      float64
	Note           string
	UpdatedBy      *string
	UpdatedAt      time.Time
}

// CostControlLine, "Maliyet Kontrolü" ana tablosunun (WBS × Cost Code
// kırılımı) tek bir satırıdır. IsUnbudgeted=true ise bu satırın bir
// bütçe kalemi YOKTUR -- yalnızca o cost code'a doğrudan bağlanmış (bir
// bütçe kalemine bağlanmamış) taahhüt/gider vardır ("bütçe dışı harcama"
// -- OriginalAmount/RevisedBudget her zaman 0, Variance her zaman
// negatiftir).
type CostControlLine struct {
	BudgetLineID        *string
	WBSNodeID           *string
	WBSCode             string
	WBSName             string
	CostCodeID          string
	CostCodeCode        string
	CostCodeName        string
	Description         string
	OriginalAmount      float64
	ApprovedAdjustments float64
	RevisedBudget       float64
	CommittedCost       float64
	ActualCost          float64
	ETCAmount           float64
	EAC                 float64
	Variance            float64
	IsUnbudgeted        bool
}

// CostControlSummary, proje seviyesinde Maliyet Kontrolü özet KPI'larıdır.
// ContractValue, GetProjectFinancialSummary'deki current_contract_value
// İLE AYNI canlı formülle (contract_amount + approved_additions -
// approved_deductions) hesaplanır -- ayrı bir kopya DEĞİLDİR.
// ForecastProfit/-Margin, spec'in "Current Contract Value - EAC" ve
// "forecast_profit / contract_value * 100" formülleridir (sıfır/negatif
// contract_value'da marj güvenle 0 döner, bkz. GetProjectFinancialSummary
// İLE AYNI clamp deseni).
type CostControlSummary struct {
	Currency              string
	ContractValue         float64
	OriginalBudget        float64
	ApprovedAdjustments   float64
	RevisedBudget         float64
	CommittedCost         float64
	ActualCost            float64
	ETCTotal              float64
	EACTotal              float64
	Variance              float64
	ForecastProfit        float64
	ForecastMarginPercent float64
	// HasBudget, bu projenin HENÜZ bir bütçesi olup olmadığını belirtir --
	// "bütçesiz proje" geçerli bir durumdur (spec §42), false ise diğer
	// TÜM alanlar (ContractValue hariç) 0'dır.
	HasBudget bool
}
