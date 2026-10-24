package domain

import "time"

// Taşeron Paneli (migration 0075, docs/taseron-paneli.md).

// PortalUser: bir taşeron kartına açılmış giriş.
type PortalUser struct {
	ID                 string
	Username           string
	FullName           string
	IsActive           bool
	MustChangePassword bool
	LastLoginAt        *time.Time
	CreatedAt          time.Time
}

// PortalProjectChoice: firmanın izin ekranındaki proje satırı.
type PortalProjectChoice struct {
	ID            string
	ProjectNo     string
	Name          string
	Status        string
	Granted       bool
	HasEngagement bool
}

// PortalProject: taşerona izin verilmiş proje.
type PortalProject struct {
	ID        string
	ProjectNo string
	Name      string
	Status    string
}

// PortalEngagement: taşeronun izinli bir projedeki işi. Kind "simple"
// (basit taşeron) ya da "contract" (sözleşmeli taşeron). Certified yalnızca
// sözleşmelide doludur. Remaining = max(bedel - ödenen, 0).
type PortalEngagement struct {
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
	Certified      *float64
	Paid           float64
	Payable        float64
	Retention      float64
	AdvanceOpen    float64
	PendingClaims  float64
	Remaining      float64
}

// PortalPayment: taşerona yapılmış (iptal edilmemiş) ödeme. Source
// "simple" | "contract" | "direct" (proje dışı); Kind "work" | "advance" |
// "general".
type PortalPayment struct {
	Source      string
	ID          string
	ProjectID   *string
	ProjectName string
	ProjectNo   string
	Amount      float64
	Currency    string
	PaidDate    time.Time
	Description string
	Kind        string
}

// PortalTotals: para birimi başına toplamlar. Paid ödeme listesinin
// toplamıdır (proje dışı dahil); Remaining işlerin kalanlarının toplamı.
type PortalTotals struct {
	Currency       string
	ContractAmount float64
	Paid           float64
	Remaining      float64
	Payable        float64
	Retention      float64
}

// PortalOverview: taşeronun ana ekranı.
type PortalOverview struct {
	SupplierID   string
	SupplierName string
	Projects     []PortalProject
	Engagements  []PortalEngagement
	Payments     []PortalPayment
	Totals       []PortalTotals
}
