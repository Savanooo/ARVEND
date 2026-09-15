package service

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// AuthorizationService, ARVEND V2 RBAC + Project Membership sprint'inin
// MERKEZİ yetkilendirme katmanıdır -- "handler'lara dağınık kod yazma"
// kısıtının somutlaşmasıdır (spec §7). super_admin BU SERVİSE HİÇ
// uğramaz: platform rolü tamamen ayrı bir eksendir (middleware.RoleFrom
// Context kontrolüyle daha önce muaf tutulur, tıpkı RequireOnboarded'daki
// AYNI desen).
type AuthorizationService struct {
	q *sqlc.Queries
}

func NewAuthorizationService(q *sqlc.Queries) *AuthorizationService {
	return &AuthorizationService{q: q}
}

// AuthzContext, TEK bir istek boyunca yeniden kullanılan, önceden
// yüklenmiş yetkilendirme anlık görüntüsüdür -- middleware.LoadAuthorization
// bunu İSTEK BAŞINA BİR KEZ hesaplar (2 sorgu: rol kodu + izin listesi) ve
// request context'ine koyar; sonraki RequirePermission/RequireProjectPermission
// çağrıları ONU okur, TEKRAR sorgu ATMAZ (spec §12: "aşırı sorgu YOK").
type AuthzContext struct {
	UserID         string
	OrganizationID string
	RoleCode       string // organization_roles.code -- owner/admin/legacy_user/project_manager/finance/field
	RoleName       string
	Permissions    map[string]bool
}

func (a *AuthzContext) HasPermission(code string) bool {
	if a == nil {
		return false
	}
	return a.Permissions[code]
}

// BypassesProjectMembership, bu kullanıcının proje-üyeliği kontrolünden
// MUAF olup olmadığını söyler (owner/admin/legacy_user -- bkz.
// domain.RoleBypassesProjectMembership).
func (a *AuthzContext) BypassesProjectMembership() bool {
	if a == nil {
		return false
	}
	return domain.RoleBypassesProjectMembership(a.RoleCode)
}

// LoadAuthzContext, kullanıcının rol kodunu VE tüm izin kodlarını İKİ
// hafif, indeksli sorguda yükler. Yalnızca organization_id'si dolu
// (super_admin OLMAYAN) kullanıcılar için çağrılmalıdır.
func (s *AuthorizationService) LoadAuthzContext(ctx context.Context, userID, organizationID string) (*AuthzContext, error) {
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	role, err := s.q.GetUserRoleCode(ctx, sqlc.GetUserRoleCodeParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// organization_role_id NULL/geçersiz -- ör. henüz backfill
			// edilmemiş bir kayıt. Deny-by-default: boş yetki kümesi.
			return &AuthzContext{UserID: userID, OrganizationID: organizationID, Permissions: map[string]bool{}}, nil
		}
		return nil, err
	}

	rows, err := s.q.GetUserPermissions(ctx, sqlc.GetUserPermissionsParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	perms := make(map[string]bool, len(rows))
	for _, code := range rows {
		perms[code] = true
	}
	return &AuthzContext{
		UserID: userID, OrganizationID: organizationID,
		RoleCode: role.Code, RoleName: role.Name, Permissions: perms,
	}, nil
}

// CanAccessProject, kullanıcının BU projeye erişip erişemeyeceğini söyler.
// owner/admin/legacy_user rolleri proje üyeliğinden BAĞIMSIZ olarak HER
// ZAMAN true döner (bkz. domain.RoleBypassesProjectMembership); diğer
// roller (project_manager/finance/field) yalnızca project_users'ta üye
// iseler erişebilir -- TEK bir EXISTS sorgusu (tam satır çekmez).
func (s *AuthorizationService) CanAccessProject(ctx context.Context, authz *AuthzContext, projectID string) (bool, error) {
	if authz.BypassesProjectMembership() {
		return true, nil
	}
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return false, domain.ErrNotFound
	}
	uid, err := repository.StringToUUID(authz.UserID)
	if err != nil {
		return false, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(authz.OrganizationID)
	if err != nil {
		return false, domain.ErrNotFound
	}
	return s.q.ProjectUserExists(ctx, sqlc.ProjectUserExistsParams{ProjectID: pid, UserID: uid, OrganizationID: orgID})
}

