package domain

import (
	"errors"
	"time"
)

// ---------- Organizasyon rol kodları ----------
//
// Bu kodlar migration 0034'te HER organizasyon için otomatik seed edilen 6
// sistem rolüne karşılık gelir. users.role (admin/kullanici/super_admin)
// İLE KARIŞTIRILMAMALI -- o eksen platform/tenant-admin ayrımını sürdürür,
// bu eksen ORGANIZATION İÇİ ince-taneli yetkilendirmedir (ek, ayrı bir
// sütun: users.organization_role_id).
const (
	OrgRoleOwner          = "owner"
	OrgRoleAdmin          = "admin"
	OrgRoleLegacyUser     = "legacy_user" // migration-only geriye uyumluluk rolü -- yeni kullanıcıya ATANMAZ, web rol seçicisinde gösterilmez.
	OrgRoleProjectManager = "project_manager"
	OrgRoleFinance        = "finance"
	OrgRoleField          = "field"
)

// bypassProjectMembershipRoles, bu rol kodlarına sahip kullanıcıların proje
// üyeliğinden BAĞIMSIZ olarak organizasyondaki TÜM projeleri görebildiği/
// erişebildiği merkezi kural kümesidir -- spec'in "OWNER/ADMIN tüm
// projeleri görür, PROJECT_MANAGER/FINANCE/FIELD yalnızca atandığı
// projeleri görür" şartının TEK kaynağı. legacy_user de burada: migration
// öncesi 'kullanici' rolü koşulsuz proje görünürlüğüne sahipti, bu davranış
// AYNEN korunur (backfill'de her legacy_user'a mevcut projelere üyelik de
// eklendi, ama bypass zaten bunu gereksiz kılıyor -- iki katman savunma).
var bypassProjectMembershipRoles = map[string]bool{
	OrgRoleOwner:      true,
	OrgRoleAdmin:      true,
	OrgRoleLegacyUser: true,
}

// RoleBypassesProjectMembership, verilen organizasyon rol koduna sahip bir
// kullanıcının proje üyeliği KONTROLÜNDEN MUAF olup olmadığını söyler.
func RoleBypassesProjectMembership(orgRoleCode string) bool {
	return bypassProjectMembershipRoles[orgRoleCode]
}

// TenantSelectableOrgRoles, web'de bir NORMAL admin'in kullanıcı rol
// seçicisinde göstermesi gereken kodların TAM listesidir -- legacy_user
// BİLİNÇLİ OLARAK dışarıda bırakılır (yeni atama hedefi değil, yalnızca
// migration artığı).
var TenantSelectableOrgRoles = []string{
	OrgRoleOwner, OrgRoleAdmin, OrgRoleProjectManager, OrgRoleFinance, OrgRoleField,
}

// ---------- Proje rol kodları (organizasyon rolünden TAMAMEN AYRI eksen) ----------

const (
	ProjectRoleManager = "project_manager"
	ProjectRoleMember  = "member"
	ProjectRoleViewer  = "viewer"
)

var validProjectRoles = map[string]bool{
	ProjectRoleManager: true, ProjectRoleMember: true, ProjectRoleViewer: true,
}

func ValidProjectRole(r string) bool { return validProjectRoles[r] }

