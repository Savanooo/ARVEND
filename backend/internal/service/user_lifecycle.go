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

// guardOwnerOnlyAction, Sahip'e dokunan ya da Sahip yaratan bir işlemi
// yalnızca bir Sahip'in yapmasına izin verir (domain.ErrOwnerOnlyAction).
// Kısıt yalnızca hedef Sahip ise ya da newRoleCode Sahip ise devreye girer;
// diğer işlemler (Yönetici'nin bir Saha kullanıcısını pasifleştirmesi gibi)
// etkilenmez. targetUID boş olabilir (henüz var olmayan kullanıcıya rol
// verme). actorUserID boşsa/geçersizse aktör Sahip sayılmaz. Platform
// (Süper Admin) yolu bu kontrolden geçmez -- o, firmalar üstü bir yetkidir.
func guardOwnerOnlyAction(ctx context.Context, q *sqlc.Queries, actorUserID string, targetUID, orgID pgtype.UUID, newRoleCode string) error {
	touchesOwner := newRoleCode == domain.OrgRoleOwner
	if !touchesOwner && targetUID.Valid {
		role, err := q.GetUserRoleCode(ctx, sqlc.GetUserRoleCodeParams{ID: targetUID, OrganizationID: orgID})
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		touchesOwner = err == nil && role.Code == domain.OrgRoleOwner
	}
	if !touchesOwner {
		return nil
	}
	actor, err := repository.StringToUUID(actorUserID)
	if err != nil {
		return domain.ErrOwnerOnlyAction
	}
	actorRole, err := q.GetUserRoleCode(ctx, sqlc.GetUserRoleCodeParams{ID: actor, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ErrOwnerOnlyAction
		}
		return err
	}
	if actorRole.Code != domain.OrgRoleOwner {
		return domain.ErrOwnerOnlyAction
	}
	return nil
}

