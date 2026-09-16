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
	IBANEncSet     bool
	IsActive       bool
	Notes          string
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

// ---------- Organizasyon olayları (organization_events -- Sprint 2'nin
// mevcut altyapısı, YENİ tablo YOK, bkz. cost_code_service.go logOrgEvent) ----------

const (
	OrgEventSupplierCreated     = "supplier_created"
	OrgEventSupplierUpdated     = "supplier_updated"
	OrgEventSupplierArchived    = "supplier_archived"
	OrgEventSupplierReactivated = "supplier_reactivated"
)
