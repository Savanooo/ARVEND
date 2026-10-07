package service_test

// Yumuşak silme (soft-delete) -- kullanıcı VE firma. Gerçek PostgreSQL'e
// karşı (DB_URL yoksa atlanır, bkz. testDBURL). Kapsam: satırlar ASLA
// fiziksel DELETE ile kaldırılmaz (deleted_at/deleted_by), normal
// listelerden dışarıda kalır, giriş/oturum reddedilir, tarihçe (audit)
// kullanıcıyı/firmayı çözmeye devam eder, geri yükleme, son aktif Owner
// korumasının silme yoluna da uygulanması, ve kullanıcı adı yeniden
// kullanım davranışının açık tanımı.

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestSoftDeleteUser(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	platformSvc, userSvc := newPlatformTestServices(q, pool)
	authSvc := service.NewAuthService(q, auth.NewJWTIssuer("test-secret-sd", 15*time.Minute), 24*time.Hour)

	const slug = "platform-sd-firma"
	usernames := []string{"sd_owner_1", "sd_owner_2", "sd_field"}
	row := pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug)
	var existingID string
	if scanErr := row.Scan(&existingID); scanErr == nil {
		cleanupPlatformOrg(t, pool, existingID)
	}
	_, _ = pool.Exec(ctx, "DELETE FROM users WHERE username = ANY($1::text[])", usernames)

	created, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
		Name: "Platform SD Firma", Slug: slug,
		OwnerUsername: "sd_owner_1", OwnerPassword: "GecicSifre123!", OwnerFullName: "Birinci Sahip",
	})
	if err != nil {
		t.Fatalf("organizasyon+owner oluşturulamadı: %v", err)
	}
	org := created.Organization
	owner1 := created.Owner
	t.Cleanup(func() { cleanupPlatformOrg(t, pool, org.ID) })

	field, err := platformSvc.ProvisionOrganizationUser(ctx, service.ProvisionOrganizationUserInput{
		OrganizationID: org.ID, Username: "sd_field", FullName: "Saha Elemanı", TemporaryPassword: "GecicSifre123!", RoleCode: domain.OrgRoleField,
	})
	if err != nil {
		t.Fatalf("saha kullanıcısı oluşturulamadı: %v", err)
	}
	if _, err := authSvc.Login(ctx, "sd_field", "GecicSifre123!"); err != nil {
		t.Fatalf("saha ilk giriş: %v", err)
	}
	if err := userSvc.SetInitialPassword(ctx, field.ID, org.ID, "SabitSifre123!", ""); err != nil {
		t.Fatalf("saha şifre belirleme: %v", err)
	}

	t.Run("cannot_delete_last_active_owner", func(t *testing.T) {
		if err := platformSvc.DeleteOrganizationUser(ctx, org.ID, owner1.ID, ""); !errors.Is(err, domain.ErrLastOwner) {
			t.Fatalf("err = %v, want ErrLastOwner", err)
		}
		var stillThere bool
		if err := pool.QueryRow(ctx, "SELECT true FROM users WHERE id = $1 AND deleted_at IS NULL", owner1.ID).Scan(&stillThere); err != nil || !stillThere {
			t.Errorf("son owner yanlışlıkla silinmiş görünüyor (err=%v)", err)
		}
	})

	var owner2 *domain.User
	t.Run("second_owner_unlocks_deletion", func(t *testing.T) {
		owner2, err = platformSvc.ProvisionOrganizationUser(ctx, service.ProvisionOrganizationUserInput{
			OrganizationID: org.ID, Username: "sd_owner_2", FullName: "İkinci Sahip", TemporaryPassword: "GecicSifre123!", RoleCode: domain.OrgRoleOwner,
		})
		if err != nil {
			t.Fatalf("ikinci owner oluşturulamadı: %v", err)
		}
		if err := platformSvc.DeleteOrganizationUser(ctx, org.ID, owner1.ID, ""); err != nil {
			t.Fatalf("ikinci owner varken silme başarısız: %v", err)
		}
		if err := platformSvc.DeleteOrganizationUser(ctx, org.ID, owner1.ID, ""); !errors.Is(err, domain.ErrAlreadyDeleted) {
			t.Errorf("tekrar silme err = %v, want ErrAlreadyDeleted (idempotent-safe)", err)
		}
	})

	t.Run("deleted_user_row_is_preserved_not_hard_deleted", func(t *testing.T) {
		var exists bool
		var deletedAtSet, isActive bool
		row := pool.QueryRow(ctx, "SELECT true, deleted_at IS NOT NULL, is_active FROM users WHERE id = $1", owner1.ID)
		if err := row.Scan(&exists, &deletedAtSet, &isActive); err != nil {
			t.Fatalf("satır fiziksel olarak SİLİNMİŞ (beklenen: yumuşak silme): %v", err)
		}
		if !deletedAtSet {
			t.Errorf("deleted_at boş")
		}
		if isActive {
			t.Errorf("is_active = true, want false (silme deaktivasyonu da kapsar)")
		}
	})

	t.Run("deleted_user_disappears_from_normal_lists", func(t *testing.T) {
		list, err := platformSvc.ListOrganizationUsers(ctx, org.ID, 1, 50)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		for _, u := range list.Users {
			if u.ID == owner1.ID {
				t.Errorf("silinmiş kullanıcı normal listede göründü")
			}
		}
		tenantList, err := userSvc.List(ctx, org.ID, 1, 50)
		if err != nil {
			t.Fatalf("tenant listesi alınamadı: %v", err)
		}
		for _, u := range tenantList.Users {
			if u.ID == owner1.ID {
				t.Errorf("silinmiş kullanıcı tenant listesinde (paylaşılan sorgu) göründü")
			}
		}
	})

	t.Run("deleted_user_appears_in_archive_view", func(t *testing.T) {
		deleted, err := platformSvc.ListDeletedOrganizationUsers(ctx, org.ID, 1, 50)
		if err != nil {
			t.Fatalf("silinenler listesi alınamadı: %v", err)
		}
		found := false
		for _, u := range deleted.Users {
			if u.ID == owner1.ID {
				found = true
				if u.OrganizationRoleName == "" {
					t.Errorf("silinen kullanıcının organizasyon rolü Silinenler görünümünde kayboldu: %+v", u)
				}
			}
		}
		if !found {
			t.Errorf("silinmiş kullanıcı Silinenler görünümünde YOK: %+v", deleted.Users)
		}
	})

	t.Run("deleted_user_cannot_authenticate", func(t *testing.T) {
		if _, err := authSvc.Login(ctx, "sd_owner_1", "GecicSifre123!"); !errors.Is(err, domain.ErrInactiveUser) {
			t.Errorf("silinmiş kullanıcı login err = %v, want ErrInactiveUser", err)
		}
	})

	t.Run("existing_session_of_deleted_user_is_rejected", func(t *testing.T) {
		sess, err := authSvc.Login(ctx, "sd_field", "SabitSifre123!")
		if err != nil {
			t.Fatalf("saha login: %v", err)
		}
		if err := platformSvc.DeleteOrganizationUser(ctx, org.ID, field.ID, ""); err != nil {
			t.Fatalf("saha silinemedi: %v", err)
		}
		if _, err := authSvc.Refresh(ctx, sess.RefreshToken); err == nil {
			t.Errorf("silinen kullanıcının açık oturumu YENİLENEBİLDİ")
		}
	})

	t.Run("historical_references_still_resolve", func(t *testing.T) {
		events, err := platformSvc.ListAuditEvents(ctx, org.ID, 1, 100)
		if err != nil {
			t.Fatalf("audit alınamadı: %v", err)
		}
		found := false
		for _, e := range events {
			if e.Action == domain.AuditActionUserDeleted && e.TargetUserID != nil && *e.TargetUserID == owner1.ID {
				found = true
				if e.Metadata["username"] != "sd_owner_1" {
					t.Errorf("audit metadata'sı silinen kullanıcı adını kaybetti: %+v", e.Metadata)
				}
			}
		}
		if !found {
			t.Errorf("user_deleted audit kaydı bulunamadı/hedef kullanıcıyı çözemedi")
		}
		// GetUserByIDInOrg (tekil kayıt çözümü -- ör. restore/denetim
		// ekranı), silinmiş satırı da bulabilmeli (yalnızca LİSTELER
		// filtrelenir, bkz. queries/users.sql yorumu).
		fetched, err := userSvc.Get(ctx, owner1.ID, org.ID)
		if err != nil || fetched.Username != "sd_owner_1" {
			t.Errorf("silinmiş kullanıcının tekil kaydı çözülemedi: err=%v", err)
		}
	})

	t.Run("username_stays_reserved_after_delete", func(t *testing.T) {
		// Açık tanım: silinen bir kullanıcı adı KALICI OLARAK ayrılmış
		// kalır -- yeniden kullanılamaz (global UNIQUE kısıtı deleted_at'ten
		// bağımsızdır). Bu, tarihçe/denetim referanslarında ("bu işlemi
		// sd_owner_1 yaptı") ASLA bir belirsizlik oluşmamasını garanti eder.
		_, err := platformSvc.ProvisionOrganizationUser(ctx, service.ProvisionOrganizationUserInput{
			OrganizationID: org.ID, Username: "sd_owner_1", FullName: "Başka Biri", TemporaryPassword: "GecicSifre123!", RoleCode: domain.OrgRoleField,
		})
		if !errors.Is(err, domain.ErrDuplicateUsername) {
			t.Errorf("silinmiş kullanıcı adıyla yeniden oluşturma err = %v, want ErrDuplicateUsername", err)
		}
	})

	t.Run("cannot_reactivate_deleted_user_directly", func(t *testing.T) {
		if err := platformSvc.ReactivateOrganizationUser(ctx, org.ID, owner1.ID, ""); !errors.Is(err, domain.ErrUserDeleted) {
			t.Errorf("err = %v, want ErrUserDeleted (önce restore gerekir)", err)
		}
	})

	t.Run("restore_user", func(t *testing.T) {
		if err := platformSvc.RestoreOrganizationUser(ctx, org.ID, owner1.ID, ""); err != nil {
			t.Fatalf("restore başarısız: %v", err)
		}
		if err := platformSvc.RestoreOrganizationUser(ctx, org.ID, owner1.ID, ""); !errors.Is(err, domain.ErrNotDeleted) {
			t.Errorf("tekrar restore err = %v, want ErrNotDeleted", err)
		}
		list, err := platformSvc.ListOrganizationUsers(ctx, org.ID, 1, 50)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		var restored *domain.User
		for i := range list.Users {
			if list.Users[i].ID == owner1.ID {
				restored = &list.Users[i]
			}
		}
		if restored == nil {
			t.Fatalf("restore edilen kullanıcı normal listede YOK")
		}
		if restored.IsActive {
			t.Errorf("restore sonrası is_active = true, want false (restore aktifleştirmez, bkz. restoreUser yorumu)")
		}
		if _, err := authSvc.Login(ctx, "sd_owner_1", "GecicSifre123!"); !errors.Is(err, domain.ErrInactiveUser) {
			t.Errorf("restore-ama-hâlâ-pasif kullanıcı login err = %v, want ErrInactiveUser", err)
		}
		if err := platformSvc.ReactivateOrganizationUser(ctx, org.ID, owner1.ID, ""); err != nil {
			t.Fatalf("restore sonrası ayrı aktifleştirme başarısız: %v", err)
		}
		if _, err := authSvc.Login(ctx, "sd_owner_1", "GecicSifre123!"); err != nil {
			t.Errorf("restore+aktifleştirme sonrası login başarısız: %v", err)
		}
	})

	t.Run("cannot_demote_last_active_owner_via_delete_after_restore", func(t *testing.T) {
		// owner2 şu an tek aktif Sahip (owner1 restore edildi ama field
		// rolünde değil, owner1 Sahip -- iki aktif Sahip olabilir; bu alt
		// testte owner2'yi tek Sahip konumuna getirip silmeyi dener.
		if _, err := platformSvc.SetOrganizationUserRole(ctx, org.ID, owner1.ID, domain.OrgRoleField, ""); err != nil {
			t.Fatalf("owner1 düşürülemedi: %v", err)
		}
		if err := platformSvc.DeleteOrganizationUser(ctx, org.ID, owner2.ID, ""); !errors.Is(err, domain.ErrLastOwner) {
			t.Errorf("son owner2 silme err = %v, want ErrLastOwner", err)
		}
	})
}

