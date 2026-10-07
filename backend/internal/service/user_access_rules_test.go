package service_test

// Kullanıcı yönetiminin erişim kuralları, gerçek PostgreSQL'e karşı:
// Sahip'e dokunan işlemler yalnızca Sahip'in, şifre değişince oturumlar
// kapanır, "ilk şifre" ucu yalnızca geçici şifreli kullanıcıya açıktır,
// asgari şifre uzunluğu, pasifleştirmede telefon kayıtları silinir ve
// iki Sahip aynı anda birbirini pasifleştiremez.

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestUserAccessRules(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	platformSvc, userSvc := newPlatformTestServices(q, pool)
	authzSvc := service.NewAuthorizationService(pool, q)
	authSvc := service.NewAuthService(q, auth.NewJWTIssuer("test-secret-access-rules", 15*time.Minute), 24*time.Hour)
	pushSvc := service.NewPushService(q, nil)

	const slug = "user-access-rules"
	usernames := []string{"uar_owner", "uar_owner2", "uar_admin", "uar_field", "uar_short", "uar_wannabe"}
	if row := pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug); row != nil {
		var existingID string
		if row.Scan(&existingID) == nil {
			cleanupPlatformOrg(t, pool, existingID)
		}
	}
	_, _ = pool.Exec(ctx, "DELETE FROM users WHERE username = ANY($1::text[])", usernames)

	created, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
		Name: "Erişim Kuralları Firma", Slug: slug,
		OwnerUsername: "uar_owner", OwnerPassword: "GeciciSifre123!", OwnerFullName: "Asıl Sahip",
	})
	if err != nil {
		t.Fatalf("firma: %v", err)
	}
	org := created.Organization
	owner := created.Owner
	t.Cleanup(func() { cleanupPlatformOrg(t, pool, org.ID) })

	admin, _, err := userSvc.CreateMember(ctx, org.ID, owner.ID, "uar_admin", "GeciciSifre123!", "Yönetici", domain.OrgRoleAdmin, service.PersonnelOptions{})
	if err != nil {
		t.Fatalf("yönetici: %v", err)
	}
	field, _, err := userSvc.CreateMember(ctx, org.ID, admin.ID, "uar_field", "GeciciSifre123!", "Saha", domain.OrgRoleField, service.PersonnelOptions{})
	if err != nil {
		t.Fatalf("saha: %v", err)
	}

	t.Run("Yönetici Sahip'e dokunamaz", func(t *testing.T) {
		if err := userSvc.AdminResetPassword(ctx, owner.ID, org.ID, admin.ID, "ElGecirme123!"); !errors.Is(err, domain.ErrOwnerOnlyAction) {
			t.Errorf("Sahip'in şifresini sıfırlama: ErrOwnerOnlyAction beklendi, %v", err)
		}
		if _, err := authSvc.Login(ctx, "uar_owner", "ElGecirme123!"); err == nil {
			t.Error("reddedilen sıfırlamanın şifresiyle giriş yapılabildi")
		}
		if err := userSvc.Deactivate(ctx, owner.ID, org.ID, admin.ID); !errors.Is(err, domain.ErrOwnerOnlyAction) {
			t.Errorf("Sahip'i pasifleştirme: %v", err)
		}
		if _, err := userSvc.Update(ctx, owner.ID, org.ID, admin.ID, "Asıl Sahip", false); !errors.Is(err, domain.ErrOwnerOnlyAction) {
			t.Errorf("formdan Sahip'i pasife alma: %v", err)
		}
		if _, err := authzSvc.SetUserOrganizationRole(ctx, owner.ID, org.ID, admin.ID, domain.OrgRoleField); !errors.Is(err, domain.ErrOwnerOnlyAction) {
			t.Errorf("Sahip'in rolünü düşürme: %v", err)
		}
		if _, err := authzSvc.SetUserOrganizationRole(ctx, admin.ID, org.ID, admin.ID, domain.OrgRoleOwner); !errors.Is(err, domain.ErrOwnerOnlyAction) {
			t.Errorf("kendini Sahip yapma: %v", err)
		}
		if _, _, err := userSvc.CreateMember(ctx, org.ID, admin.ID, "uar_wannabe", "GeciciSifre123!", "Sahte Sahip", domain.OrgRoleOwner, service.PersonnelOptions{}); !errors.Is(err, domain.ErrOwnerOnlyAction) {
			t.Errorf("Sahip rolüyle hesap açma: %v", err)
		}
		// Sahip'in adını düzeltmek serbest.
		if _, err := userSvc.Update(ctx, owner.ID, org.ID, admin.ID, "Asıl Sahip (düzeltildi)", true); err != nil {
			t.Errorf("Sahip'in adını düzeltmek engellenmemeli: %v", err)
		}
		// Yöneticinin olağan işleri etkilenmez.
		if _, err := authzSvc.SetUserOrganizationRole(ctx, field.ID, org.ID, admin.ID, domain.OrgRoleFinance); err != nil {
			t.Errorf("Yönetici Saha'nın rolünü değiştirebilmeli: %v", err)
		}
	})

	t.Run("Şifre değişince diğer oturumlar kapanır, bu cihazınki açık kalır", func(t *testing.T) {
		here, err := authSvc.Login(ctx, "uar_field", "GeciciSifre123!")
		if err != nil {
			t.Fatal(err)
		}
		other, err := authSvc.Login(ctx, "uar_field", "GeciciSifre123!")
		if err != nil {
			t.Fatal(err)
		}
		if err := userSvc.ChangeOwnPassword(ctx, field.ID, org.ID, "GeciciSifre123!", "YeniSifre456!", here.RefreshToken); err != nil {
			t.Fatal(err)
		}
		if _, err := authSvc.Refresh(ctx, other.RefreshToken); !errors.Is(err, domain.ErrInvalidToken) {
			t.Errorf("diğer cihazın oturumu kapanmalı: %v", err)
		}
		if _, err := authSvc.Refresh(ctx, here.RefreshToken); err != nil {
			t.Errorf("şifreyi değiştiren cihazın oturumu açık kalmalı: %v", err)
		}
	})

	t.Run("Yönetici sıfırlaması geçici şifre verir ve tüm oturumları kapatır", func(t *testing.T) {
		s, err := authSvc.Login(ctx, "uar_field", "YeniSifre456!")
		if err != nil {
			t.Fatal(err)
		}
		if err := userSvc.AdminResetPassword(ctx, field.ID, org.ID, admin.ID, "Gecici789!"); err != nil {
			t.Fatal(err)
		}
		if _, err := authSvc.Refresh(ctx, s.RefreshToken); !errors.Is(err, domain.ErrInvalidToken) {
			t.Errorf("sıfırlama sonrası eski oturum kapanmalı: %v", err)
		}
		u, err := userSvc.Get(ctx, field.ID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		if !u.MustChangePassword {
			t.Error("sıfırlanan şifre geçici olmalı (must_change_password)")
		}
	})

	t.Run("İlk şifre ucu yalnızca geçici şifreli kullanıcıya açık", func(t *testing.T) {
		if err := userSvc.SetInitialPassword(ctx, field.ID, org.ID, "KendiSifrem1!", ""); err != nil {
			t.Fatalf("geçici şifreli kullanıcı ilk şifresini belirleyebilmeli: %v", err)
		}
		if err := userSvc.SetInitialPassword(ctx, field.ID, org.ID, "BaskasininSifresi1!", ""); !errors.Is(err, domain.ErrInitialPasswordAlreadySet) {
			t.Errorf("bayrak kapanınca uç reddetmeli: %v", err)
		}
		if _, err := authSvc.Login(ctx, "uar_field", "KendiSifrem1!"); err != nil {
			t.Errorf("reddedilen istek şifreyi değiştirmemeli: %v", err)
		}
	})

	t.Run("Asgari şifre uzunluğu oluşturmada da geçerli", func(t *testing.T) {
		if _, _, err := userSvc.CreateMember(ctx, org.ID, owner.ID, "uar_short", "1234567", "Kısa", domain.OrgRoleField, service.PersonnelOptions{}); !errors.Is(err, domain.ErrPasswordTooShort) {
			t.Errorf("7 karakterlik şifre reddedilmeli: %v", err)
		}
	})

	t.Run("Pasifleştirme telefon kayıtlarını siler, pasif kullanıcıya push gitmez", func(t *testing.T) {
		const tok = "uar-field-device-token-0001"
		if err := pushSvc.RegisterDevice(ctx, org.ID, field.ID, tok, "android", "1.0"); err != nil {
			t.Fatal(err)
		}
		fid, _ := repository.StringToUUID(field.ID)
		if toks, _ := q.ListPushTokensForUser(ctx, fid); len(toks) != 1 {
			t.Fatalf("ön koşul: 1 cihaz, %d", len(toks))
		}
		// Kayıt kalsa bile pasif kullanıcıya gönderilmez.
		if _, err := pool.Exec(ctx, `UPDATE users SET is_active = false WHERE id = $1`, field.ID); err != nil {
			t.Fatal(err)
		}
		if toks, _ := q.ListPushTokensForUser(ctx, fid); len(toks) != 0 {
			t.Errorf("pasif kullanıcının cihazına gönderim listesi boş olmalı, %d", len(toks))
		}
		if _, err := pool.Exec(ctx, `UPDATE users SET is_active = true WHERE id = $1`, field.ID); err != nil {
			t.Fatal(err)
		}
		if err := userSvc.Deactivate(ctx, field.ID, org.ID, admin.ID); err != nil {
			t.Fatal(err)
		}
		var n int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM push_devices WHERE user_id = $1`, field.ID).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != 0 {
			t.Errorf("pasifleştirme cihaz kayıtlarını silmeli, %d kaldı", n)
		}
	})

	t.Run("İki Sahip aynı anda birbirini pasifleştiremez", func(t *testing.T) {
		owner2, _, err := userSvc.CreateMember(ctx, org.ID, owner.ID, "uar_owner2", "GeciciSifre123!", "İkinci Sahip", domain.OrgRoleOwner, service.PersonnelOptions{})
		if err != nil {
			t.Fatalf("Sahip ikinci Sahip'i açabilmeli: %v", err)
		}
		orgUUID, _ := repository.StringToUUID(org.ID)
		// Yarış penceresi dar: birkaç tur denenir (kilitsiz hâlde turların
		// birinde ikisi de "diğeri hâlâ aktif" görüp geçiyordu).
		for round := 0; round < 15; round++ {
			if _, err := pool.Exec(ctx, `UPDATE users SET is_active = true WHERE id = ANY($1::uuid[])`, []string{owner.ID, owner2.ID}); err != nil {
				t.Fatal(err)
			}
			var wg sync.WaitGroup
			errs := make([]error, 2)
			start := make(chan struct{})
			wg.Add(2)
			go func() {
				defer wg.Done()
				<-start
				errs[0] = userSvc.Deactivate(ctx, owner.ID, org.ID, owner2.ID)
			}()
			go func() {
				defer wg.Done()
				<-start
				errs[1] = userSvc.Deactivate(ctx, owner2.ID, org.ID, owner.ID)
			}()
			close(start)
			wg.Wait()
			ok, last := 0, 0
			for _, e := range errs {
				switch {
				case e == nil:
					ok++
				case errors.Is(e, domain.ErrLastOwner):
					last++
				default:
					t.Fatalf("tur %d: beklenmeyen hata: %v", round, e)
				}
			}
			active, err := q.CountActiveOwners(ctx, orgUUID)
			if err != nil {
				t.Fatal(err)
			}
			if ok != 1 || last != 1 || active != 1 {
				t.Fatalf("tur %d: biri başarılı, diğeri ErrLastOwner olmalı ve tam 1 aktif Sahip kalmalı: %v, aktif %d", round, errs, active)
			}
		}
	})

	t.Run("Rol izinleri tek seferde yazılır", func(t *testing.T) {
		roles, err := authzSvc.ListOrganizationRoles(ctx, org.ID, false)
		if err != nil {
			t.Fatal(err)
		}
		var fieldRoleID string
		for _, r := range roles {
			if r.Code == domain.OrgRoleField {
				fieldRoleID = r.ID
			}
		}
		want := []string{domain.PermAttendanceRead, domain.PermProjectsRead}
		got, err := authzSvc.SetRolePermissions(ctx, fieldRoleID, org.ID, want)
		if err != nil {
			t.Fatal(err)
		}
		again, err := authzSvc.GetOrganizationRole(ctx, fieldRoleID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		if len(got.Permissions) != 2 || len(again.Permissions) != 2 {
			t.Errorf("rol tam olarak 2 izinle kalmalı: %v / %v", got.Permissions, again.Permissions)
		}
		// Tanımsız kod: hiçbir şey silinmeden reddedilir.
		if _, err := authzSvc.SetRolePermissions(ctx, fieldRoleID, org.ID, []string{"yok.boyle.izin"}); !errors.Is(err, domain.ErrUnknownPermission) {
			t.Errorf("tanımsız izin reddedilmeli: %v", err)
		}
		if after, _ := authzSvc.GetOrganizationRole(ctx, fieldRoleID, org.ID); len(after.Permissions) != 2 {
			t.Errorf("reddedilen istek izinleri değiştirmemeli: %v", after.Permissions)
		}
	})
}
