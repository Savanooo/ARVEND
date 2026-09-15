package middleware_test

// Bu dosya, Super Admin/organization Admin ayrımının VE askıya alma
// (suspend) uygulamasının gerçekten HTTP sınırında (middleware) uygulandığını
// doğrular -- gerçek bir PostgreSQL bağlantısı gerektirir (DB_URL), yoksa
// atlanır. İki güvenlik garantisini kapsar:
//  1. "platform authorization/403": bir organization admin'in /platform/*
//     rotalarına (requireSuperAdmin) ERİŞEMEMESİ, VE bunun tam tersi -- bir
//     Super Admin'in normal requireAdmin rotalarına da erişememesi (ikisi
//     mutually exclusive, "SUPER ADMIN ile ORGANIZATION ADMIN kesinlikle
//     aynı şey değildir").
//  2. "suspend blocks access": zaten geçerli (süresi dolmamış) bir access
//     token'la gelen bir isteğin, firma askıya alındıktan SONRA hemen
//     reddedilmesi -- yalnızca yeni login/refresh'in değil.

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/joho/godotenv"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	appmw "github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func testDBURL(t *testing.T) string {
	t.Helper()
	_ = godotenv.Load("../../../.env")
	url := os.Getenv("DB_URL")
	if url == "" {
		t.Skip("DB_URL ayarlanmamış -- middleware entegrasyon testi gerçek bir PostgreSQL bağlantısı gerektirir, atlanıyor")
	}
	return url
}

func cleanupTestOrg(t *testing.T, pool *pgxpool.Pool, orgID string) {
	t.Helper()
	ctx := context.Background()
	for _, stmt := range []string{
		"DELETE FROM users WHERE organization_id = $1",
		"DELETE FROM organizations WHERE id = $1",
	} {
		if _, err := pool.Exec(ctx, stmt, orgID); err != nil {
			t.Logf("temizlik uyarısı (%s): %v", stmt, err)
		}
	}
}

// chain, RequireAuth ile ardından bir RequireRole'ü (verilirse) zincirler
// ve zincirin sonuna 200 dönen basit bir handler koyar -- gerçek router.go
// wiring'inin bire bir aynısı (bkz. router.go: requireAuth := ...;
// requireAdmin := appmw.RequireRole(...)).
func chain(issuer *auth.JWTIssuer, q *sqlc.Queries, role domain.Role) http.Handler {
	final := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	var h http.Handler = final
	if role != "" {
		h = appmw.RequireRole(role)(h)
	}
	return appmw.RequireAuth(issuer, q)(h)
}