func TestSoftDeleteOrganization(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	platformSvc, _ := newPlatformTestServices(q, pool)
	authSvc := service.NewAuthService(q, auth.NewJWTIssuer("test-secret-sdorg", 15*time.Minute), 24*time.Hour)

	const slug = "platform-sd-org"
	row := pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug)
	var existingID string
	if scanErr := row.Scan(&existingID); scanErr == nil {
		cleanupPlatformOrg(t, pool, existingID)
	}
	_, _ = pool.Exec(ctx, "DELETE FROM users WHERE username = $1", "sdorg_owner")

	created, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
		Name: "Platform SD Org Firma", Slug: slug,
		OwnerUsername: "sdorg_owner", OwnerPassword: "GecicSifre123!", OwnerFullName: "Org Sahibi",
	})
	if err != nil {
		t.Fatalf("organizasyon+owner oluşturulamadı: %v", err)
	}
	org := created.Organization
	t.Cleanup(func() { cleanupPlatformOrg(t, pool, org.ID) })

	t.Run("org_admin_cannot_call_platform_delete_endpoint", func(t *testing.T) {
		// Bu invariant HTTP katmanında (RequireRole(super_admin), bkz.
		// platform_isolation_test.go) zaten doğrulanmıştır -- burada servis
		// katmanının KENDİSİNİN organizasyon kimliğini HER ZAMAN açıkça
		// aldığını (bir "çağıran kimin organizasyonu" çıkarımı OLMADIĞINI)
		// doğrular: yanlış bir organizationID ile çağrı ErrNotFound döner,
		// asla "çağıranın kendi firması" gibi bir varsayılana düşmez.
		if err := platformSvc.DeleteOrganization(ctx, "00000000-0000-0000-0000-000000000000", ""); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("var olmayan org id err = %v, want ErrNotFound", err)
		}
	})

	t.Run("soft_delete_organization", func(t *testing.T) {
		if err := platformSvc.DeleteOrganization(ctx, org.ID, ""); err != nil {
			t.Fatalf("firma silinemedi: %v", err)
		}
		if err := platformSvc.DeleteOrganization(ctx, org.ID, ""); !errors.Is(err, domain.ErrAlreadyDeleted) {
			t.Errorf("tekrar silme err = %v, want ErrAlreadyDeleted", err)
		}
	})

	t.Run("organization_data_remains_in_db_with_status_preserved", func(t *testing.T) {
		var deletedAtSet bool
		var status string
		row := pool.QueryRow(ctx, "SELECT deleted_at IS NOT NULL, status FROM organizations WHERE id = $1", org.ID)
		if err := row.Scan(&deletedAtSet, &status); err != nil {
			t.Fatalf("firma satırı fiziksel olarak SİLİNMİŞ (beklenen: yumuşak silme): %v", err)
		}
		if !deletedAtSet {
			t.Errorf("deleted_at boş")
		}
		if status != string(domain.OrgStatusActive) {
			t.Errorf("status = %q, want active (silme status'e DOKUNMAMALI)", status)
		}
		var userCount int
		if err := pool.QueryRow(ctx, "SELECT count(*) FROM users WHERE organization_id = $1", org.ID).Scan(&userCount); err != nil || userCount != 1 {
			t.Errorf("firma kullanıcıları korunmadı: n=%d err=%v", userCount, err)
		}
	})

	t.Run("deleted_organization_disappears_from_normal_platform_list", func(t *testing.T) {
		list, err := platformSvc.ListOrganizations(ctx, "", 1, 200)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		for _, o := range list.Organizations {
			if o.ID == org.ID {
				t.Errorf("silinmiş firma normal listede (status='') göründü")
			}
		}
		listActive, err := platformSvc.ListOrganizations(ctx, "active", 1, 200)
		if err != nil {
			t.Fatalf("aktif liste alınamadı: %v", err)
		}
		for _, o := range listActive.Organizations {
			if o.ID == org.ID {
				t.Errorf("silinmiş firma status='active' filtresinde göründü")
			}
		}
	})

	t.Run("deleted_organization_appears_in_archive_view", func(t *testing.T) {
		deleted, err := platformSvc.ListDeletedOrganizations(ctx, 1, 200)
		if err != nil {
			t.Fatalf("silinenler listesi alınamadı: %v", err)
		}
		found := false
		for _, o := range deleted.Organizations {
			if o.ID == org.ID {
				found = true
			}
		}
		if !found {
			t.Errorf("silinmiş firma Silinenler görünümünde YOK")
		}
	})

	t.Run("deleted_organization_tenant_access_is_rejected", func(t *testing.T) {
		if _, err := authSvc.Login(ctx, "sdorg_owner", "GecicSifre123!"); !errors.Is(err, domain.ErrOrganizationSuspended) {
			t.Errorf("silinmiş firma login err = %v, want ErrOrganizationSuspended", err)
		}
	})

	t.Run("mutations_rejected_while_deleted", func(t *testing.T) {
		if _, err := platformSvc.UpdatePlan(ctx, org.ID, "", "pro"); !errors.Is(err, domain.ErrOrganizationDeleted) {
			t.Errorf("plan güncelleme err = %v, want ErrOrganizationDeleted", err)
		}
		if _, err := platformSvc.SetStatus(ctx, org.ID, "", domain.OrgStatusSuspended); !errors.Is(err, domain.ErrOrganizationDeleted) {
			t.Errorf("durum değiştirme err = %v, want ErrOrganizationDeleted", err)
		}
	})

	t.Run("restore_organization", func(t *testing.T) {
		if err := platformSvc.RestoreOrganization(ctx, org.ID, ""); err != nil {
			t.Fatalf("restore başarısız: %v", err)
		}
		if err := platformSvc.RestoreOrganization(ctx, org.ID, ""); !errors.Is(err, domain.ErrNotDeleted) {
			t.Errorf("tekrar restore err = %v, want ErrNotDeleted", err)
		}
		list, err := platformSvc.ListOrganizations(ctx, "", 1, 200)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		found := false
		for _, o := range list.Organizations {
			if o.ID == org.ID {
				found = true
			}
		}
		if !found {
			t.Errorf("restore edilen firma normal listede YOK")
		}
		if _, err := authSvc.Login(ctx, "sdorg_owner", "GecicSifre123!"); err != nil {
			t.Errorf("restore sonrası login başarısız: %v", err)
		}
	})

	events, err := platformSvc.ListAuditEvents(ctx, org.ID, 1, 100)
	if err != nil {
		t.Fatalf("audit alınamadı: %v", err)
	}
	var sawDeleted, sawRestored bool
	for _, e := range events {
		if e.Action == domain.AuditActionOrganizationDeleted {
			sawDeleted = true
		}
		if e.Action == domain.AuditActionOrganizationRestored {
			sawRestored = true
		}
	}
	if !sawDeleted || !sawRestored {
		t.Errorf("platform audit trail eksik: deleted=%v restored=%v", sawDeleted, sawRestored)
	}
}
