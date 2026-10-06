package service_test

// Bu dosya, ARVEND — SUPER ADMIN + FİRMA/MAĞAZA YÖNETİMİ fazının
// PlatformService'ini gerçek bir PostgreSQL bağlantısına karşı doğrular
// (DB_URL yoksa atlanır, bkz. tenant_isolation_test.go'daki testDBURL).
// Kapsam: atomik firma+owner oluşturma (başarısızlıkta TAM rollback),
// suspend/activate + audit trail, ve Metraj Hesaplama kataloğu
// provizyonunun idempotentliği (aynı organizasyonda ikinci çalıştırma
// hiçbir şey oluşturmamalı).

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func newPlatformTestServices(q *sqlc.Queries, pool *pgxpool.Pool) (*service.PlatformService, *service.UserService) {
	userSvc := service.NewUserService(pool, q)
	calcSvc := service.NewCalcService(q)
	productSvc := service.NewProductService(q)
	return service.NewPlatformService(pool, q, userSvc, calcSvc, productSvc), userSvc
}

// cleanupPlatformOrg, cleanupOrganization'ı (tenant_isolation_test.go)
// çağırmadan ÖNCE PlatformService.CreateOrganizationWithOwner'ın
// oluşturduğu ek satırları (audit events, calc_* provizyonu -- ikisi de
// cleanupOrganization'da zaten ele alınıyor calc_* için, ama audit events
// AYRICA silinmeli çünkü organizations FK'sı ON DELETE SET NULL'dır ve
// immutability trigger'ı [migration 0033] bu SET NULL'a izin verse de satır
// GERİYE kalır -- test veritabanını temiz tutmak için açıkça siliyoruz).
func cleanupPlatformOrg(t *testing.T, pool *pgxpool.Pool, orgID string) {
	t.Helper()
	ctx := context.Background()
	if _, err := pool.Exec(ctx, "DELETE FROM platform_audit_events WHERE target_organization_id = $1", orgID); err != nil {
		t.Logf("audit temizlik uyarısı: %v", err)
	}
	cleanupOrganization(t, pool, orgID)
}

