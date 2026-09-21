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

// Süper Admin'in bir firmanın kullanıcıları üzerindeki yönetim işlemleri.
// Her metot organizasyon kimliğini AÇIKÇA alır (URL'den) -- platform
// hesabı için hiçbir tenant bağlamı çıkarsanmaz. Kurallar (son aktif Owner
// koruması, kaba rol senkronu, oturum iptali) tenant tarafıyla ORTAK
// (user_lifecycle.go); burada yalnızca açık org hedefi + denetim kaydı
// eklenir. Hiçbir metot satır SİLMEZ.

type ProvisionOrganizationUserInput struct {
	OrganizationID    string
	Username          string
	FullName          string
	TemporaryPassword string
	RoleCode          string // organization_roles.code -- legacy_user ATANAMAZ
	ActorUserID       string
}

// ListOrganizationRoles, firmanın atanabilir organizasyon rollerini döner
// (özel roller dahil); legacy_user yeni atama hedefi olmadığı için dışarıda.
func (s *PlatformService) ListOrganizationRoles(ctx context.Context, organizationID string) ([]domain.OrganizationRole, error) {
	if _, err := s.GetOrganization(ctx, organizationID); err != nil {
		return nil, err
	}
	orgID, _ := repository.StringToUUID(organizationID)
	rows, err := s.q.ListOrganizationRoles(ctx, orgID)
	if err != nil {
		return nil, err
	}
	out := make([]domain.OrganizationRole, 0, len(rows))
	for _, r := range rows {
		if r.Code == domain.OrgRoleLegacyUser {
			continue
		}
		out = append(out, repository.ToDomainOrganizationRole(r))
	}
	return out, nil
}