func doRequest(t *testing.T, h http.Handler, cookieValue string) int {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	if cookieValue != "" {
		req.AddCookie(&http.Cookie{Name: "access_token", Value: cookieValue})
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec.Code
}

func TestRequireAuth_PlatformVsOrganizationSeparation(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)

	orgSvc := service.NewOrganizationService(q)
	org, err := orgSvc.Create(ctx, "Middleware Test Firma", "middleware-test-firma-auth")
	if err != nil {
		// Önceki bir çalışmadan kalıntı olabilir.
		row := pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", "middleware-test-firma-auth")
		var existingID string
		if scanErr := row.Scan(&existingID); scanErr == nil {
			cleanupTestOrg(t, pool, existingID)
		}
		org, err = orgSvc.Create(ctx, "Middleware Test Firma", "middleware-test-firma-auth")
		if err != nil {
			t.Fatalf("test organizasyonu oluşturulamadı: %v", err)
		}
	}
	t.Cleanup(func() { cleanupTestOrg(t, pool, org.ID) })

	issuer := auth.NewJWTIssuer("test-secret-middleware", 15*time.Minute)
	adminToken, err := issuer.IssueAccessToken("00000000-0000-0000-0000-0000000000aa", domain.RoleAdmin, org.ID)
	if err != nil {
		t.Fatalf("admin token üretilemedi: %v", err)
	}
	superAdminToken, err := issuer.IssueAccessToken("00000000-0000-0000-0000-0000000000bb", domain.RoleSuperAdmin, "")
	if err != nil {
		t.Fatalf("super admin token üretilemedi: %v", err)
	}

	t.Run("no cookie -> 401", func(t *testing.T) {
		h := chain(issuer, q, domain.RoleSuperAdmin)
		if code := doRequest(t, h, ""); code != http.StatusUnauthorized {
			t.Errorf("status = %d, want 401", code)
		}
	})

	t.Run("malformed token -> 401", func(t *testing.T) {
		h := chain(issuer, q, "")
		if code := doRequest(t, h, "garbage-not-a-jwt"); code != http.StatusUnauthorized {
			t.Errorf("status = %d, want 401", code)
		}
	})

	t.Run("org admin cannot reach requireSuperAdmin route", func(t *testing.T) {
		h := chain(issuer, q, domain.RoleSuperAdmin)
		if code := doRequest(t, h, adminToken); code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (org admin /platform/* rotasına erişemez)", code)
		}
	})

	t.Run("super admin cannot reach requireAdmin (org-scoped) route", func(t *testing.T) {
		h := chain(issuer, q, domain.RoleAdmin)
		if code := doRequest(t, h, superAdminToken); code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (Super Admin normal organization admin rotasına erişemez)", code)
		}
	})

	t.Run("super admin reaches requireSuperAdmin route", func(t *testing.T) {
		h := chain(issuer, q, domain.RoleSuperAdmin)
		if code := doRequest(t, h, superAdminToken); code != http.StatusOK {
			t.Errorf("status = %d, want 200", code)
		}
	})

	t.Run("org admin reaches requireAdmin route (own org, active)", func(t *testing.T) {
		h := chain(issuer, q, domain.RoleAdmin)
		if code := doRequest(t, h, adminToken); code != http.StatusOK {
			t.Errorf("status = %d, want 200 (aktif firma, geçerli admin token)", code)
		}
	})
}

func TestRequireAuth_SuspendBlocksMidSessionAccess(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)

	orgSvc := service.NewOrganizationService(q)
	userSvc := service.NewUserService(q)
	calcSvc := service.NewCalcService(q)
	productSvc := service.NewProductService(q)
	platformSvc := service.NewPlatformService(pool, q, userSvc, calcSvc, productSvc)

	org, err := orgSvc.Create(ctx, "Middleware Suspend Test Firma", "middleware-test-firma-suspend")
	if err != nil {
		row := pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", "middleware-test-firma-suspend")
		var existingID string
		if scanErr := row.Scan(&existingID); scanErr == nil {
			cleanupTestOrg(t, pool, existingID)
		}
		org, err = orgSvc.Create(ctx, "Middleware Suspend Test Firma", "middleware-test-firma-suspend")
		if err != nil {
			t.Fatalf("test organizasyonu oluşturulamadı: %v", err)
		}
	}
	t.Cleanup(func() { cleanupTestOrg(t, pool, org.ID) })

	issuer := auth.NewJWTIssuer("test-secret-suspend", 15*time.Minute)
	// Token, firma HÂLÂ aktifken üretiliyor -- tıpkı gerçek dünyada olduğu
	// gibi: kullanıcı zaten oturum açmış, elinde geçerli (süresi dolmamış)
	// bir access token var.
	token, err := issuer.IssueAccessToken("00000000-0000-0000-0000-0000000000cc", domain.RoleAdmin, org.ID)
	if err != nil {
		t.Fatalf("token üretilemedi: %v", err)
	}
	h := chain(issuer, q, "")

	if code := doRequest(t, h, token); code != http.StatusOK {
		t.Fatalf("askıya almadan ÖNCE status = %d, want 200", code)
	}

	if _, err := platformSvc.SetStatus(ctx, org.ID, "", domain.OrgStatusSuspended); err != nil {
		t.Fatalf("firma askıya alınamadı: %v", err)
	}

	if code := doRequest(t, h, token); code != http.StatusForbidden {
		t.Errorf("askıya aldıktan SONRA (AYNI, hâlâ süresi dolmamış token ile) status = %d, want 403 -- mid-session erişim engellenmedi", code)
	}

	// Yeniden aktive edilince erişim geri gelmeli (aynı token, yeni bir
	// login/refresh gerekmeden).
	if _, err := platformSvc.SetStatus(ctx, org.ID, "", domain.OrgStatusActive); err != nil {
		t.Fatalf("firma yeniden aktive edilemedi: %v", err)
	}
	if code := doRequest(t, h, token); code != http.StatusOK {
		t.Errorf("yeniden aktive ettikten SONRA status = %d, want 200", code)
	}
}