// ---------- Rol / İzin yönetimi (Roller & Yetkiler ekranı) ----------

func (s *AuthorizationService) ListPermissions(ctx context.Context) ([]domain.Permission, error) {
	rows, err := s.q.ListPermissions(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]domain.Permission, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainPermission(r)
	}
	return out, nil
}

// ListOrganizationRoles, İSTENİRSE (includeLegacy=false) legacy_user
// satırını dışarıda bırakır -- web rol seçicisi/yönetim ekranı bunu HER
// ZAMAN false ile çağırmalıdır (spec: legacy_user yeni atama hedefi
// değil, yalnızca migration artığı).
func (s *AuthorizationService) ListOrganizationRoles(ctx context.Context, organizationID string, includeLegacy bool) ([]domain.OrganizationRole, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListOrganizationRoles(ctx, orgID)
	if err != nil {
		return nil, err
	}
	out := make([]domain.OrganizationRole, 0, len(rows))
	for _, r := range rows {
		if !includeLegacy && r.Code == domain.OrgRoleLegacyUser {
			continue
		}
		dr := repository.ToDomainOrganizationRole(r)
		perms, err := s.q.ListPermissionsForRole(ctx, r.ID)
		if err != nil {
			return nil, err
		}
		dr.Permissions = perms
		out = append(out, dr)
	}
	return out, nil
}

