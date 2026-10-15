package domain

import "time"

// Supplier, organizasyon-seviyeli (proje-bağımsız) tedarikçi kataloğunu
// temsil eder -- organization_cost_codes İLE AYNI kardinalite (bkz.
// docs/procurement.md). Customer'dan KASITLI OLARAK AYRI bir tablodur:
// repo genelinde ortak bir Person/Company/Contact soyutlaması yoktur
// (customers ve project_subcontractors de birbirinden bağımsız, düz
// tablolardır) -- burada da böyle bir soyutlama İCAT EDİLMEDİ.
//
// IBANEncSet, gerçek IBAN'ın şifreli/kayıtlı olup olmadığını belirtir --
// plaintext ASLA bu struct'ın DIŞINA (HTTP yanıtına) taşınmaz
// (organization_commercial_settings.iban_enc İLE AYNI ilke).
type Supplier struct {
	ID             string
	OrganizationID string
	Code           string
	LegalName      string
	TradeName      string
	TaxNumber      string
	TaxOffice      string
	ContactName    string
	Email          string
	Phone          string
	Address        string
	City           string
	Country        string
	// Specialty, taşeron olarak kullanılabildiğinde branş/uzmanlık alanını
	// belirtir (ör. "Elektrik", "Sıhhi Tesisat") -- Sprint 5, spec §3/§4:
	// AYRI bir subcontractor master tablosu İCAT ETMEK yerine, mevcut
	// tedarikçi kaydı bu tek opsiyonel alanla genişletildi. Boş olabilir --
	// hiçbir supplier/subcontract kullanılabilirlik farkı YOKTUR, salt
	// bilgilendirici metadata.
	Specialty string
	// IsSubcontractor: "Taşeronlar" listesindeki kart (migration 0069).
	IsSubcontractor bool
	IBANEncSet      bool
	IsActive        bool
	Notes           string
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

// ---------- Organizasyon olayları (organization_events -- Sprint 2'nin
// mevcut altyapısı, YENİ tablo YOK, bkz. cost_code_service.go logOrgEvent) ----------

const (
	OrgEventSupplierCreated     = "supplier_created"
	OrgEventSupplierUpdated     = "supplier_updated"
	OrgEventSupplierArchived    = "supplier_archived"
	OrgEventSupplierReactivated = "supplier_reactivated"
)

// SubcontractorEngagement: taşeronun bir projedeki işi -- projedeki basit
// taşeron kaydı (Kind "simple") ya da sözleşmeli taşeronluk ("contract").
type SubcontractorEngagement struct {
	Kind           string
	ID             string
	ProjectID      string
	ProjectName    string
	ProjectNo      string
	ProjectStatus  string
	Title          string
	Status         string
	Currency       string
	ContractAmount float64
	PaidAmount     float64
}

// SubcontractorLedgerPayment: taşerona yapılan bir ödeme -- Source "simple"
// (projedeki basit taşeron ödemesi), "contract" (sözleşmeli taşeron
// ödemesi) ya da "direct" (proje dışı, migration 0069).
type SubcontractorLedgerPayment struct {
	Source       string
	ID           string
	ProjectID    string
	ProjectName  string
	ProjectNo    string
	EngagementID string
	Amount       float64
	Currency     string
	PaidDate     time.Time
	Description  string
	VoidedAt     *time.Time
	VoidReason   string
	// Kind: "work" | "advance" | "general" (proje dışı genel ödeme).
	Kind string
}

// SubcontractorCard: "Taşeronlar" listesinin satırı -- kart ve para
// birimi başına ödenen toplam (yalnızca finans okuyabilene doldurulur).
type SubcontractorCard struct {
	Supplier
	PaidTotals []MoneyAmount
	// RemainingTotals: para birimi başına kalan borç (yürürlükteki işlerin
	// bedeli eksi ödenen, iş başına sıfırın altına inmez).
	RemainingTotals []MoneyAmount
}

// SubcontractorSiteDay: taşeronun sahada çalıştığı bir gün (günlük şantiye
// raporundan, migration 0071).
type SubcontractorSiteDay struct {
	ReportDate  time.Time
	ProjectID   string
	ProjectName string
	ProjectNo   string
	Workers     int
	WorkNote    string
}