func TestPlatformService_CreateOrganizationWithOwner(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	platformSvc, userSvc := newPlatformTestServices(q, pool)

	t.Run("success: atomic org+owner, must_change_password, catalog provisioned, audit written", func(t *testing.T) {
		row := pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", "platform-test-firma-basari")
		var existingID string
		if scanErr := row.Scan(&existingID); scanErr == nil {
			cleanupPlatformOrg(t, pool, existingID)
		}
		_, _ = pool.Exec(ctx, "DELETE FROM users WHERE username = $1", "platform_test_owner_basari")

		result, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
			Name: "Platform Test Firma Başarı", Slug: "platform-test-firma-basari",
			OwnerUsername: "platform_test_owner_basari", OwnerPassword: "GecicSifre123!", OwnerFullName: "İlk Owner",
		})
		if err != nil {
			t.Fatalf("organizasyon+owner oluşturulamadı: %v", err)
		}
		t.Cleanup(func() { cleanupPlatformOrg(t, pool, result.Organization.ID) })

		if result.Organization.Status != domain.OrgStatusActive {
			t.Errorf("status = %q, want active (varsayılan)", result.Organization.Status)
		}
		if result.Organization.PlanCode != "trial" {
			t.Errorf("plan_code = %q, want trial (varsayılan)", result.Organization.PlanCode)
		}
		if result.Owner.Role != domain.RoleAdmin {
			t.Errorf("owner rolü = %q, want admin", result.Owner.Role)
		}
		if !result.Owner.MustChangePassword {
			t.Errorf("owner must_change_password = false, want true (Super Admin provisioning her zaman true set etmeli)")
		}
		if result.Owner.OrganizationID == nil || *result.Owner.OrganizationID != result.Organization.ID {
			t.Errorf("owner organization_id yanlış veya nil")
		}
		if result.CalcCatalog == nil {
			t.Fatalf("calc catalog provisioning sonucu nil -- best-effort adım çalışmadı")
		}
		if result.CalcCatalog.GroupsCreated == 0 || result.CalcCatalog.CategoriesCreated == 0 || result.CalcCatalog.ItemsCreated == 0 {
			t.Errorf("calc catalog provisioning beklenenden az satır oluşturdu: %+v", result.CalcCatalog)
		}

		// Owner gerçekten DB'de var mı ve doğru organizasyona bağlı mı.
		fetched, err := userSvc.Get(ctx, result.Owner.ID, result.Organization.ID)
		if err != nil {
			t.Fatalf("owner DB'den okunamadı: %v", err)
		}
		if fetched.Username != "platform_test_owner_basari" {
			t.Errorf("kullanıcı adı = %q", fetched.Username)
		}

		events, err := platformSvc.ListAuditEvents(ctx, result.Organization.ID, 1, 10)
		if err != nil {
			t.Fatalf("audit events okunamadı: %v", err)
		}
		found := false
		for _, e := range events {
			if e.Action == domain.AuditActionOrganizationCreated {
				found = true
			}
		}
		if !found {
			t.Errorf("organization_created audit kaydı bulunamadı: %+v", events)
		}
	})

	t.Run("duplicate slug: rollback leaves no partial user row", func(t *testing.T) {
		row := pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", "platform-test-firma-cakisma")
		var existingID string
		if scanErr := row.Scan(&existingID); scanErr == nil {
			cleanupPlatformOrg(t, pool, existingID)
		}
		_, _ = pool.Exec(ctx, "DELETE FROM users WHERE username IN ($1, $2)", "platform_test_owner_cakisma_1", "platform_test_owner_cakisma_2")

		first, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
			Name: "Platform Test Firma Çakışma", Slug: "platform-test-firma-cakisma",
			OwnerUsername: "platform_test_owner_cakisma_1", OwnerPassword: "GecicSifre123!", OwnerFullName: "İlk Owner",
		})
		if err != nil {
			t.Fatalf("ilk organizasyon oluşturulamadı: %v", err)
		}
		t.Cleanup(func() { cleanupPlatformOrg(t, pool, first.Organization.ID) })

		_, err = platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
			Name: "Aynı Slug İkinci Deneme", Slug: "platform-test-firma-cakisma", // AYNI slug -> unique violation
			OwnerUsername: "platform_test_owner_cakisma_2", OwnerPassword: "GecicSifre123!", OwnerFullName: "İkinci Owner",
		})
		if err == nil {
			t.Fatalf("çakışan slug'la ikinci organizasyon oluşturulabildi, hata bekleniyordu")
		}

		// Rollback gerçekten atomik mi: "cakisma_2" kullanıcı adı DB'de
		// OLMAMALI (transaction'ın user INSERT'i de geri alınmış olmalı).
		var count int64
		if scanErr := pool.QueryRow(ctx, "SELECT count(*) FROM users WHERE username = $1", "platform_test_owner_cakisma_2").Scan(&count); scanErr != nil {
			t.Fatalf("kontrol sorgusu başarısız: %v", scanErr)
		}
		if count != 0 {
			t.Errorf("başarısız organizasyon oluşturma sonrası owner kullanıcı satırı DB'de KALDI (rollback atomik değil): count=%d", count)
		}
	})

	t.Run("duplicate owner username across organizations: rollback leaves no partial organization row", func(t *testing.T) {
		row := pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", "platform-test-firma-kullanici-cakisma-1")
		var existingID string
		if scanErr := row.Scan(&existingID); scanErr == nil {
			cleanupPlatformOrg(t, pool, existingID)
		}
		row2 := pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", "platform-test-firma-kullanici-cakisma-2")
		if scanErr := row2.Scan(&existingID); scanErr == nil {
			cleanupPlatformOrg(t, pool, existingID)
		}
		_, _ = pool.Exec(ctx, "DELETE FROM users WHERE username = $1", "platform_test_owner_ortak")

		first, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
			Name: "Kullanıcı Çakışma Firma 1", Slug: "platform-test-firma-kullanici-cakisma-1",
			OwnerUsername: "platform_test_owner_ortak", OwnerPassword: "GecicSifre123!", OwnerFullName: "Ortak Owner",
		})
		if err != nil {
			t.Fatalf("ilk organizasyon oluşturulamadı: %v", err)
		}
		t.Cleanup(func() { cleanupPlatformOrg(t, pool, first.Organization.ID) })

		_, err = platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
			Name: "Kullanıcı Çakışma Firma 2", Slug: "platform-test-firma-kullanici-cakisma-2",
			OwnerUsername: "platform_test_owner_ortak", OwnerPassword: "GecicSifre123!", OwnerFullName: "Ortak Owner 2",
		})
		if !errors.Is(err, domain.ErrDuplicateUsername) {
			t.Fatalf("err = %v, want ErrDuplicateUsername", err)
		}

		var count int64
		if scanErr := pool.QueryRow(ctx, "SELECT count(*) FROM organizations WHERE slug = $1", "platform-test-firma-kullanici-cakisma-2").Scan(&count); scanErr != nil {
			t.Fatalf("kontrol sorgusu başarısız: %v", scanErr)
		}
		if count != 0 {
			t.Errorf("başarısız organizasyon oluşturma sonrası organizasyon satırı DB'de KALDI (rollback atomik değil): count=%d", count)
		}
	})
}