func (s *AuthorizationService) GetOrganizationRole(ctx context.Context, roleID, organizationID string) (*domain.OrganizationRole, error) {
	rid, err := repository.StringToUUID(roleID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetOrganizationRoleByID(ctx, sqlc.GetOrganizationRoleByIDParams{ID: rid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	dr := repository.ToDomainOrganizationRole(row)
	perms, err := s.q.ListPermissionsForRole(ctx, row.ID)
	if err != nil {
		return nil, err
	}
	dr.Permissions = perms
	return &dr, nil
}

// SetRolePermissions, bir rolün izin kümesini TAMAMEN yeni listeyle
// değiştirir (offer/change-order kalemlerinin "sil+yeniden yaz" deseniyle
// AYNI ilke). is_system rollerin İZİNLERİ değiştirilebilir (bu ekranın
// asıl amacı budur) ama role_permissions dışında rol satırının KENDİSİ
// (code/is_system) DEĞİŞMEZ. Tanımsız (registry'de olmayan) bir izin kodu
// verilirse DB'nin role_permissions.permission_code FK kısıtı zaten
// reddeder -- burada AYRICA erken/net bir hata için ön-doğrulama yapılır
// (deny-by-default, spec §9).
func (s *AuthorizationService) SetRolePermissions(ctx context.Context, roleID, organizationID string, permissionCodes []string) (*domain.OrganizationRole, error) {
	rid, err := repository.StringToUUID(roleID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	role, err := s.q.GetOrganizationRoleByID(ctx, sqlc.GetOrganizationRoleByIDParams{ID: rid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}

	all, err := s.q.ListPermissions(ctx)
	if err != nil {
		return nil, err
	}
	valid := make(map[string]bool, len(all))
	for _, p := range all {
		valid[p.Code] = true
	}
	clean := make([]string, 0, len(permissionCodes))
	seen := map[string]bool{}
	for _, code := range permissionCodes {
		code = strings.TrimSpace(code)
		if code == "" || seen[code] {
			continue
		}
		if !valid[code] {
			return nil, domain.ErrUnknownPermission
		}
		seen[code] = true
		clean = append(clean, code)
	}

	if err := s.q.ClearRolePermissions(ctx, rid); err != nil {
		return nil, err
	}
	for _, code := range clean {
		if err := s.q.AddRolePermission(ctx, sqlc.AddRolePermissionParams{OrganizationRoleID: rid, PermissionCode: code}); err != nil {
			return nil, err
		}
	}

	dr := repository.ToDomainOrganizationRole(role)
	dr.Permissions = clean
	return &dr, nil
}

// ---------- Kullanıcı organizasyon rolü ----------

// SetUserOrganizationRole, bir kullanıcının organizasyon rolünü değiştirir.
// super_admin'e ASLA çağrılmaz (users_super_admin_has_no_org_role CHECK
// kısıtı DB seviyesinde zaten engeller); roleCode'un normal-admin
// tarafından 'super_admin' OLAMAYACAĞI zaten garanti edilir çünkü
// organization_roles hiçbir zaman 'super_admin' kodlu bir satır İÇERMEZ
// (yalnızca migration'da seed edilen 6 kod var, hepsi tenant rolü).
func (s *AuthorizationService) SetUserOrganizationRole(ctx context.Context, userID, organizationID, roleCode string) (*domain.OrganizationRole, error) {
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	role, err := s.q.GetOrganizationRoleByCode(ctx, sqlc.GetOrganizationRoleByCodeParams{OrganizationID: orgID, Code: roleCode})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}

	// Son-owner koruması: mevcut rolü 'owner' olan TEK aktif kullanıcı,
	// başka bir role düşürülemez.
	current, err := s.q.GetUserRoleCode(ctx, sqlc.GetUserRoleCodeParams{ID: uid, OrganizationID: orgID})
	if err == nil && current.Code == domain.OrgRoleOwner && role.Code != domain.OrgRoleOwner {
		count, cerr := s.q.CountOwnersInOrganization(ctx, orgID)
		if cerr != nil {
			return nil, cerr
		}
		if count <= 1 {
			return nil, domain.ErrLastOwner
		}
	}

	if _, err := s.q.UpdateUserOrganizationRole(ctx, sqlc.UpdateUserOrganizationRoleParams{
		ID: uid, OrganizationID: orgID, OrganizationRoleID: role.ID,
	}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	dr := repository.ToDomainOrganizationRole(role)
	return &dr, nil
}

// ---------- Kullanıcı listesi (organizasyon rolüyle zenginleştirilmiş) ----------

// ListUsersWithRoles, "Kullanıcılar" ekranının genişletilmiş listesidir --
// UserService.List'in AYNI sayfalama sözleşmesini (page/limit) izler ama
// her satıra organizasyon rol kodu/adını da (N+1'siz, tek JOIN) ekler.
// UserService'in kendi CRUD metodları (Create/Update/Deactivate) BUNDAN
// ETKİLENMEZ/DEĞİŞMEZ -- yalnızca okuma ekranı bu zenginleştirilmiş
// sorguya geçirilir.
func (s *AuthorizationService) ListUsersWithRoles(ctx context.Context, organizationID string, page, limit int) ([]domain.User, int64, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, 0, domain.ErrNotFound
	}
	if page < 1 {
		page = 1
	}
	if limit < 1 || limit > 200 {
		limit = 50
	}
	rows, err := s.q.ListUsersWithOrganizationRole(ctx, sqlc.ListUsersWithOrganizationRoleParams{
		OrganizationID: orgID, Limit: int32(limit), Offset: int32((page - 1) * limit),
	})
	if err != nil {
		return nil, 0, err
	}
	total, err := s.q.CountUsers(ctx, orgID)
	if err != nil {
		return nil, 0, err
	}
	out := make([]domain.User, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainUserWithRole(r)
	}
	return out, total, nil
}

func (s *AuthorizationService) GetUserWithRole(ctx context.Context, userID, organizationID string) (*domain.User, error) {
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetUserWithOrganizationRole(ctx, sqlc.GetUserWithOrganizationRoleParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	du := repository.ToDomainSingleUserWithRole(row)
	return &du, nil
}

// ---------- Proje Erişimi (project_users) ----------

type ProjectUserInput struct {
	UserID      string
	ProjectRole string
	CreatedBy   string
}

// AddProjectUser, bir kullanıcıyı projeye üye ekler. Kullanıcı VE proje
// AYNI organizasyona ait olmalıdır -- bu, DB'deki
// trg_project_users_check_org_consistency trigger'ının servis
// katmanındaki ERKEN tespitidir (kullanıcıya net bir hata için); trigger
// yine de son güvence olarak kalır (savunma derinliği).
func (s *AuthorizationService) AddProjectUser(ctx context.Context, projectID, organizationID string, in ProjectUserInput) (*domain.ProjectUser, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	uid, err := repository.StringToUUID(in.UserID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if !domain.ValidProjectRole(in.ProjectRole) {
		return nil, errors.New("geçersiz proje rolü")
	}
	target, err := s.q.GetUserByIDInOrg(ctx, sqlc.GetUserByIDInOrgParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrCrossOrgMembership
		}
		return nil, err
	}
	if target.Role == string(domain.RoleSuperAdmin) {
		return nil, domain.ErrCrossOrgMembership
	}
	if _, err := s.q.GetProjectByID(ctx, sqlc.GetProjectByIDParams{ID: pid, OrganizationID: orgID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}

	row, err := s.q.CreateProjectUser(ctx, sqlc.CreateProjectUserParams{
		OrganizationID: orgID, ProjectID: pid, UserID: uid,
		ProjectRole: in.ProjectRole, CreatedBy: actorUUID(in.CreatedBy),
	})
	if err != nil {
		return nil, err
	}
	dr := repository.ToDomainProjectUser(row)
	return &dr, nil
}

func (s *AuthorizationService) RemoveProjectUser(ctx context.Context, projectID, userID, organizationID string) error {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return domain.ErrNotFound
	}
	n, err := s.q.DeleteProjectUser(ctx, sqlc.DeleteProjectUserParams{ProjectID: pid, UserID: uid, OrganizationID: orgID})
	if err != nil {
		return err
	}
	if n == 0 {
		return domain.ErrNotFound
	}
	return nil
}

func (s *AuthorizationService) UpdateProjectUserRole(ctx context.Context, projectID, userID, organizationID, projectRole string) (*domain.ProjectUser, error) {
	if !domain.ValidProjectRole(projectRole) {
		return nil, errors.New("geçersiz proje rolü")
	}
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	createdBy, err := s.q.GetProjectUser(ctx, sqlc.GetProjectUserParams{ProjectID: pid, UserID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	row, err := s.q.CreateProjectUser(ctx, sqlc.CreateProjectUserParams{
		OrganizationID: orgID, ProjectID: pid, UserID: uid,
		ProjectRole: projectRole, CreatedBy: createdBy.CreatedBy,
	})
	if err != nil {
		return nil, err
	}
	dr := repository.ToDomainProjectUser(row)
	return &dr, nil
}

// ListUserProjects, "Kullanıcılar" ekranının kullanıcı detayındaki
// "Atandığı Projeler" listesidir -- owner/admin/legacy_user için de
// yalnızca project_users'taki GERÇEK satırları döner (bu roller
// erişimden MUAF olsa da, "hangi projelere açıkça üye" bilgisi ayrı bir
// sorudur; bkz. UI notu: bypass rolleri zaten tüm projeleri görür, bu
// liste yalnızca AÇIKÇA yapılmış üyelik atamalarını gösterir).
func (s *AuthorizationService) ListUserProjects(ctx context.Context, userID, organizationID string) ([]domain.UserProjectAssignment, error) {
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListProjectsForUserDetailed(ctx, sqlc.ListProjectsForUserDetailedParams{UserID: uid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.UserProjectAssignment, len(rows))
	for i, r := range rows {
		out[i] = domain.UserProjectAssignment{
			ProjectID: r.ProjectID.String(), ProjectNo: r.ProjectNo, ProjectName: r.ProjectName, ProjectRole: r.ProjectRole,
		}
	}
	return out, nil
}

func (s *AuthorizationService) ListProjectUsers(ctx context.Context, projectID, organizationID string) ([]domain.ProjectUser, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListProjectUsersDetailed(ctx, sqlc.ListProjectUsersDetailedParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.ProjectUser, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainProjectUserDetailed(r)
	}
	return out, nil
}
