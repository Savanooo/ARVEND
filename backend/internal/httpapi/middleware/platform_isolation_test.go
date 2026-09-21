package middleware_test

// Platform (super_admin) ile tenant (organizasyon) eksenlerinin GERÇEK
// router üzerinde birbirinden tamamen yalıtıldığını doğrular -- require_
// permission_test.go'daki AYNI real-DB harness (setupRBACTestRouter).
// Kapsanan garantiler:
//   - super_admin HİÇBİR tenant ucuna giremez (403 tenant_context_required),
//     izin/üyelik kontrolünü "bypass" edemez, bir organizasyon uydurulmaz;
//   - super_admin /platform/* uçlarına erişmeye devam eder;
//   - organizasyon Owner'ı (users.role='admin' + org rolü 'owner' -- legacy
//     admin'in migration 0034 sonrası tam şekli) ve project_manager HİÇBİR
//     /platform/* ucuna giremez;
//   - tenant kullanıcılarının mevcut erişimi (Owner tam, PM kısıtlı) BOZULMAZ.

import (
	"context"
	"net/http"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

func TestPlatformTenantIsolation(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "platform-isolation-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, org.Organization.ID)
	if err != nil {
		t.Fatalf("owner token üretilemedi: %v", err)
	}
	_, pmToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "iso_pm", domain.OrgRoleProjectManager)
	superToken, err := d.issuer.IssueAccessToken("00000000-0000-0000-0000-0000000000ee", domain.RoleSuperAdmin, "")
	if err != nil {
		t.Fatalf("super admin token üretilemedi: %v", err)
	}
	project := mustCreateProject(t, ctx, d, org.Organization.ID, "İzolasyon Projesi")

	tenantEndpoints := []struct{ method, path string }{
		{http.MethodGet, "/api/v1/offers/"},
		{http.MethodGet, "/api/v1/projects/"},
		{http.MethodGet, "/api/v1/projects/" + project.ID},
		{http.MethodGet, "/api/v1/projects/" + project.ID + "/tasks"},
		{http.MethodGet, "/api/v1/projects/" + project.ID + "/financial-summary"},
		{http.MethodGet, "/api/v1/tasks/mine"},
		{http.MethodGet, "/api/v1/customers/"},
		{http.MethodGet, "/api/v1/employees/"},
		{http.MethodGet, "/api/v1/attendance/"},
		{http.MethodGet, "/api/v1/products/"},
		{http.MethodGet, "/api/v1/calculations/groups"},
		{http.MethodGet, "/api/v1/notifications/"},
		{http.MethodGet, "/api/v1/organization/cost-codes/"},
		{http.MethodGet, "/api/v1/organization/suppliers/"},
		{http.MethodGet, "/api/v1/organization/roles"},
		{http.MethodGet, "/api/v1/organization/permissions"},
		{http.MethodGet, "/api/v1/organization/settings"},
		{http.MethodGet, "/api/v1/onboarding"},
		{http.MethodGet, "/api/v1/settings/smtp"},
		{http.MethodGet, "/api/v1/users"},
		{http.MethodPost, "/api/v1/users/me/set-initial-password"},
		{http.MethodPatch, "/api/v1/users/me/password"},
	}
	platformEndpoints := []string{
		"/api/v1/platform/plans",
		"/api/v1/platform/organizations",
		"/api/v1/platform/organizations/" + org.Organization.ID,
		"/api/v1/platform/organizations/" + org.Organization.ID + "/users",
		"/api/v1/platform/organizations/" + org.Organization.ID + "/audit-events",
	}

	t.Run("super_admin_denied_on_every_tenant_endpoint", func(t *testing.T) {
		for _, ep := range tenantEndpoints {
			rec, body := rbacDo(t, d.router, ep.method, ep.path, superToken, "")
			if rec.Code != http.StatusForbidden {
				t.Errorf("%s %s: status = %d, want 403", ep.method, ep.path, rec.Code)
				continue
			}
			if body["code"] != "tenant_context_required" {
				t.Errorf("%s %s: code = %v, want tenant_context_required", ep.method, ep.path, body["code"])
			}
		}
	})

	t.Run("super_admin_allowed_on_platform_endpoints", func(t *testing.T) {
		for _, path := range platformEndpoints {
			rec, _ := rbacDo(t, d.router, http.MethodGet, path, superToken, "")
			if rec.Code != http.StatusOK {
				t.Errorf("GET %s: status = %d, want 200", path, rec.Code)
			}
		}
	})

	t.Run("organization_owner_denied_on_platform_endpoints", func(t *testing.T) {
		for _, path := range platformEndpoints {
			rec, _ := rbacDo(t, d.router, http.MethodGet, path, ownerToken, "")
			if rec.Code != http.StatusForbidden {
				t.Errorf("GET %s: status = %d, want 403 (owner platform yöneticisi DEĞİLDİR)", path, rec.Code)
			}
		}
		rec, _ := rbacDo(t, d.router, http.MethodPost, "/api/v1/platform/organizations", ownerToken,
			`{"name":"X","slug":"x-owner-attempt","owner_username":"x","owner_password":"GeciciSifre123!","owner_full_name":"X"}`)
		if rec.Code != http.StatusForbidden {
			t.Errorf("POST /platform/organizations: status = %d, want 403", rec.Code)
		}
	})

	t.Run("project_manager_denied_on_platform_endpoints", func(t *testing.T) {
		for _, path := range platformEndpoints {
			rec, _ := rbacDo(t, d.router, http.MethodGet, path, pmToken, "")
			if rec.Code != http.StatusForbidden {
				t.Errorf("GET %s: status = %d, want 403", path, rec.Code)
			}
		}
	})

	t.Run("organization_owner_tenant_access_intact", func(t *testing.T) {
		for _, path := range []string{
			"/api/v1/offers/",
			"/api/v1/projects/",
			"/api/v1/projects/" + project.ID,
			"/api/v1/users",
			"/api/v1/organization/settings",
		} {
			rec, _ := rbacDo(t, d.router, http.MethodGet, path, ownerToken, "")
			if rec.Code != http.StatusOK {
				t.Errorf("GET %s: status = %d, want 200 (owner'ın tenant erişimi bozulmamalı)", path, rec.Code)
			}
		}
	})

	t.Run("project_manager_receives_only_permitted_tenant_access", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/", pmToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("GET /projects/: status = %d, want 200 (projects.read izni var)", rec.Code)
		}
		rec, _ = rbacDo(t, d.router, http.MethodGet, "/api/v1/users", pmToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("GET /users: status = %d, want 403 (requireAdmin + organization.users.read yok)", rec.Code)
		}
		rec, _ = rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+project.ID+"/financial-summary", pmToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("GET financial-summary: status = %d, want 403 (finance.read yok)", rec.Code)
		}
	})

	t.Run("legacy_admin_shape_is_a_tenant_owner_not_a_platform_account", func(t *testing.T) {
		// Migration 0034 sonrası legacy "admin": users.role='admin', org rolü
		// 'owner', organization_id DOLU -- yani bir TENANT hesabı. /auth/me
		// bunu böyle raporlamalı ve /platform/* ona kapalı kalmalı.
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/auth/me", ownerToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("/auth/me status = %d, want 200", rec.Code)
		}
		if body["role"] != string(domain.RoleAdmin) {
			t.Errorf("role = %v, want admin", body["role"])
		}
		if body["organization_role_code"] != domain.OrgRoleOwner {
			t.Errorf("organization_role_code = %v, want owner", body["organization_role_code"])
		}
		if body["organization_id"] == nil || body["organization_id"] == "" {
			t.Errorf("organization_id boş -- tenant hesabında dolu olmalı")
		}
	})
}
