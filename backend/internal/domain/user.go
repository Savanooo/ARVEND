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
	// OrganizationRoleCode/-Name, RBAC/Project Membership sprint'inin
	// ince-taneli organizasyon rolüdür (users.role'den TAMAMEN AYRI --
	// bkz. domain/authorization.go). YALNIZCA bunları JOIN'le dolduran
	// sorgularla (ör. AuthorizationService.ListUsersWithRoles) gelir;
	// temel UserService.List/Get/Create/Update boş bırakır.
	OrganizationRoleCode string
	OrganizationRoleName string
	// DeletedAt/DeletedBy, is_active'den TAMAMEN AYRI bir eksendir --
	// "normal listelerden kaldırıldı" (bkz. migration 0043 başlık notu).
	// Silinen bir kullanıcı HER ZAMAN is_active=false'dur da (deleteUser
	// ikisini birlikte yazar) ama tersi doğru değildir: pasif bir
	// kullanıcı silinmiş OLMAYABİLİR.
	DeletedAt *time.Time
	DeletedBy *string
	// LinkedEmployee*, hesabın bağlı olduğu personel kaydıdır ("kişi = tek
	// kayıt", bkz. service/user_employee_link.go). YALNIZCA bunu JOIN'le
	// dolduran sorgularla (AuthorizationService.ListUsersWithRoles/
	// GetUserWithRole) ve hesap açma yollarıyla gelir; nil = bağlı personel
	// yok (ya da sorgu doldurmadı).
	LinkedEmployeeID     *string
	LinkedEmployeeName   string
	LinkedEmployeeActive bool
}

func (u User) IsDeleted() bool { return u.DeletedAt != nil }
