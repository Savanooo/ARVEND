// Package domain, katmanlar arasında paylaşılan iş nesnelerini tanımlar.
// sqlc'nin ürettiği (pgtype ağırlıklı) modellerden bilerek ayrı tutulur ki
// veritabanı detayları (pgtype.UUID vb.) servis/handler katmanına sızmasın.
package domain

import "time"

type Role string

const (
	RoleAdmin      Role = "admin"
	RoleKullanici  Role = "kullanici"
	RoleSuperAdmin Role = "super_admin"
)

func (r Role) Valid() bool {
	return r == RoleAdmin || r == RoleKullanici || r == RoleSuperAdmin
}

// User.OrganizationID, RoleSuperAdmin için her zaman nil'dir -- Super Admin
// platform seviyesindedir, herhangi bir firmaya bağlı değildir (bkz.
// users_super_admin_has_no_org DB CHECK constraint'i, migration 0030).
// Diğer tüm roller için her zaman doludur.
type User struct {
	ID                 string
	OrganizationID     *string
	Username           string
	PasswordHash       string
	FullName           string
	Role               Role
	IsActive           bool
	MustChangePassword bool
	CreatedAt          time.Time
	UpdatedAt          time.Time
	LastLoginAt        *time.Time
}
