package service_test

// UserService.Create'in organizationRoleCode dalı — tenant self-servis
// "Yeni Kullanıcı" HTTP ucunun (UserHandler.Create) dayandığı davranış.
// Bu, gerçek bir üretim hatasının regresyon testidir: bu parametre
// eklenmeden önce web'deki "Yeni Kullanıcı" formu yalnızca kaba bir `role`
// (admin/kullanici) gönderiyordu, organizasyon rolünü HİÇ sormuyordu --
// backend de bunu sessizce "legacy_user"a (migration-only, atama HEDEFİ
// olmayan bir rol) düşürüyordu. Bkz. UserService.Create yorumu.

import (
	"context"
	"errors"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestUserServiceCreateOrganizationRole(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	userSvc := service.NewUserService(pool, q)

	org := mustCreateOrg(t, ctx, orgSvc, pool, "UserSvcRole Org", "usersvc-role")
	// mustCreateOrg, düz OrganizationService.Create çağırır -- organization_roles
	// yalnızca PlatformService.CreateOrganizationWithOwner (gerçek Süper Admin
	// "Yeni Firma" akışı) tarafından seed edilir. Bu testin RBAC rol kodlarına
	// (field/admin/legacy_user) ihtiyacı var, bu yüzden aynı DB fonksiyonu
	// burada AÇIKÇA çağrılır (migration 0034, bkz. SeedSystemRolesForOrg).
	orgUUID, err := repository.StringToUUID(org.ID)
	if err != nil {
		t.Fatalf("org id: %v", err)
	}
	if err := q.SeedSystemRolesForOrg(ctx, orgUUID); err != nil {
		t.Fatalf("rol seed: %v", err)
	}

	t.Run("organizationRoleCode verilirse tam olarak o rol atanır, kaba rol ondan türetilir", func(t *testing.T) {
		u, err := userSvc.Create(ctx, org.ID, "usersvc_field", "GeciciSifre123!", "Saha Kullanıcı", domain.RoleKullanici, domain.OrgRoleField)
		if err != nil {
			t.Fatalf("beklenmedik hata: %v", err)
		}
		if u.OrganizationRoleCode != domain.OrgRoleField {
			t.Fatalf("organization_role_code = %q, beklenen %q", u.OrganizationRoleCode, domain.OrgRoleField)
		}
		if u.Role != domain.RoleKullanici {
			t.Fatalf("field rolü kaba users.role'ü 'kullanici' üretmeli, geldi: %q", u.Role)
		}
	})

	t.Run("organizationRoleCode=admin -> kaba rol admin'e türetilir", func(t *testing.T) {
		u, err := userSvc.Create(ctx, org.ID, "usersvc_admin", "GeciciSifre123!", "Yönetici Kullanıcı", domain.RoleKullanici, domain.OrgRoleAdmin)
		if err != nil {
			t.Fatalf("beklenmedik hata: %v", err)
		}
		if u.OrganizationRoleCode != domain.OrgRoleAdmin {
			t.Fatalf("organization_role_code = %q, beklenen %q", u.OrganizationRoleCode, domain.OrgRoleAdmin)
		}
		if u.Role != domain.RoleAdmin {
			t.Fatalf("admin rolü kaba users.role'ü 'admin' üretmeli, geldi: %q", u.Role)
		}
	})

	t.Run("organizationRoleCode=legacy_user KESİNLİKLE reddedilir (migration-only, atama hedefi değil)", func(t *testing.T) {
		_, err := userSvc.Create(ctx, org.ID, "usersvc_legacy_reject", "GeciciSifre123!", "Reddedilmeli", domain.RoleKullanici, domain.OrgRoleLegacyUser)
		if !errors.Is(err, domain.ErrRoleNotAssignable) {
			t.Fatalf("legacy_user REDDEDİLMELİ (ErrRoleNotAssignable), geldi: %v", err)
		}
	})

	t.Run("bilinmeyen organizationRoleCode -> ErrNotFound", func(t *testing.T) {
		_, err := userSvc.Create(ctx, org.ID, "usersvc_unknown_role", "GeciciSifre123!", "Bilinmeyen Rol", domain.RoleKullanici, "boyle-bir-rol-yok")
		if !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("bilinmeyen rol kodu ErrNotFound dönmeli, geldi: %v", err)
		}
	})

	t.Run("organizationRoleCode boş bırakılırsa ESKİ (bootstrap) varsayım zinciri KORUNUR", func(t *testing.T) {
		// cmd/api'nin SEED_ADMIN_* bootstrap yolu HÂLÂ bu şekilde çağırır
		// (organization_roles henüz seed edilmemiş olabileceği bir andır) --
		// bu dal DEĞİŞMEDİĞİNİ doğrular (regresyon koruması). NOT: bu ESKİ
		// dal (dokunulmadı) `Create()`'in döndürdüğü struct'ta
		// OrganizationRoleCode/-Name'i HİÇBİR ZAMAN doldurmaz (yalnızca DB'de
		// organization_role_id'yi ayarlar) -- bu yüzden burada kaba `Role`
		// alanı doğrulanır, DB'deki gerçek atama authzSvc.GetUserWithRole
		// ile (join yapan sorgu) ayrıca kontrol edilir.
		authzSvc := service.NewAuthorizationService(pool, q)

		uAdmin, err := userSvc.Create(ctx, org.ID, "usersvc_legacy_admin", "GeciciSifre123!", "Eski Admin", domain.RoleAdmin, "")
		if err != nil {
			t.Fatalf("beklenmedik hata: %v", err)
		}
		if uAdmin.Role != domain.RoleAdmin {
			t.Fatalf("role=admin + boş kod -> kaba Role 'admin' olmalı, geldi: %q", uAdmin.Role)
		}
		gotAdmin, err := authzSvc.GetUserWithRole(ctx, uAdmin.ID, org.ID)
		if err != nil {
			t.Fatalf("get: %v", err)
		}
		if gotAdmin.OrganizationRoleCode != domain.OrgRoleAdmin {
			t.Fatalf("role=admin + boş kod -> DB'de organization_role_code 'admin' olmalı, geldi: %q", gotAdmin.OrganizationRoleCode)
		}

		uKullanici, err := userSvc.Create(ctx, org.ID, "usersvc_legacy_kullanici", "GeciciSifre123!", "Eski Kullanıcı", domain.RoleKullanici, "")
		if err != nil {
			t.Fatalf("beklenmedik hata: %v", err)
		}
		gotKullanici, err := authzSvc.GetUserWithRole(ctx, uKullanici.ID, org.ID)
		if err != nil {
			t.Fatalf("get: %v", err)
		}
		if gotKullanici.OrganizationRoleCode != domain.OrgRoleLegacyUser {
			t.Fatalf("role=kullanici + boş kod -> DB'de organization_role_code 'legacy_user' olmalı (ESKİ davranış), geldi: %q", gotKullanici.OrganizationRoleCode)
		}
	})
}
