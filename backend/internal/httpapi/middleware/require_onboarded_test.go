package middleware_test

// Bu dosya, chore(auth): enforce first-login and onboarding gates
// server-side değişikliğini doğrular -- gerçek bir PostgreSQL bağlantısı
// gerektirir (DB_URL), yoksa atlanır. Amaç: müşteri redirect'lerini
// (web/mobil) atlayıp doğrudan API'ye istek atsa bile (ör. curl), geçici
// şifresini değiştirmemiş veya onboarding'ini tamamlamamış bir organization
// kullanıcısının "business" verisine (offers/projects/...) erişememesi --
// yalnızca client-side yönlendirme güvenliğine güvenilmemesi.
//
// chain()/auth_test.go'daki testlerden BİLİNÇLİ OLARAK ayrı tutulur: o
// dosyanın chain() yardımcısı requireOnboarded İÇERMEZ, çünkü o testler
// rol ayrımını doğrular ve varsayılan (onboarding_completed=false) test
// organizasyonlarıyla çalışır -- oraya requireOnboarded eklemek o
// testlerin anlamını bozardı.

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	appmw "github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// chainOnboarded, RequireAuth + RequireOnboarded'ı zincirler -- router.go'daki
// business route gruplarının (offers/projects/products/...) gerçek
// wiring'inin aynısı.
func chainOnboarded(issuer *auth.JWTIssuer, q *sqlc.Queries) http.Handler {
	final := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	h := appmw.RequireOnboarded(q)(final)
	return appmw.RequireAuth(issuer, q)(h)
}

// chainAuthOnly, router.go'daki /onboarding ve /organization/settings
// route gruplarının gerçek wiring'idir -- requireOnboarded YOK, yalnızca
// requireAuth+requireAdmin.
func chainAuthOnly(issuer *auth.JWTIssuer, q *sqlc.Queries) http.Handler {
	final := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	return appmw.RequireAuth(issuer, q)(appmw.RequireRole(domain.RoleAdmin)(final))
}

// cleanupOnboardedTestOrg, cleanupTestOrg'un (auth_test.go) aynısı ama AYRICA
// CreateOrganizationWithOwner'ın otomatik provision ettiği satırları da
// temizler (calc_recipe_items/calc_categories/calc_groups -- organization_id'ye
// CASCADE'siz/RESTRICT FK taşır, organizations satırından ÖNCE silinmeli --
// ve organization_profile/organization_commercial_settings/platform_audit_events).
func cleanupOnboardedTestOrg(t *testing.T, pool *pgxpool.Pool, orgID string) {
	t.Helper()
	ctx := context.Background()
	for _, stmt := range []string{
		"DELETE FROM calc_recipe_items WHERE organization_id = $1",
		"DELETE FROM calc_categories WHERE organization_id = $1",
		"DELETE FROM calc_groups WHERE organization_id = $1",
		"DELETE FROM organization_profile WHERE organization_id = $1",
		"DELETE FROM organization_commercial_settings WHERE organization_id = $1",
		"DELETE FROM platform_audit_events WHERE target_organization_id = $1",
		// RBAC/Project Membership sprint'i (migration 0034):
		// CreateOrganizationWithOwner artık organization_roles'u seed edip
		// Owner'ı bağlıyor -- organizations SİLİNMEDEN ÖNCE bu satırlar
		// (ve onlara referans veren users.organization_role_id) temizlenmeli.
		"DELETE FROM role_permissions WHERE organization_role_id IN (SELECT id FROM organization_roles WHERE organization_id = $1)",
		"UPDATE users SET organization_role_id = NULL WHERE organization_id = $1",
		"DELETE FROM organization_roles WHERE organization_id = $1",
	} {
		if _, err := pool.Exec(ctx, stmt, orgID); err != nil {
			t.Logf("temizlik uyarısı (%s): %v", stmt, err)
		}
	}
	cleanupTestOrg(t, pool, orgID)
}

func mustCreateOrgWithOwner(t *testing.T, ctx context.Context, platformSvc *service.PlatformService, pool *pgxpool.Pool, slug string) *service.CreateOrganizationResult {
	t.Helper()
	row := pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug)
	var existingID string
	if scanErr := row.Scan(&existingID); scanErr == nil {
		cleanupOnboardedTestOrg(t, pool, existingID)
	}
	result, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
		Name: "Onboarded Gate Test " + slug, Slug: slug,
		OwnerUsername: "owner_" + slug, OwnerPassword: "GeciciSifre123!", OwnerFullName: "Gate Test Owner",
	})
	if err != nil {
		t.Fatalf("test organizasyonu+owner oluşturulamadı: %v", err)
	}
	return result
}