// guardLastActiveOwner, hedef kullanıcı organizasyonun SON AKTİF Owner'ı ise
// domain.ErrLastOwner döner. Owner olmayan ya da zaten pasif bir hedef için
// kısıt yoktur (pasif bir Owner zaten sayılmaz; başka aktif Owner varsa
// düşürülebilir). Kullanıcı bu organizasyonda yoksa ErrNotFound.
//
// Önce firma satırını kilitler (LockOrganizationForOwnerChange): sayım ile
// ardından gelen pasifleştirme/rol değişikliği arasında aynı firmada başka
// bir sahiplik değişikliği araya giremez. Bu yüzden q bir transaction'a
// bağlı OLMALI ve değişiklik AYNI transaction'da yapılmalıdır -- kilit
// commit'e kadar tutulur.
func guardLastActiveOwner(ctx context.Context, q *sqlc.Queries, uid, orgID pgtype.UUID) error {
	if err := q.LockOrganizationForOwnerChange(ctx, orgID); err != nil {
		return err
	}
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
	current, err := q.GetUserRoleCode(ctx, sqlc.GetUserRoleCodeParams{ID: uid, OrganizationID: orgID})
	hadRole := err == nil
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
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
	// Kişiye özel yetki ayarları ESKİ role göre tutulan farklardır -- rol
	// değişince anlamlarını yitirirler, sıfırlanır (aynı rol yeniden
	// seçilirse korunur).
	if !hadRole || current.Code != role.Code {
		if err := q.ClearUserPermissionOverrides(ctx, sqlc.ClearUserPermissionOverridesParams{UserID: uid, OrganizationID: orgID}); err != nil {
			return nil, err
		}
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
	if err := endUserAccess(ctx, q, uid); err != nil {
		return pgtype.UUID{}, err
	}
	return uid, nil
}

// endUserAccess, erişimi kesilen kullanıcının açık oturumlarını (refresh
// token) iptal eder ve telefon kayıtlarını siler -- pasif/silinmiş biri ne
// oturumunu yenileyebilir ne de bildirim almaya devam eder.
func endUserAccess(ctx context.Context, q *sqlc.Queries, uid pgtype.UUID) error {
	if err := q.RevokeAllUserRefreshTokens(ctx, uid); err != nil {
		return err
	}
	return q.DeleteAllUserPushDevices(ctx, uid)
}

// reactivateUser, silinmiş bir kullanıcıda REDDEDİLİR -- "silinmiş ama
// aktif" gibi tutarsız bir durum asla oluşmamalı (bkz. migration 0043:
// deleteUser is_active'i AYNI anda false yapar, bu değişmez öyle kalır).
// Silinmiş bir kullanıcı önce restoreUser ile geri yüklenmeli, aktifleştirme
// AYRI ve bilinçli bir sonraki adımdır (bkz. restoreUser yorumu).
func reactivateUser(ctx context.Context, q *sqlc.Queries, userID, organizationID string) (pgtype.UUID, error) {
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return pgtype.UUID{}, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return pgtype.UUID{}, domain.ErrNotFound
	}
	current, err := q.GetUserByIDInOrg(ctx, sqlc.GetUserByIDInOrgParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return pgtype.UUID{}, domain.ErrNotFound
		}
		return pgtype.UUID{}, err
	}
	if current.DeletedAt.Valid {
		return pgtype.UUID{}, domain.ErrUserDeleted
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

// deleteUser, kullanıcıyı YUMUŞAK siler: satır KALIR, deleted_at/deleted_by
// yazılır VE is_active AYNI anda false yapılır (bkz. migration 0043 --
// "silinmiş kullanıcı giriş yapamaz" garantisi böylece HALİHAZIRDA var olan
// is_active kontrolünden bedava gelir, yeni bir kod yolu gerekmez). Son
// aktif Owner korumasını uygular (guardLastActiveOwner, deaktivasyonla
// AYNI kural -- silme, deaktivasyonun bir üst kümesidir) ve açık
// oturumlarını iptal eder.
func deleteUser(ctx context.Context, q *sqlc.Queries, userID, organizationID, actorUserID string) (pgtype.UUID, error) {
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
	current, err := q.GetUserByIDInOrg(ctx, sqlc.GetUserByIDInOrgParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return pgtype.UUID{}, domain.ErrNotFound
		}
		return pgtype.UUID{}, err
	}
	if current.DeletedAt.Valid {
		return pgtype.UUID{}, domain.ErrAlreadyDeleted
	}
	var deletedBy pgtype.UUID
	if actorUserID != "" {
		if aid, aerr := repository.StringToUUID(actorUserID); aerr == nil {
			deletedBy = aid
		}
	}
	rows, err := q.SoftDeleteUser(ctx, sqlc.SoftDeleteUserParams{ID: uid, OrganizationID: orgID, DeletedBy: deletedBy})
	if err != nil {
		return pgtype.UUID{}, err
	}
	if rows == 0 {
		return pgtype.UUID{}, domain.ErrAlreadyDeleted
	}
	if err := endUserAccess(ctx, q, uid); err != nil {
		return pgtype.UUID{}, err
	}
	return uid, nil
}

// restoreUser, YALNIZCA silme durumunu geri alır (deleted_at/deleted_by
// temizlenir) -- is_active BİLİNÇLİ OLARAK false kalır (deleteUser'ın
// onu false yapmasının simetriği): geri yüklenen kullanıcı organizasyonun
// normal (silinmemiş) listesine "Pasif" olarak döner, giriş erişimi AYRI
// bir "Aktifleştir" eylemiyle verilir -- restore tek başına sessizce
// giriş erişimini geri VERMEZ.
func restoreUser(ctx context.Context, q *sqlc.Queries, userID, organizationID string) (pgtype.UUID, error) {
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return pgtype.UUID{}, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return pgtype.UUID{}, domain.ErrNotFound
	}
	rows, err := q.RestoreUser(ctx, sqlc.RestoreUserParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		return pgtype.UUID{}, err
	}
	if rows == 0 {
		return pgtype.UUID{}, domain.ErrNotDeleted
	}
	return uid, nil
}