// ProvisionOrganizationUser, firmaya yeni bir kullanıcı (gerekirse ilk/yeni
// Sahip) ekler: must_change_password=true ile başlar, geçici şifre ilk
// girişte zorunlu değiştirilir (CreateOrganizationWithOwner ile AYNI akış).
// Genel "admin" kullanıcı adı reddedilir; kaba users.role organizasyon
// rolünden türetilir (owner/admin -> admin, diğerleri -> kullanici).
func (s *PlatformService) ProvisionOrganizationUser(ctx context.Context, in ProvisionOrganizationUserInput) (*domain.User, error) {
	username := strings.TrimSpace(in.Username)
	fullName := strings.TrimSpace(in.FullName)
	roleCode := strings.TrimSpace(in.RoleCode)
	if username == "" || fullName == "" || in.TemporaryPassword == "" || roleCode == "" {
		return nil, errors.New("kullanıcı adı, ad soyad, geçici şifre ve organizasyon rolü zorunludur")
	}
	if isReservedUsername(username) {
		return nil, domain.ErrReservedUsername
	}
	if len(in.TemporaryPassword) < 8 {
		return nil, errors.New("geçici şifre en az 8 karakter olmalı")
	}
	if roleCode == domain.OrgRoleLegacyUser {
		return nil, domain.ErrRoleNotAssignable
	}
	if _, err := s.GetOrganization(ctx, in.OrganizationID); err != nil {
		return nil, err
	}
	orgID, _ := repository.StringToUUID(in.OrganizationID)

	hash, err := auth.HashPassword(in.TemporaryPassword)
	if err != nil {
		return nil, err
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	role, err := txq.GetOrganizationRoleByCode(ctx, sqlc.GetOrganizationRoleByCodeParams{OrganizationID: orgID, Code: roleCode})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	userRow, err := txq.CreateUserWithOptions(ctx, sqlc.CreateUserWithOptionsParams{
		OrganizationID:     orgID,
		Username:           username,
		PasswordHash:       hash,
		FullName:           fullName,
		Role:               string(coarseRoleForOrgRole(role.Code)),
		MustChangePassword: true,
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, domain.ErrDuplicateUsername
		}
		return nil, err
	}
	userRow, err = txq.UpdateUserOrganizationRole(ctx, sqlc.UpdateUserOrganizationRoleParams{
		ID: userRow.ID, OrganizationID: orgID, OrganizationRoleID: role.ID,
	})
	if err != nil {
		return nil, err
	}
	if err := s.writeAuditEvent(ctx, txq, in.ActorUserID, domain.AuditActionUserProvisioned, &orgID, &userRow.ID, map[string]any{
		"username": username, "role_code": role.Code,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	u := repository.ToDomainUser(userRow)
	u.OrganizationRoleCode = role.Code
	u.OrganizationRoleName = role.Name
	return &u, nil
}

func (s *PlatformService) DeactivateOrganizationUser(ctx context.Context, organizationID, userID, actorUserID string) error {
	if _, err := s.GetOrganization(ctx, organizationID); err != nil {
		return err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	uid, err := deactivateUser(ctx, txq, userID, organizationID)
	if err != nil {
		return err
	}
	orgID, _ := repository.StringToUUID(organizationID)
	if err := s.writeAuditEvent(ctx, txq, actorUserID, domain.AuditActionUserDeactivated, &orgID, &uid, userAuditMetadata(ctx, txq, uid, orgID)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// userAuditMetadata, kullanıcı denetim kayıtlarına yalnızca kullanıcı adını
// ekler (denetim listesinde okunabilirlik için) -- şifre/hash ASLA girmez.
func userAuditMetadata(ctx context.Context, q *sqlc.Queries, uid, orgID pgtype.UUID) map[string]any {
	row, err := q.GetUserByIDInOrg(ctx, sqlc.GetUserByIDInOrgParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		return nil
	}
	return map[string]any{"username": row.Username}
}

func (s *PlatformService) ReactivateOrganizationUser(ctx context.Context, organizationID, userID, actorUserID string) error {
	if _, err := s.GetOrganization(ctx, organizationID); err != nil {
		return err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	uid, err := reactivateUser(ctx, txq, userID, organizationID)
	if err != nil {
		return err
	}
	orgID, _ := repository.StringToUUID(organizationID)
	if err := s.writeAuditEvent(ctx, txq, actorUserID, domain.AuditActionUserReactivated, &orgID, &uid, userAuditMetadata(ctx, txq, uid, orgID)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// SetOrganizationUserRole, Süper Admin'in bir firma kullanıcısının
// organizasyon rolünü değiştirmesidir -- tenant tarafındaki AYNI kural
// (son aktif Owner düşürülemez, kaba rol senkronu). legacy_user hedef olamaz.
func (s *PlatformService) SetOrganizationUserRole(ctx context.Context, organizationID, userID, roleCode, actorUserID string) (*domain.OrganizationRole, error) {
	if strings.TrimSpace(roleCode) == domain.OrgRoleLegacyUser {
		return nil, domain.ErrRoleNotAssignable
	}
	if _, err := s.GetOrganization(ctx, organizationID); err != nil {
		return nil, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	role, err := setUserOrganizationRole(ctx, txq, userID, organizationID, strings.TrimSpace(roleCode))
	if err != nil {
		return nil, err
	}
	orgID, _ := repository.StringToUUID(organizationID)
	uid, _ := repository.StringToUUID(userID)
	meta := userAuditMetadata(ctx, txq, uid, orgID)
	if meta == nil {
		meta = map[string]any{}
	}
	meta["role_code"] = role.Code
	if err := s.writeAuditEvent(ctx, txq, actorUserID, domain.AuditActionUserRoleChanged, &orgID, &uid, meta); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return role, nil
}

// ResetOrganizationUserPassword, "ilk şifre" akışını yeniden başlatır: yeni
// bir geçici şifre yazılır, must_change_password=true olur, açık oturumlar
// iptal edilir. Geçici şifre denetim kaydına ASLA yazılmaz.
func (s *PlatformService) ResetOrganizationUserPassword(ctx context.Context, organizationID, userID, temporaryPassword, actorUserID string) error {
	if len(temporaryPassword) < 8 {
		return errors.New("geçici şifre en az 8 karakter olmalı")
	}
	if _, err := s.GetOrganization(ctx, organizationID); err != nil {
		return err
	}
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, _ := repository.StringToUUID(organizationID)
	hash, err := auth.HashPassword(temporaryPassword)
	if err != nil {
		return err
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	rows, err := txq.ResetPasswordRequireChange(ctx, sqlc.ResetPasswordRequireChangeParams{ID: uid, OrganizationID: orgID, PasswordHash: hash})
	if err != nil {
		return err
	}
	if rows == 0 {
		return domain.ErrNotFound
	}
	if err := txq.RevokeAllUserRefreshTokens(ctx, uid); err != nil {
		return err
	}
	if err := s.writeAuditEvent(ctx, txq, actorUserID, domain.AuditActionUserPasswordReset, &orgID, &uid, userAuditMetadata(ctx, txq, uid, orgID)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
