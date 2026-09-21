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
	AuditActionOrganizationCancelled    = "organization_cancelled"
	AuditActionCalcCatalogReprovisioned = "calc_catalog_reprovisioned"
	// Süper Admin'in firma kullanıcıları üzerindeki işlemleri -- hepsi
	// target_user_id ile yazılır; hiçbir şifre/geçici şifre metadata'ya girmez.
	AuditActionUserProvisioned      = "user_provisioned"
	AuditActionUserDeactivated      = "user_deactivated"
	AuditActionUserReactivated      = "user_reactivated"
	AuditActionUserRoleChanged      = "user_role_changed"
	AuditActionUserPasswordReset    = "user_password_reset"
	AuditActionUserDeleted          = "user_deleted"
	AuditActionUserRestored         = "user_restored"
	AuditActionOrganizationDeleted  = "organization_deleted"
	AuditActionOrganizationRestored = "organization_restored"
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
