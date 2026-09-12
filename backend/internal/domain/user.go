// Package domain, katmanlar arasında paylaşılan iş nesnelerini tanımlar.
// sqlc'nin ürettiği (pgtype ağırlıklı) modellerden bilerek ayrı tutulur ki
// veritabanı detayları (pgtype.UUID vb.) servis/handler katmanına sızmasın.
package domain

import "time"

type Role string

const (
	RoleAdmin     Role = "admin"
	RoleKullanici Role = "kullanici"
)

func (r Role) Valid() bool {
	return r == RoleAdmin || r == RoleKullanici
}

type User struct {
	ID             string
	OrganizationID string
	Username       string
	PasswordHash   string
	FullName       string
	Role           Role
	IsActive       bool
	CreatedAt      time.Time
	UpdatedAt      time.Time
	LastLoginAt    *time.Time
}