func TestPlatformService_SetStatusAndAudit(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	platformSvc, _ := newPlatformTestServices(q, pool)
	orgSvc := service.NewOrganizationService(q)

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Platform Test Suspend Firma", "platform-test-suspend-firma")

	updated, err := platformSvc.SetStatus(ctx, org.ID, "", domain.OrgStatusSuspended)
	if err != nil {
		t.Fatalf("askıya alma başarısız: %v", err)
	}
	if updated.Status != domain.OrgStatusSuspended || updated.IsActive {
		t.Errorf("status=%q is_active=%v, want suspended/false", updated.Status, updated.IsActive)
	}

	updated, err = platformSvc.SetStatus(ctx, org.ID, "", domain.OrgStatusActive)
	if err != nil {
		t.Fatalf("yeniden aktive etme başarısız: %v", err)
	}
	if updated.Status != domain.OrgStatusActive || !updated.IsActive {
		t.Errorf("status=%q is_active=%v, want active/true", updated.Status, updated.IsActive)
	}

	events, err := platformSvc.ListAuditEvents(ctx, org.ID, 1, 10)
	if err != nil {
		t.Fatalf("audit events okunamadı: %v", err)
	}
	var sawSuspend, sawActivate bool
	for _, e := range events {
		if e.Action == domain.AuditActionOrganizationSuspended {
			sawSuspend = true
		}
		if e.Action == domain.AuditActionOrganizationActivated {
			sawActivate = true
		}
	}
	if !sawSuspend || !sawActivate {
		t.Errorf("audit trail eksik: sawSuspend=%v sawActivate=%v, events=%+v", sawSuspend, sawActivate, events)
	}

	t.Cleanup(func() { cleanupPlatformOrg(t, pool, org.ID) })
}

// TestPlatformService_CalcCatalogProvisioningIdempotency, "provisioning
// idempotency" gereksinimidir -- AYNI organizasyonda ikinci bir
// reprovision çağrısı hiçbir yeni satır oluşturmamalı (hepsi "zaten var,
// atla").
func TestPlatformService_CalcCatalogProvisioningIdempotency(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	platformSvc, _ := newPlatformTestServices(q, pool)
	orgSvc := service.NewOrganizationService(q)

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Platform Test İdempotent Katalog Firma", "platform-test-idempotent-katalog")
	t.Cleanup(func() { cleanupPlatformOrg(t, pool, org.ID) })

	first, err := platformSvc.ReprovisionCalcCatalog(ctx, org.ID, "", false)
	if err != nil {
		t.Fatalf("ilk provisioning başarısız: %v", err)
	}
	if first.GroupsCreated == 0 || first.CategoriesCreated == 0 || first.ItemsCreated == 0 {
		t.Fatalf("ilk çalıştırma beklenenden az satır oluşturdu: %+v", first)
	}
	if first.ItemsFailed != 0 {
		t.Errorf("ilk çalıştırmada %d kalem başarısız oldu, 0 bekleniyordu: %+v", first.ItemsFailed, first)
	}

	second, err := platformSvc.ReprovisionCalcCatalog(ctx, org.ID, "", false)
	if err != nil {
		t.Fatalf("ikinci (idempotent) provisioning başarısız: %v", err)
	}
	if second.GroupsCreated != 0 || second.CategoriesCreated != 0 || second.ItemsCreated != 0 {
		t.Errorf("ikinci çalıştırma YENİ satır oluşturdu (idempotent değil): %+v", second)
	}
	if second.GroupsSkipped != first.GroupsCreated || second.CategoriesSkipped != first.CategoriesCreated || second.ItemsSkipped != first.ItemsCreated {
		t.Errorf("ikinci çalıştırmanın atlanan sayıları ilkinin oluşturulan sayılarıyla eşleşmiyor: first=%+v second=%+v", first, second)
	}
}