// ---------- İzin kodları (canonical Go tanımlayıcıları) ----------
//
// Dış temsilleri (DB'de, JWT/me yanıtında) HER ZAMAN aşağıdaki lowercase
// string değerlerdir -- bu sabitler yalnızca Go kaynağında yazım hatasını
// derleme zamanında yakalamak içindir. Kayıt defter niteliğindedir: yeni
// bir izin eklerken hem burada hem migration'daki permissions seed'inde
// KARŞILIĞI olmalıdır (bkz. docs/authorization.md "yeni izin ekleme").
const (
	PermProjectsRead               = "projects.read"
	PermProjectsCreate             = "projects.create"
	PermProjectsUpdate             = "projects.update"
	PermProjectsFinanceRead        = "projects.finance.read"
	PermProjectsFinanceManage      = "projects.finance.manage"
	PermProjectsTasksRead          = "projects.tasks.read"
	PermProjectsTasksCreate        = "projects.tasks.create"
	PermProjectsTasksUpdate        = "projects.tasks.update"
	PermProjectsOperationsRead     = "projects.operations.read"
	PermProjectsOperationsManage   = "projects.operations.manage"
	PermProjectsAccessRead         = "projects.access.read"
	PermProjectsAccessManage       = "projects.access.manage"
	PermOffersRead                 = "offers.read"
	PermOffersCreate               = "offers.create"
	PermOffersUpdate               = "offers.update"
	PermOffersApprove              = "offers.approve"
	PermOffersDelete               = "offers.delete"
	PermCalculationsRead           = "calculations.read"
	PermCalculationsManage         = "calculations.manage"
	PermProductsRead               = "products.read"
	PermProductsManage             = "products.manage"
	PermCustomersRead              = "customers.read"
	PermCustomersManage            = "customers.manage"
	PermEmployeesRead              = "employees.read"
	PermEmployeesManage            = "employees.manage"
	PermAttendanceRead             = "attendance.read"
	PermAttendanceManage           = "attendance.manage"
	PermOrganizationUsersRead      = "organization.users.read"
	PermOrganizationUsersManage    = "organization.users.manage"
	PermOrganizationRolesRead      = "organization.roles.read"
	PermOrganizationRolesManage    = "organization.roles.manage"
	PermOrganizationSettingsRead   = "organization.settings.read"
	PermOrganizationSettingsManage = "organization.settings.manage"

	// Sprint 2 -- WBS + Cost Codes + Project Budget + Cost Control
	// (bkz. migration 0035 permissions seed'i, docs/cost-control.md).
	PermProjectsBudgetRead          = "projects.budget.read"
	PermProjectsBudgetManage        = "projects.budget.manage"
	PermProjectsCostControlRead     = "projects.cost_control.read"
	PermProjectsCostControlManage   = "projects.cost_control.manage"
	PermOrganizationCostCodesRead   = "organization.cost_codes.read"
	PermOrganizationCostCodesManage = "organization.cost_codes.manage"

	// Sprint 3 -- Proje Sözleşmesi (Contract, gelir/revenue tarafı --
	// Sprint 2'nin budget/cost_control'ünden [maliyet tarafı] AYRI).
	// Sprint 2'nin read/manage ikilisinden FARKLI olarak ÜÇ parçalı:
	// lifecycle (Activate/Cancel/Complete/Terminate), manage'den (taslak
	// düzenleme) BİLİNÇLİ OLARAK AYRI bir izindir (bkz. migration 0036
	// rol matrisi gerekçesi -- Project Manager manage alır ama lifecycle
	// almaz).
	PermProjectsContractsRead      = "projects.contracts.read"
	PermProjectsContractsManage    = "projects.contracts.manage"
	PermProjectsContractsLifecycle = "projects.contracts.lifecycle"

	// Sprint 4 -- Procurement Foundation (Suppliers, Purchase Request,
	// RFQ, Supplier Quotations, Purchase Order). suppliers.* organizasyon-
	// seviyelidir (organization_cost_codes İLE AYNI kardinalite). procurement.*
	// proje-seviyelidir ve Contract'ın read/manage/lifecycle üçlüsünden
	// ESİNLENEREK üç parçaya ayrılır, ama "approve" fiiliyle (bkz. migration
	// 0037 rol matrisi gerekçesi -- "lifecycle" tüm gelecekteki üçüncü
	// fiiller için evrensel bir isim DEĞİLDİR): approve, PR onayı/reddi, RFQ
	// award'ı, PO onayı/iptali/kapatmayı kapsar; manage'den BİLİNÇLİ OLARAK
	// AYRIDIR (Project Manager manage alır ama approve almaz -- Contract'taki
	// AYNI desen).
	PermOrganizationSuppliersRead   = "organization.suppliers.read"
	PermOrganizationSuppliersManage = "organization.suppliers.manage"
	PermProjectsProcurementRead     = "projects.procurement.read"
	PermProjectsProcurementManage   = "projects.procurement.manage"
	PermProjectsProcurementApprove  = "projects.procurement.approve"

	// Sprint 5 -- Taşeron Yönetimi (Subcontractor Management)
	PermProjectsSubcontractsRead         = "projects.subcontracts.read"
	PermProjectsSubcontractsManage       = "projects.subcontracts.manage"
	PermProjectsSubcontractsApprove      = "projects.subcontracts.approve"
	PermProjectsSubcontractClaimsRead    = "projects.subcontract_claims.read"
	PermProjectsSubcontractClaimsManage  = "projects.subcontract_claims.manage"
	PermProjectsSubcontractClaimsCertify = "projects.subcontract_claims.certify"
)

