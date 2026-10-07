package middleware_test

// Kullanıcının GÜNCEL durumu (pasif/silinmiş, düşürülmüş rol, geri alınmış
// firma ayarı izni) hâlâ geçerli bir access token'la gelen isteklerde de
// uygulanmalı -- token 15 dakika yaşıyor ve rolü içinde taşıyor.

import (
	"context"
	"net/http"
	"slices"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestUserGateUsesCurrentUserRow(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "user-gate-http")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	orgID := org.Organization.ID

	t.Run("pasifleştirilen kullanıcı token'ı dolmadan 401 alır", func(t *testing.T) {
		field, token := mustCreateRoleUser(t, ctx, d, orgID, "gate_field", domain.OrgRoleField)
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/attendance?month=2026-09", token, ""); rec.Code != http.StatusOK {
			t.Fatalf("ön koşul: aktifken 200, geldi %d", rec.Code)
		}
		if _, err := d.pool.Exec(ctx, `UPDATE users SET is_active = false WHERE id = $1`, field.ID); err != nil {
			t.Fatal(err)
		}
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/attendance?month=2026-09", token, "")
		if rec.Code != http.StatusUnauthorized || body["code"] != "user_inactive" {
			t.Fatalf("pasif kullanıcı 401 user_inactive almalı, geldi %d %v", rec.Code, body)
		}
		// requireOnboarded almayan rotalar da (cihaz kaydı) keser.
		rec, _ = rbacDo(t, d.router, http.MethodPost, "/api/v1/push/devices/", token, `{"token":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}`)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("pasif kullanıcı cihaz kaydedememeli, geldi %d", rec.Code)
		}
	})

	t.Run("silinen kullanıcı 401 alır", func(t *testing.T) {
		u, token := mustCreateRoleUser(t, ctx, d, orgID, "gate_deleted", domain.OrgRoleField)
		if _, err := d.pool.Exec(ctx, `UPDATE users SET deleted_at = now() WHERE id = $1`, u.ID); err != nil {
			t.Fatal(err)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/attendance?month=2026-09", token, ""); rec.Code != http.StatusUnauthorized {
			t.Fatalf("silinen kullanıcı 401 almalı, geldi %d", rec.Code)
		}
	})

	t.Run("rolü düşürülen Yönetici, token'ında admin yazsa da yönetim uçlarına giremez", func(t *testing.T) {
		admin, _ := mustCreateRoleUser(t, ctx, d, orgID, "gate_admin_demoted", domain.OrgRoleAdmin)
		adminToken, err := d.issuer.IssueAccessToken(admin.ID, domain.RoleAdmin, orgID)
		if err != nil {
			t.Fatal(err)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/users/", adminToken, ""); rec.Code != http.StatusOK {
			t.Fatalf("ön koşul: Yönetici kullanıcı listesini görmeli, geldi %d", rec.Code)
		}
		if _, err := d.authzSvc.SetUserOrganizationRole(ctx, admin.ID, orgID, org.Owner.ID, domain.OrgRoleField); err != nil {
			t.Fatal(err)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/users/", adminToken, ""); rec.Code != http.StatusForbidden {
			t.Fatalf("rolü düşürülen kişi 403 almalı (token'daki eski rol değil), geldi %d", rec.Code)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/organization/settings/", adminToken, ""); rec.Code != http.StatusForbidden {
			t.Fatalf("firma ayarları da (requireOnboarded'sız rota) 403 olmalı, geldi %d", rec.Code)
		}
	})

	t.Run("firma ayarı izni geri alınan Yönetici ayarları değiştiremez", func(t *testing.T) {
		admin, token := mustCreateRoleUser(t, ctx, d, orgID, "gate_admin_noperm", domain.OrgRoleAdmin)
		detail, err := d.authzSvc.GetUserPermissionDetail(ctx, admin.ID, orgID)
		if err != nil {
			t.Fatal(err)
		}
		desired := slices.DeleteFunc(slices.Clone(detail.Effective), func(p string) bool {
			return p == domain.PermOrganizationSettingsManage
		})
		if _, err := d.authzSvc.SetUserPermissions(ctx, admin.ID, orgID, org.Owner.ID, desired); err != nil {
			t.Fatal(err)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/organization/settings/", token, ""); rec.Code != http.StatusOK {
			t.Fatalf("okuma izni duruyor, 200 beklendi, geldi %d", rec.Code)
		}
		for _, path := range []string{"/api/v1/organization/settings/company", "/api/v1/onboarding/company"} {
			rec, body := rbacDo(t, d.router, http.MethodPut, path, token, `{"company_name":"Ele Geçirildi"}`)
			if rec.Code != http.StatusForbidden || body["code"] != "permission_denied" {
				t.Fatalf("%s: 403 permission_denied beklendi, geldi %d %v", path, rec.Code, body)
			}
		}
	})

	t.Run("yeni firmanın Sahibi sihirbazı hâlâ kullanabilir", func(t *testing.T) {
		fresh, err := d.platform.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
			Name: "Gate Taze Firma", Slug: "user-gate-fresh",
			OwnerUsername: "owner_user_gate_fresh", OwnerPassword: "GeciciSifre123!", OwnerFullName: "Taze Sahip",
		})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { rbacCleanupOrg(t, d.pool, fresh.Organization.ID) })
		token, err := d.issuer.IssueAccessToken(fresh.Owner.ID, domain.RoleAdmin, fresh.Organization.ID)
		if err != nil {
			t.Fatal(err)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/onboarding/", token, ""); rec.Code != http.StatusOK {
			t.Fatalf("Sahip sihirbaza girebilmeli, geldi %d %s", rec.Code, rec.Body.String())
		}
	})
}
