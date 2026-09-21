package middleware_test

// Bu dosya DB GEREKTİRMEZ: super_admin token'ının org claim'i boş olduğu
// için RequireAuth DB'ye hiç gitmez (nil *sqlc.Queries güvenlidir) ve her
// tenant katmanı, herhangi bir sorguya ULAŞMADAN ÖNCE platform hesabını
// reddetmek zorundadır -- nil bağımlılıklarla çalışabilmesi bunun kanıtıdır.
// Org kullanıcılarının gerçek router üzerindeki davranışı için bkz.
// platform_isolation_test.go.

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	appmw "github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
)

func tenantDo(h http.Handler, cookieValue string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	if cookieValue != "" {
		req.AddCookie(&http.Cookie{Name: "access_token", Value: cookieValue})
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestRequireTenant_PlatformAccountRejectedByEveryTenantLayer(t *testing.T) {
	issuer := auth.NewJWTIssuer("test-secret-tenant", 15*time.Minute)
	superToken, err := issuer.IssueAccessToken("00000000-0000-0000-0000-0000000000ee", domain.RoleSuperAdmin, "")
	if err != nil {
		t.Fatalf("super admin token üretilemedi: %v", err)
	}
	okHandler := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })

	layers := map[string]func(http.Handler) http.Handler{
		"RequireTenant":            appmw.RequireTenant(),
		"RequireOnboarded":         appmw.RequireOnboarded(nil),
		"LoadAuthorization":        appmw.LoadAuthorization(nil),
		"RequirePermission":        appmw.RequirePermission(domain.PermOffersRead),
		"RequireProjectPermission": appmw.RequireProjectPermission(nil, domain.PermProjectsRead),
	}
	for name, layer := range layers {
		t.Run(name+"_rejects_super_admin", func(t *testing.T) {
			h := appmw.RequireAuth(issuer, nil)(layer(okHandler))
			rec := tenantDo(h, superToken)
			if rec.Code != http.StatusForbidden {
				t.Fatalf("status = %d, want 403", rec.Code)
			}
			if !strings.Contains(rec.Body.String(), "tenant_context_required") {
				t.Errorf("body = %q, want code tenant_context_required", rec.Body.String())
			}
		})
	}

	t.Run("super_admin_still_reaches_requireSuperAdmin", func(t *testing.T) {
		h := appmw.RequireAuth(issuer, nil)(appmw.RequireRole(domain.RoleSuperAdmin)(okHandler))
		if rec := tenantDo(h, superToken); rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (platform rotası super_admin'e açık kalmalı)", rec.Code)
		}
	})

	t.Run("no_auth_context_is_denied_by_default", func(t *testing.T) {
		h := appmw.RequireTenant()(okHandler)
		if rec := tenantDo(h, ""); rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (auth context'i yokken de reddedilmeli)", rec.Code)
		}
	})
}