// ---------- Domain tipleri ----------

type Permission struct {
	Code        string
	Description string
	Category    string
}

type OrganizationRole struct {
	ID             string
	OrganizationID string
	Code           string
	Name           string
	Description    string
	IsSystem       bool
	Permissions    []string // yalnızca ilgili servis metodu doldurursa dolu olur (ör. rol detayı) -- liste uçlarında boş kalır.
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

// ProjectUser, project_users satırının domain karşılığıdır -- project_id/
// user_id çiftine bağlı ERİŞİM kaydı (bkz. migration 0034 başlık notu:
// mevcut project_members -- İK/puantaj roster'ı -- İLE KARIŞTIRILMAMALI).
type ProjectUser struct {
	ID             string
	OrganizationID string
	ProjectID      string
	UserID         string
	ProjectRole    string
	CreatedAt      time.Time
	// Aşağıdaki alanlar YALNIZCA ListProjectUsersDetailed'dan gelir (ekip
	// listesi ekranı için) -- GetProjectUser gibi tekil sorgularda boştur.
	Username             string
	FullName             string
	UserIsActive         bool
	OrganizationRole     string
	OrganizationRoleName string
}

// UserProjectAssignment, "Kullanıcılar" ekranının kullanıcı detayındaki
// "Atandığı Projeler" listesinin tek bir satırıdır.
type UserProjectAssignment struct {
	ProjectID   string
	ProjectNo   string
	ProjectName string
	ProjectRole string
}

// ---------- Hatalar ----------

var (
	// ErrPermissionDenied, kullanıcının org rolü gerekli izne sahip
	// DEĞİLSE döner -- middleware bunu 403 + "permission_denied" koduna
	// çevirir.
	ErrPermissionDenied = errors.New("bu işlem için yetkiniz yok")
	// ErrProjectAccessDenied, kullanıcı gerekli izne sahip ama BU PROJEYE
	// üye DEĞİLSE döner (owner/admin/legacy_user için asla üretilmez,
	// bkz. RoleBypassesProjectMembership) -- middleware 403 +
	// "project_access_denied" koduna çevirir.
	ErrProjectAccessDenied = errors.New("bu projeye erişim yetkiniz yok")
	// ErrCannotAssignSuperAdmin, normal bir admin'in bir kullanıcıyı
	// super_admin'e YÜKSELTMEYE çalıştığı her durumda döner -- users.role
	// alanı bu API'lerden HİÇ değiştirilemez (super_admin yalnızca
	// platform CLI/seed ile oluşturulur).
	ErrCannotAssignSuperAdmin = errors.New("normal kullanıcılar super admin olarak atanamaz")
	// ErrLastOwner, organizasyonun TEK aktif Owner'ını kaldırma/düşürme/
	// deaktive etme girişiminde döner.
	ErrLastOwner = errors.New("organizasyonun son sahibi (owner) kaldırılamaz veya rolü düşürülemez")
	// ErrCrossOrgMembership, bir kullanıcıyı/projeyi FARKLI bir
	// organizasyonun project_users kaydına bağlama girişiminde döner --
	// DB'deki trg_project_users_check_org_consistency ile AYNI kuralın
	// servis katmanındaki erken tespitidir (kullanıcıya daha net bir hata
	// mesajı vermek için).
	ErrCrossOrgMembership = errors.New("kullanıcı ve proje aynı organizasyona ait olmalı")
	// ErrUnknownPermission, kayıt defterinde OLMAYAN bir izin kodu
	// istenirse döner -- "tanımsız izin = erişim yok" (deny-by-default,
	// spec §9) ilkesinin somutlaşmasıdır.
	ErrUnknownPermission = errors.New("tanımsız izin kodu")
)
