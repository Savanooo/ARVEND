package domain

import "time"

// Plan, gerçek bir billing entegrasyonu (Stripe/Iyzico) OLMADAN limitleri
// saklayan minimal bir plan modelidir -- bu fazda limitler sadece
// GÖSTERİLİR, enforce EDİLMEZ (bkz. final rapor "Kapsam Dışı" bölümü).
type Plan struct {
	Code        string
	Name        string
	IsActive    bool
	MaxUsers    int
	MaxProjects int
	SortOrder   int
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

// Platform audit action'ları -- platform_audit_events.action kolonuna yazılır
// (bkz. migration 0033). Password/token/secret ASLA metadata'ya yazılmaz.
const (
	AuditActionOrganizationCreated      = "organization_created"
	AuditActionOrganizationSuspended    = "organization_suspended"
	AuditActionOrganizationActivated    = "organization_activated"
	AuditActionOrganizationPlanChanged  = "organization_plan_changed"
	AuditActionCalcCatalogReprovisioned = "calc_catalog_reprovisioned"
)

// AuditEvent, bir Super Admin'in bir organization veya user üzerinde yaptığı
// platform işleminin değişmez (immutable) denetim kaydıdır (bkz.
// platform_audit_events_prevent_mutation trigger'ı).
type AuditEvent struct {
	ID                   string
	ActorUserID          *string
	Action               string
	TargetOrganizationID *string
	TargetUserID         *string
	Metadata             map[string]any
	CreatedAt            time.Time
}
