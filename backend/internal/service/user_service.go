package service

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

type UserService struct {
	q *sqlc.Queries
}

func NewUserService(q *sqlc.Queries) *UserService {
	return &UserService{q: q}
}

type ListResult struct {
	Users []domain.User
	Total int64
}

func (s *UserService) List(ctx context.Context, organizationID string, page, limit int) (*ListResult, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	if page <= 0 {
		page = 1
	}
	rows, err := s.q.ListUsers(ctx, sqlc.ListUsersParams{
		OrganizationID: orgID,
		Limit:          int32(limit),
		Offset:         int32((page - 1) * limit),
	})
	if err != nil {
		return nil, err
	}
	total, err := s.q.CountUsers(ctx, orgID)
	if err != nil {
		return nil, err
	}
	users := make([]domain.User, len(rows))
	for i, r := range rows {
		users[i] = repository.ToDomainUser(r)
	}
	return &ListResult{Users: users, Total: total}, nil
}

func (s *UserService) Get(ctx context.Context, id, organizationID string) (*domain.User, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetUserByIDInOrg(ctx, sqlc.GetUserByIDInOrgParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	u := repository.ToDomainUser(row)
	return &u, nil
}

func (s *UserService) Create(ctx context.Context, organizationID, username, password, fullName string, role domain.Role) (*domain.User, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	username = strings.TrimSpace(username)
	if username == "" || password == "" || strings.TrimSpace(fullName) == "" {
		return nil, errors.New("kullanıcı adı, şifre ve ad soyad zorunludur")
	}
	if !role.Valid() {
		role = domain.RoleKullanici
	}
	hash, err := auth.HashPassword(password)
	if err != nil {
		return nil, err
	}
	row, err := s.q.CreateUser(ctx, sqlc.CreateUserParams{
		OrganizationID: orgID,
		Username:       username,
		PasswordHash:   hash,
		FullName:       strings.TrimSpace(fullName),
		Role:           string(role),
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" { // unique_violation
			return nil, domain.ErrDuplicateUsername
		}
		return nil, err
	}

	// RBAC/Project Membership sprint'i: YENİ kullanıcı organization_role_id
	// NULL bırakılırsa AuthorizationService.LoadAuthzContext deny-by-default
	// boş izin kümesi döner -- kullanıcı HİÇBİR business uca erişemez (bkz.
	// PlatformService.CreateOrganizationWithOwner'daki AYNI gerekçe).
	// Eski (role: admin/kullanici) sözleşmesiyle GERİYE DÖNÜK UYUMLU
	// varsayılan: admin -> 'admin' sistem rolü (tam yetki), kullanici ->
	// 'legacy_user' (migration backfill'iyle AYNI eşleme) -- bir admin
	// isterse PUT /users/{id}/organization-role ile SONRADAN inceltebilir
	// (project_manager/finance/field). En iyi çaba: rol satırı her zaman
	// seed edilmiş olmalıdır (migration backfill veya CreateOrganizationWithOwner
	// ile), ama bulunamazsa kullanıcı yine de OLUŞTURULUR -- yalnızca
	// organization_role_id boş kalır, sonradan atanabilir.
	orgRoleCode := domain.OrgRoleLegacyUser
	if role == domain.RoleAdmin {
		orgRoleCode = domain.OrgRoleAdmin
	}
	if orgRole, rerr := s.q.GetOrganizationRoleByCode(ctx, sqlc.GetOrganizationRoleByCodeParams{
		OrganizationID: orgID, Code: orgRoleCode,
	}); rerr == nil {
		if updated, uerr := s.q.UpdateUserOrganizationRole(ctx, sqlc.UpdateUserOrganizationRoleParams{
			ID: row.ID, OrganizationID: orgID, OrganizationRoleID: orgRole.ID,
		}); uerr == nil {
			row = updated
		}
	}

	u := repository.ToDomainUser(row)
	return &u, nil
}

// Update, kullanıcının profilini (ad soyad + aktiflik) değiştirir. Kaba
// users.role BİLEREK burada bir parametre DEĞİLDİR: "admin"/"kullanici"
// artık bağımsız düzenlenebilir bir kavram değil, organizasyon rolünden
// TÜRETİLEN bir alan (bkz. setUserOrganizationRole/coarseRoleForOrgRole) --
// bu uç onu bağımsız değiştirebilseydi, ikisi birbirinden sapar (requireAdmin
// kapısı ve /admin vs /panel kabuk seçimi organizasyon rolüyle tutarsız
// kalırdı) ve son-Sahip koruması organizasyon rolüne bakan guardLastActiveOwner
// tarafından bu sapmayı GÖREMEZDİ. Rol değişikliği yalnızca
// SetOrganizationRole ile yapılır (o hem senkronu hem son-Sahip korumasını
// uygular).
func (s *UserService) Update(ctx context.Context, id, organizationID, fullName string, isActive bool) (*domain.User, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if !isActive {
		if err := guardLastActiveOwner(ctx, s.q, uid, orgID); err != nil {
			return nil, err
		}
	} else {
		// Silinmiş bir kullanıcı bu yoldan doğrudan aktifleştirilemez --
		// önce restore edilmeli (bkz. user_lifecycle.go reactivateUser'daki
		// AYNI kural; bu, tenant tarafının reaktivasyon yoludur).
		current, cerr := s.q.GetUserByIDInOrg(ctx, sqlc.GetUserByIDInOrgParams{ID: uid, OrganizationID: orgID})
		if cerr != nil {
			if errors.Is(cerr, pgx.ErrNoRows) {
				return nil, domain.ErrNotFound
			}
			return nil, cerr
		}
		if current.DeletedAt.Valid {
			return nil, domain.ErrUserDeleted
		}
	}
	row, err := s.q.UpdateUserProfile(ctx, sqlc.UpdateUserProfileParams{
		ID:             uid,
		OrganizationID: orgID,
		FullName:       strings.TrimSpace(fullName),
		IsActive:       isActive,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if !isActive {
		if err := s.q.RevokeAllUserRefreshTokens(ctx, uid); err != nil {
			return nil, err
		}
	}
	u := repository.ToDomainUser(row)
	return &u, nil
}

// ChangeOwnPassword, kullanıcının kendi şifresini değiştirmesi için mevcut
// şifreyi doğrular (admin resetinden farkı budur).
func (s *UserService) ChangeOwnPassword(ctx context.Context, id, organizationID, currentPassword, newPassword string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	row, err := s.q.GetUserByID(ctx, uid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ErrNotFound
		}
		return err
	}
	if !auth.CheckPassword(row.PasswordHash, currentPassword) {
		return domain.ErrInvalidCredentials
	}
	return s.setPassword(ctx, uid, organizationID, newPassword)
}

// AdminResetPassword, mevcut şifre istemeden bir kullanıcının şifresini
// değiştirir — yalnız RequireRole("admin") arkasında çağrılmalıdır.
func (s *UserService) AdminResetPassword(ctx context.Context, id, organizationID, newPassword string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	return s.setPassword(ctx, uid, organizationID, newPassword)
}

// SetInitialPassword, Super Admin'in provision ettiği bir Owner'ın (veya
// başka bir must_change_password=true kullanıcının) ilk girişte YENİ bir
// şifre belirlemesi içindir -- ChangeOwnPassword'ün aksine mevcut şifreyi
// DOĞRULAMAZ (kullanıcı zaten geçici şifreyle kimlik doğrulamış durumda,
// bu uç yalnızca requireAuth arkasındadır). must_change_password bayrağını
// AYNI sorguda temizler (bkz. SetPasswordAndClearMustChange).
func (s *UserService) SetInitialPassword(ctx context.Context, id, organizationID, newPassword string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	if len(newPassword) < 8 {
		return errors.New("yeni şifre en az 8 karakter olmalı")
	}
	hash, err := auth.HashPassword(newPassword)
	if err != nil {
		return err
	}
	rows, err := s.q.SetPasswordAndClearMustChange(ctx, sqlc.SetPasswordAndClearMustChangeParams{
		ID: uid, OrganizationID: orgID, PasswordHash: hash,
	})
	if err != nil {
		return err
	}
	if rows == 0 {
		return domain.ErrNotFound
	}
	return nil
}

func (s *UserService) setPassword(ctx context.Context, uid pgtype.UUID, organizationID, newPassword string) error {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	if len(newPassword) < 8 {
		return errors.New("yeni şifre en az 8 karakter olmalı")
	}
	hash, err := auth.HashPassword(newPassword)
	if err != nil {
		return err
	}
	rows, err := s.q.UpdateUserPassword(ctx, sqlc.UpdateUserPasswordParams{ID: uid, OrganizationID: orgID, PasswordHash: hash})
	if err != nil {
		return err
	}
	if rows == 0 {
		return domain.ErrNotFound
	}
	return nil
}

// Deactivate, kullanıcıyı pasifleştirir -- satır silinmez, son aktif Owner
// korunur, açık oturumları iptal edilir (bkz. user_lifecycle.go).
func (s *UserService) Deactivate(ctx context.Context, id, organizationID string) error {
	_, err := deactivateUser(ctx, s.q, id, organizationID)
	return err
}
