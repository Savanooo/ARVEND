package service_test

// Süper Admin'in firma kullanıcı yönetimi + firma yaşam döngüsü -- gerçek
// PostgreSQL'e karşı (DB_URL yoksa atlanır). Kapsam: Owner provisioning'in
// genel "admin" hesabı üretmemesi, son aktif Owner koruması (pasifleştirme
// VE düşürme, platform VE tenant yolları), ikinci Owner'ın kısıtı
// kaldırması, pasifleştirmenin satırı KORUMASI ve oturumu düşürmesi,
// yeniden aktifleştirme, geçici şifre yeniden verme, yaşam döngüsü geçiş
// kuralları ve iptal edilen firmanın verisinin KORUNMASI.

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestPlatformUserManagement(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	platformSvc, userSvc := newPlatformTestServices(q, pool)
	authzSvc := service.NewAuthorizationService(pool, q)
	authSvc := service.NewAuthService(q, auth.NewJWTIssuer("test-secret-um", 15*time.Minute), 24*time.Hour)

	const slug = "platform-um-firma"
	usernames := []string{"um_owner_1", "um_owner_2", "um_field"}
	row := pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug)
	var existingID string
	if scanErr := row.Scan(&existingID); scanErr == nil {
		cleanupPlatformOrg(t, pool, existingID)
	}
	_, _ = pool.Exec(ctx, "DELETE FROM users WHERE username = ANY($1::text[])", usernames)

	created, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
		Name: "Platform UM Firma", Slug: slug,
		OwnerUsername: "um_owner_1", OwnerPassword: "GecicSifre123!", OwnerFullName: "Birinci Sahip",
	})
	if err != nil {
		t.Fatalf("organizasyon+owner oluşturulamadı: %v", err)
	}
	org := created.Organization
	owner1 := created.Owner
	t.Cleanup(func() { cleanupPlatformOrg(t, pool, org.ID) })

	auditHas := func(t *testing.T, action string, targetUserID string) bool {
		t.Helper()
		events, err := platformSvc.ListAuditEvents(ctx, org.ID, 1, 100)
		if err != nil {
			t.Fatalf("audit okunamadı: %v", err)
		}
		for _, e := range events {
			if e.Action != action {
				continue
			}
			if targetUserID == "" || (e.TargetUserID != nil && *e.TargetUserID == targetUserID) {
				return true
			}
		}
		return false
	}

	t.Run("organization_creation_provisions_owner_not_generic_admin", func(t *testing.T) {
		list, err := platformSvc.ListOrganizationUsers(ctx, org.ID, 1, 50)
		if err != nil {
			t.Fatalf("kullanıcılar listelenemedi: %v", err)
		}
		if list.Total != 1 || len(list.Users) != 1 {
			t.Fatalf("kullanıcı sayısı = %d/%d, want 1", list.Total, len(list.Users))
		}
		u := list.Users[0]
		if u.Username == "admin" || strings.EqualFold(u.Username, "admin") {
			t.Errorf("genel 'admin' hesabı üretildi")
		}
		if u.OrganizationRoleCode != domain.OrgRoleOwner {
			t.Errorf("organization_role_code = %q, want owner (liste org rolüyle zenginleşmeli)", u.OrganizationRoleCode)
		}
		if !u.MustChangePassword {
			t.Errorf("must_change_password = false, want true")
		}
	})

	t.Run("generic_admin_username_rejected_on_provisioning", func(t *testing.T) {
		_, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
			Name: "UM Admin Firma", Slug: slug + "-admin",
			OwnerUsername: "admin", OwnerPassword: "GecicSifre123!", OwnerFullName: "Genel Admin",
		})
		if !errors.Is(err, domain.ErrReservedUsername) {
			t.Fatalf("err = %v, want ErrReservedUsername", err)
		}
		var n int
		if err := pool.QueryRow(ctx, "SELECT count(*) FROM organizations WHERE slug = $1", slug+"-admin").Scan(&n); err != nil || n != 0 {
			t.Errorf("reddedilen provisioning firma satırı bıraktı (n=%d, err=%v)", n, err)
		}
		_, err = platformSvc.ProvisionOrganizationUser(ctx, service.ProvisionOrganizationUserInput{
			OrganizationID: org.ID, Username: "Admin", FullName: "Genel", TemporaryPassword: "GecicSifre123!", RoleCode: domain.OrgRoleOwner,
		})
		if !errors.Is(err, domain.ErrReservedUsername) {
			t.Errorf("platform user provisioning err = %v, want ErrReservedUsername", err)
		}
	})

	t.Run("last_active_owner_cannot_be_deactivated_via_any_path", func(t *testing.T) {
		if err := platformSvc.DeactivateOrganizationUser(ctx, org.ID, owner1.ID, ""); !errors.Is(err, domain.ErrLastOwner) {
			t.Errorf("platform deactivate err = %v, want ErrLastOwner", err)
		}
		if err := userSvc.Deactivate(ctx, owner1.ID, org.ID, owner1.ID); !errors.Is(err, domain.ErrLastOwner) {
			t.Errorf("tenant deactivate err = %v, want ErrLastOwner", err)
		}
		if _, err := userSvc.Update(ctx, owner1.ID, org.ID, owner1.ID, "Birinci Sahip", false); !errors.Is(err, domain.ErrLastOwner) {
			t.Errorf("tenant update(is_active=false) err = %v, want ErrLastOwner", err)
		}
		u, err := userSvc.Get(ctx, owner1.ID, org.ID)
		if err != nil || !u.IsActive {
			t.Errorf("son Owner pasifleşti veya okunamadı (err=%v)", err)
		}
	})

	t.Run("last_active_owner_cannot_be_demoted_via_any_path", func(t *testing.T) {
		if _, err := platformSvc.SetOrganizationUserRole(ctx, org.ID, owner1.ID, domain.OrgRoleProjectManager, ""); !errors.Is(err, domain.ErrLastOwner) {
			t.Errorf("platform demote err = %v, want ErrLastOwner", err)
		}
		if _, err := authzSvc.SetUserOrganizationRole(ctx, owner1.ID, org.ID, owner1.ID, domain.OrgRoleFinance); !errors.Is(err, domain.ErrLastOwner) {
			t.Errorf("tenant demote err = %v, want ErrLastOwner", err)
		}
	})

	t.Run("legacy_user_not_assignable_from_platform", func(t *testing.T) {
		if _, err := platformSvc.SetOrganizationUserRole(ctx, org.ID, owner1.ID, domain.OrgRoleLegacyUser, ""); !errors.Is(err, domain.ErrRoleNotAssignable) {
			t.Errorf("err = %v, want ErrRoleNotAssignable", err)
		}
		if _, err := platformSvc.ProvisionOrganizationUser(ctx, service.ProvisionOrganizationUserInput{
			OrganizationID: org.ID, Username: "um_legacy", FullName: "Eski", TemporaryPassword: "GecicSifre123!", RoleCode: domain.OrgRoleLegacyUser,
		}); !errors.Is(err, domain.ErrRoleNotAssignable) {
			t.Errorf("provision legacy err = %v, want ErrRoleNotAssignable", err)
		}
	})

	var owner2 *domain.User
	t.Run("provision_second_owner", func(t *testing.T) {
		u, err := platformSvc.ProvisionOrganizationUser(ctx, service.ProvisionOrganizationUserInput{
			OrganizationID: org.ID, Username: "um_owner_2", FullName: "İkinci Sahip",
			TemporaryPassword: "GecicSifre123!", RoleCode: domain.OrgRoleOwner, ActorUserID: "",
		})
		if err != nil {
			t.Fatalf("ikinci owner oluşturulamadı: %v", err)
		}
		owner2 = u
		if u.OrganizationRoleCode != domain.OrgRoleOwner || u.Role != domain.RoleAdmin || !u.MustChangePassword {
			t.Errorf("owner2 = role %q / org role %q / must_change %v, want admin/owner/true", u.Role, u.OrganizationRoleCode, u.MustChangePassword)
		}
		if !auditHas(t, domain.AuditActionUserProvisioned, u.ID) {
			t.Errorf("user_provisioned audit kaydı yok")
		}
	})

	t.Run("second_owner_allows_demotion_and_deactivation_of_first_and_record_is_preserved", func(t *testing.T) {
		if _, err := platformSvc.SetOrganizationUserRole(ctx, org.ID, owner1.ID, domain.OrgRoleProjectManager, ""); err != nil {
			t.Fatalf("düşürme başarısız: %v", err)
		}
		u, err := authzSvc.GetUserWithRole(ctx, owner1.ID, org.ID)
		if err != nil {
			t.Fatalf("kullanıcı okunamadı: %v", err)
		}
		if u.OrganizationRoleCode != domain.OrgRoleProjectManager || u.Role != domain.RoleKullanici {
			t.Errorf("düşürme sonrası org role %q / kaba rol %q, want project_manager/kullanici (kaba rol senkronu)", u.OrganizationRoleCode, u.Role)
		}
		if !auditHas(t, domain.AuditActionUserRoleChanged, owner1.ID) {
			t.Errorf("user_role_changed audit kaydı yok")
		}
		// Geri Sahip yap (ikinci Sahip varken serbest) ve kaba rol yeniden admin olsun.
		if _, err := platformSvc.SetOrganizationUserRole(ctx, org.ID, owner1.ID, domain.OrgRoleOwner, ""); err != nil {
			t.Fatalf("yeniden owner yapılamadı: %v", err)
		}
		u, _ = authzSvc.GetUserWithRole(ctx, owner1.ID, org.ID)
		if u.Role != domain.RoleAdmin {
			t.Errorf("owner'a dönüşte kaba rol %q, want admin", u.Role)
		}

		if err := platformSvc.DeactivateOrganizationUser(ctx, org.ID, owner1.ID, ""); err != nil {
			t.Fatalf("ikinci Sahip varken pasifleştirme başarısız: %v", err)
		}
		var exists, active bool
		if err := pool.QueryRow(ctx, "SELECT true, is_active FROM users WHERE id = $1", owner1.ID).Scan(&exists, &active); err != nil {
			t.Fatalf("pasifleştirilen kullanıcı satırı KAYBOLDU: %v", err)
		}
		if active {
			t.Errorf("is_active hâlâ true")
		}
		list, _ := platformSvc.ListOrganizationUsers(ctx, org.ID, 1, 50)
		if list.Total != 2 {
			t.Errorf("pasifleştirme sonrası toplam = %d, want 2 (kayıt korunur)", list.Total)
		}
		if !auditHas(t, domain.AuditActionUserDeactivated, owner1.ID) {
			t.Errorf("user_deactivated audit kaydı yok")
		}
	})

	t.Run("inactive_user_cannot_login_and_open_session_cannot_refresh", func(t *testing.T) {
		if _, err := authSvc.Login(ctx, "um_owner_1", "GecicSifre123!"); !errors.Is(err, domain.ErrInactiveUser) {
			t.Errorf("pasif kullanıcı login err = %v, want ErrInactiveUser", err)
		}
		field, err := platformSvc.ProvisionOrganizationUser(ctx, service.ProvisionOrganizationUserInput{
			OrganizationID: org.ID, Username: "um_field", FullName: "Saha", TemporaryPassword: "GecicSifre123!", RoleCode: domain.OrgRoleField,
		})
		if err != nil {
			t.Fatalf("saha kullanıcısı oluşturulamadı: %v", err)
		}
		if field.Role != domain.RoleKullanici {
			t.Errorf("saha kullanıcısının kaba rolü %q, want kullanici", field.Role)
		}
		sess, err := authSvc.Login(ctx, "um_field", "GecicSifre123!")
		if err != nil {
			t.Fatalf("saha login başarısız: %v", err)
		}
		if err := platformSvc.DeactivateOrganizationUser(ctx, org.ID, field.ID, ""); err != nil {
			t.Fatalf("saha pasifleştirilemedi: %v", err)
		}
		if _, err := authSvc.Refresh(ctx, sess.RefreshToken); err == nil {
			t.Errorf("pasifleştirilen kullanıcının açık oturumu YENİLENEBİLDİ")
		}
	})

	t.Run("now_second_owner_is_last_active_owner", func(t *testing.T) {
		if err := platformSvc.DeactivateOrganizationUser(ctx, org.ID, owner2.ID, ""); !errors.Is(err, domain.ErrLastOwner) {
			t.Errorf("err = %v, want ErrLastOwner", err)
		}
		if _, err := platformSvc.SetOrganizationUserRole(ctx, org.ID, owner2.ID, domain.OrgRoleFinance, ""); !errors.Is(err, domain.ErrLastOwner) {
			t.Errorf("demote err = %v, want ErrLastOwner", err)
		}
	})

	t.Run("reactivate_first_owner", func(t *testing.T) {
		if err := platformSvc.ReactivateOrganizationUser(ctx, org.ID, owner1.ID, ""); err != nil {
			t.Fatalf("yeniden aktifleştirme başarısız: %v", err)
		}
		u, _ := userSvc.Get(ctx, owner1.ID, org.ID)
		if u == nil || !u.IsActive {
			t.Fatalf("kullanıcı aktif değil")
		}
		if _, err := authSvc.Login(ctx, "um_owner_1", "GecicSifre123!"); err != nil {
			t.Errorf("aktifleştirilen kullanıcı giriş yapamadı: %v", err)
		}
		if !auditHas(t, domain.AuditActionUserReactivated, owner1.ID) {
			t.Errorf("user_reactivated audit kaydı yok")
		}
	})

	t.Run("reset_initial_password_reissues_must_change_and_revokes_sessions", func(t *testing.T) {
		sess, err := authSvc.Login(ctx, "um_owner_1", "GecicSifre123!")
		if err != nil {
			t.Fatalf("login: %v", err)
		}
		if err := platformSvc.ResetOrganizationUserPassword(ctx, org.ID, owner1.ID, "YeniGecici123!", ""); err != nil {
			t.Fatalf("geçici şifre verilemedi: %v", err)
		}
		if _, err := authSvc.Refresh(ctx, sess.RefreshToken); err == nil {
			t.Errorf("şifre sıfırlama sonrası eski oturum yenilenebildi")
		}
		if _, err := authSvc.Login(ctx, "um_owner_1", "GecicSifre123!"); !errors.Is(err, domain.ErrInvalidCredentials) {
			t.Errorf("eski şifreyle login err = %v, want ErrInvalidCredentials", err)
		}
		s2, err := authSvc.Login(ctx, "um_owner_1", "YeniGecici123!")
		if err != nil {
			t.Fatalf("yeni geçici şifreyle login: %v", err)
		}
		if !s2.User.MustChangePassword {
			t.Errorf("must_change_password = false, want true")
		}
		events, _ := platformSvc.ListAuditEvents(ctx, org.ID, 1, 100)
		for _, e := range events {
			for _, v := range e.Metadata {
				if s, ok := v.(string); ok && (s == "YeniGecici123!" || s == "GecicSifre123!") {
					t.Errorf("audit metadata'sına şifre SIZDI: %+v", e)
				}
			}
		}
		if !auditHas(t, domain.AuditActionUserPasswordReset, owner1.ID) {
			t.Errorf("user_password_reset audit kaydı yok")
		}
	})

	t.Run("organization_lifecycle_transitions_and_preservation", func(t *testing.T) {
		if _, err := platformSvc.SetStatus(ctx, org.ID, "", domain.OrgStatusSuspended); err != nil {
			t.Fatalf("askıya alma: %v", err)
		}
		if _, err := authSvc.Login(ctx, "um_owner_1", "YeniGecici123!"); !errors.Is(err, domain.ErrOrganizationSuspended) {
			t.Errorf("askıdaki firma login err = %v, want ErrOrganizationSuspended", err)
		}
		if _, err := platformSvc.SetStatus(ctx, org.ID, "", domain.OrgStatusSuspended); !errors.Is(err, domain.ErrInvalidOrgStatusTransition) {
			t.Errorf("aynı duruma geçiş err = %v, want ErrInvalidOrgStatusTransition", err)
		}
		if _, err := platformSvc.SetStatus(ctx, org.ID, "", domain.OrgStatusTrial); !errors.Is(err, domain.ErrInvalidOrgStatusTransition) {
			t.Errorf("trial'a dönüş err = %v, want ErrInvalidOrgStatusTransition", err)
		}
		if _, err := platformSvc.SetStatus(ctx, org.ID, "", domain.OrgStatusCancelled); err != nil {
			t.Fatalf("iptal: %v", err)
		}
		if !auditHas(t, domain.AuditActionOrganizationCancelled, "") {
			t.Errorf("organization_cancelled audit kaydı yok")
		}
		if _, err := platformSvc.SetStatus(ctx, org.ID, "", domain.OrgStatusSuspended); !errors.Is(err, domain.ErrInvalidOrgStatusTransition) {
			t.Errorf("cancelled -> suspended err = %v, want ErrInvalidOrgStatusTransition", err)
		}
		// İptal edilen firma ve TÜM kullanıcıları DB'de kalır.
		got, err := platformSvc.GetOrganization(ctx, org.ID)
		if err != nil || got.Status != domain.OrgStatusCancelled || got.IsActive {
			t.Fatalf("iptal edilen firma korunmadı/yanlış durumda: %+v err=%v", got, err)
		}
		var n int
		if err := pool.QueryRow(ctx, "SELECT count(*) FROM users WHERE organization_id = $1", org.ID).Scan(&n); err != nil || n != 3 {
			t.Errorf("iptal sonrası kullanıcı sayısı = %d (err=%v), want 3 (korunur)", n, err)
		}
		list, err := platformSvc.ListOrganizationUsers(ctx, org.ID, 1, 50)
		if err != nil || list.Total != 3 {
			t.Errorf("iptal edilen firmanın kullanıcıları listelenemedi: %v", err)
		}
		if _, err := authSvc.Login(ctx, "um_owner_1", "YeniGecici123!"); !errors.Is(err, domain.ErrOrganizationSuspended) {
			t.Errorf("iptal edilen firma login err = %v, want ErrOrganizationSuspended", err)
		}
		if _, err := platformSvc.SetStatus(ctx, org.ID, "", domain.OrgStatusActive); err != nil {
			t.Fatalf("yeniden aktifleştirme: %v", err)
		}
		if _, err := authSvc.Login(ctx, "um_owner_1", "YeniGecici123!"); err != nil {
			t.Errorf("yeniden aktif firma login başarısız: %v", err)
		}
	})

	t.Run("list_organization_roles_excludes_legacy_user", func(t *testing.T) {
		roles, err := platformSvc.ListOrganizationRoles(ctx, org.ID)
		if err != nil {
			t.Fatalf("roller alınamadı: %v", err)
		}
		codes := map[string]bool{}
		for _, r := range roles {
			codes[r.Code] = true
		}
		for _, want := range []string{domain.OrgRoleOwner, domain.OrgRoleAdmin, domain.OrgRoleProjectManager, domain.OrgRoleFinance, domain.OrgRoleField} {
			if !codes[want] {
				t.Errorf("rol listesinde %q yok", want)
			}
		}
		if codes[domain.OrgRoleLegacyUser] {
			t.Errorf("legacy_user platform rol listesinde göründü")
		}
	})
}
