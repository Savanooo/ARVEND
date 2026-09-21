package service

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Kullanıcı yaşam döngüsü (pasifleştirme/aktifleştirme/organizasyon rolü)
// TEK yerde: hem tenant tarafı (UserService/AuthorizationService, kendi
// org bağlamıyla) hem platform tarafı (PlatformService, açık organizasyon
// kimliğiyle) AYNI kuralları bu paket-içi fonksiyonlardan alır -- "son
// aktif Owner" koruması iki ayrı yerde iki farklı biçimde yazılmaz.
// *sqlc.Queries alırlar ki bir transaction'ın (WithTx) içinde de
// çağrılabilsinler. Hiçbir fonksiyon satır SİLMEZ.

// coarseRoleForOrgRole, organizasyon rolünden kaba users.role'ü türetir:
// requireAdmin kapısı (/users, /settings, /organization/roles, /onboarding,
// /organization/settings) ve web kabuğu seçimi (/admin vs /panel) hâlâ bu
// alana bakar -- ikisi birbirinden koparsa Sahip yapılan bir kullanıcı
// kullanıcı yönetimine giremez.
func coarseRoleForOrgRole(code string) domain.Role {
	if code == domain.OrgRoleOwner || code == domain.OrgRoleAdmin {
		return domain.RoleAdmin
	}
	return domain.RoleKullanici
}

// isReservedUsername, kişiye ait olmayan genel hesap adlarını (yalnızca
// "admin") platform provisioning'inde reddetmek içindir. cmd/api'nin
// SEED_ADMIN_* ile boş DB'ye ilk kullanıcıyı ekleyen bootstrap yolu
// (UserService.Create) BİLİNÇLİ OLARAK bu kuralın dışındadır -- o yol
// production provisioning değildir.
func isReservedUsername(username string) bool {
	return strings.EqualFold(strings.TrimSpace(username), "admin")
}

// guardLastActiveOwner, hedef kullanıcı organizasyonun SON AKTİF Owner'ı ise
// domain.ErrLastOwner döner. Owner olmayan ya da zaten pasif bir hedef için
// kısıt yoktur (pasif bir Owner zaten sayılmaz; başka aktif Owner varsa
// düşürülebilir). Kullanıcı bu organizasyonda yoksa ErrNotFound.
func guardLastActiveOwner(ctx context.Context, q *sqlc.Queries, uid, orgID pgtype.UUID) error {
	role, err := q.GetUserRoleCode(ctx, sqlc.GetUserRoleCodeParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		return err
	}
	if role.Code != domain.OrgRoleOwner {
		return nil
	}
	user, err := q.GetUserByIDInOrg(ctx, sqlc.GetUserByIDInOrgParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ErrNotFound
		}
		return err
	}
	if !user.IsActive {
		return nil
	}
	others, err := q.CountActiveOwnersExcludingUser(ctx, sqlc.CountActiveOwnersExcludingUserParams{OrganizationID: orgID, ID: uid})
	if err != nil {
		return err
	}
	if others == 0 {
		return domain.ErrLastOwner
	}
	return nil
}

// setUserOrganizationRole, kullanıcının organizasyon rolünü değiştirir ve
// kaba users.role'ü senkronlar. Owner'dan başka bir role düşürme, son aktif
// Owner korumasından geçer. roleCode "super_admin" OLAMAZ: organization_roles
// tablosunda böyle bir satır hiç yoktur -> ErrNotFound (bkz. spec: tenant
// admin kimseyi platform yöneticisi yapamaz).
func setUserOrganizationRole(ctx context.Context, q *sqlc.Queries, userID, organizationID, roleCode string) (*domain.OrganizationRole, error) {
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	role, err := q.GetOrganizationRoleByCode(ctx, sqlc.GetOrganizationRoleByCodeParams{OrganizationID: orgID, Code: roleCode})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if role.Code != domain.OrgRoleOwner {
		if err := guardLastActiveOwner(ctx, q, uid, orgID); err != nil {
			return nil, err
		}
	}
	if _, err := q.UpdateUserOrganizationRole(ctx, sqlc.UpdateUserOrganizationRoleParams{
		ID: uid, OrganizationID: orgID, OrganizationRoleID: role.ID,
	}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if err := q.SetUserCoarseRole(ctx, sqlc.SetUserCoarseRoleParams{
		ID: uid, OrganizationID: orgID, Role: string(coarseRoleForOrgRole(role.Code)),
	}); err != nil {
		return nil, err
	}
	dr := repository.ToDomainOrganizationRole(role)
	return &dr, nil
}

// deactivateUser, kullanıcıyı pasifleştirir (satır KALIR, is_active=false),
// son aktif Owner korumasını uygular ve açık oturumlarını (refresh token)
// iptal eder -- pasif kullanıcı ne yeni giriş yapabilir ne de mevcut
// oturumunu yenileyebilir (bkz. AuthService.Login/Refresh).
func deactivateUser(ctx context.Context, q *sqlc.Queries, userID, organizationID string) (pgtype.UUID, error) {
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return pgtype.UUID{}, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return pgtype.UUID{}, domain.ErrNotFound
	}
	if err := guardLastActiveOwner(ctx, q, uid, orgID); err != nil {
		return pgtype.UUID{}, err
	}
	rows, err := q.DeactivateUser(ctx, sqlc.DeactivateUserParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		return pgtype.UUID{}, err
	}
	if rows == 0 {
		return pgtype.UUID{}, domain.ErrNotFound
	}
	if err := q.RevokeAllUserRefreshTokens(ctx, uid); err != nil {
		return pgtype.UUID{}, err
	}
	return uid, nil
}

func reactivateUser(ctx context.Context, q *sqlc.Queries, userID, organizationID string) (pgtype.UUID, error) {
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return pgtype.UUID{}, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return pgtype.UUID{}, domain.ErrNotFound
	}
	rows, err := q.ReactivateUser(ctx, sqlc.ReactivateUserParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		return pgtype.UUID{}, err
	}
	if rows == 0 {
		return pgtype.UUID{}, domain.ErrNotFound
	}
	return uid, nil
}