func TestRequireOnboarded_BusinessEndpointGate(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)

	userSvc := service.NewUserService(q)
	calcSvc := service.NewCalcService(q)
	productSvc := service.NewProductService(q)
	platformSvc := service.NewPlatformService(pool, q, userSvc, calcSvc, productSvc)

	issuer := auth.NewJWTIssuer("test-secret-onboarded-gate", 15*time.Minute)

	t.Run("must_change_password=true -> business endpoint 403", func(t *testing.T) {
		result := mustCreateOrgWithOwner(t, ctx, platformSvc, pool, "onboarded-gate-mcp")
		t.Cleanup(func() { cleanupOnboardedTestOrg(t, pool, result.Organization.ID) })
		// Owner'ı onboarding_completed=true yap ki YALNIZCA must_change_password
		// izole edilmiş olsun.
		if _, err := pool.Exec(ctx, "UPDATE organizations SET onboarding_completed = true WHERE id = $1", result.Organization.ID); err != nil {
			t.Fatalf("onboarding_completed güncellenemedi: %v", err)
		}
		token, err := issuer.IssueAccessToken(result.Owner.ID, domain.RoleAdmin, result.Organization.ID)
		if err != nil {
			t.Fatalf("token üretilemedi: %v", err)
		}
		h := chainOnboarded(issuer, q)
		if code := doRequest(t, h, token); code != http.StatusForbidden {
			t.Errorf("must_change_password=true status = %d, want 403", code)
		}
	})

	t.Run("onboarding_completed=false -> business endpoint 403", func(t *testing.T) {
		result := mustCreateOrgWithOwner(t, ctx, platformSvc, pool, "onboarded-gate-incomplete")
		t.Cleanup(func() { cleanupOnboardedTestOrg(t, pool, result.Organization.ID) })
		// must_change_password'ü temizle ki YALNIZCA onboarding izole olsun.
		if err := userSvc.SetInitialPassword(ctx, result.Owner.ID, result.Organization.ID, "YeniSifre123!"); err != nil {
			t.Fatalf("must_change_password temizlenemedi: %v", err)
		}
		token, err := issuer.IssueAccessToken(result.Owner.ID, domain.RoleAdmin, result.Organization.ID)
		if err != nil {
			t.Fatalf("token üretilemedi: %v", err)
		}
		h := chainOnboarded(issuer, q)
		if code := doRequest(t, h, token); code != http.StatusForbidden {
			t.Errorf("onboarding_completed=false status = %d, want 403", code)
		}
	})

	t.Run("onboarding uçları requireOnboarded almaz -- her iki koşul da eksikken bile erişilebilir", func(t *testing.T) {
		result := mustCreateOrgWithOwner(t, ctx, platformSvc, pool, "onboarded-gate-bypass")
		t.Cleanup(func() { cleanupOnboardedTestOrg(t, pool, result.Organization.ID) })
		// Bu organizasyon HEM must_change_password=true HEM onboarding_completed
		// =false ile taze oluşturuldu (varsayılan) -- tam olarak /onboarding
		// rotasının hizmet etmesi gereken durum.
		token, err := issuer.IssueAccessToken(result.Owner.ID, domain.RoleAdmin, result.Organization.ID)
		if err != nil {
			t.Fatalf("token üretilemedi: %v", err)
		}
		h := chainAuthOnly(issuer, q)
		if code := doRequest(t, h, token); code != http.StatusOK {
			t.Errorf("onboarding endpoint (requireOnboarded'sız zincir) status = %d, want 200", code)
		}
	})

	t.Run("must_change_password=false + onboarding_completed=true -> normal erişim", func(t *testing.T) {
		result := mustCreateOrgWithOwner(t, ctx, platformSvc, pool, "onboarded-gate-complete")
		t.Cleanup(func() { cleanupOnboardedTestOrg(t, pool, result.Organization.ID) })
		if err := userSvc.SetInitialPassword(ctx, result.Owner.ID, result.Organization.ID, "YeniSifre123!"); err != nil {
			t.Fatalf("must_change_password temizlenemedi: %v", err)
		}
		if _, err := pool.Exec(ctx, "UPDATE organizations SET onboarding_completed = true WHERE id = $1", result.Organization.ID); err != nil {
			t.Fatalf("onboarding_completed güncellenemedi: %v", err)
		}
		token, err := issuer.IssueAccessToken(result.Owner.ID, domain.RoleAdmin, result.Organization.ID)
		if err != nil {
			t.Fatalf("token üretilemedi: %v", err)
		}
		h := chainOnboarded(issuer, q)
		if code := doRequest(t, h, token); code != http.StatusOK {
			t.Errorf("tam erişim status = %d, want 200", code)
		}
	})

	t.Run("super_admin gate'ten muaf", func(t *testing.T) {
		superAdminToken, err := issuer.IssueAccessToken("00000000-0000-0000-0000-0000000000dd", domain.RoleSuperAdmin, "")
		if err != nil {
			t.Fatalf("token üretilemedi: %v", err)
		}
		h := chainOnboarded(issuer, q)
		if code := doRequest(t, h, superAdminToken); code != http.StatusOK {
			t.Errorf("super_admin status = %d, want 200 (gate'ten muaf)", code)
		}
	})

	t.Run("mevcut Arvend Yapı kullanıcısı etkilenmez", func(t *testing.T) {
		var userID string
		row := pool.QueryRow(ctx, "SELECT id FROM users WHERE organization_id = $1 AND role = 'admin' LIMIT 1", domain.DefaultOrganizationID)
		if err := row.Scan(&userID); err != nil {
			t.Skipf("Arvend Yapı admin kullanıcısı bulunamadı, atlanıyor: %v", err)
		}
		token, err := issuer.IssueAccessToken(userID, domain.RoleAdmin, domain.DefaultOrganizationID)
		if err != nil {
			t.Fatalf("token üretilemedi: %v", err)
		}
		h := chainOnboarded(issuer, q)
		if code := doRequest(t, h, token); code != http.StatusOK {
			t.Errorf("Arvend Yapı admin status = %d, want 200 (must_change_password=false, onboarding_completed=true olmalı)", code)
		}
	})
}
