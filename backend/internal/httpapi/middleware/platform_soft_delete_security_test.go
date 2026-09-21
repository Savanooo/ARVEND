package middleware_test

// Yumuşak silme (soft-delete) uçlarının GERÇEK router üzerindeki yetki
// sınırı -- setupRBACTestRouter harness'i (require_permission_test.go).
// Kapsam: organizasyon Owner'ı hiçbir silme/geri-yükleme ucunu çağıramaz
// (403); super_admin firma+kullanıcı siler/geri yükler, son aktif Owner
// 409 ile korunur, HTTP DELETE metodu asla kullanılmaz (yalnızca POST
// eylem-fiilleri), ve ürün kaynak ağacında users/organizations tabloları
// için fiziksel bir SQL DELETE ifadesi yoktur.

import (
	"context"
	"net/http"
	"os/exec"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

func TestPlatformSoftDeleteSecurity(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "platform-sd-http-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	orgID := org.Organization.ID
	owner1 := org.Owner
	base := "/api/v1/platform/organizations/" + orgID

	ownerToken, err := d.issuer.IssueAccessToken(owner1.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatalf("owner token: %v", err)
	}
	_, _ = d.pool.Exec(ctx, "DELETE FROM users WHERE username = $1", "sd_http_superadmin")
	superAdmin, err := d.platform.CreateSuperAdmin(ctx, "sd_http_superadmin", "SuperGizli123!", "Test Platform Yöneticisi")
	if err != nil {
		t.Fatalf("test super admin oluşturulamadı: %v", err)
	}
	t.Cleanup(func() {
		_, _ = d.pool.Exec(ctx, "DELETE FROM platform_audit_events WHERE actor_user_id = $1", superAdmin.ID)
		_, _ = d.pool.Exec(ctx, "DELETE FROM refresh_tokens WHERE user_id = $1", superAdmin.ID)
		_, _ = d.pool.Exec(ctx, "DELETE FROM users WHERE id = $1", superAdmin.ID)
	})
	superToken, err := d.issuer.IssueAccessToken(superAdmin.ID, domain.RoleSuperAdmin, "")
	if err != nil {
		t.Fatalf("super token: %v", err)
	}

	t.Run("organization_owner_cannot_call_any_delete_or_restore_endpoint", func(t *testing.T) {
		for _, ep := range []struct{ method, path, body string }{
			{http.MethodPost, base + "/users/" + owner1.ID + "/delete", ""},
			{http.MethodPost, base + "/users/" + owner1.ID + "/restore", ""},
			{http.MethodPost, base + "/delete", ""},
			{http.MethodPost, base + "/restore", ""},
			{http.MethodGet, "/api/v1/platform/organizations?status=deleted", ""},
			{http.MethodGet, base + "/users?view=deleted", ""},
		} {
			rec, _ := rbacDo(t, d.router, ep.method, ep.path, ownerToken, ep.body)
			if rec.Code != http.StatusForbidden {
				t.Errorf("%s %s: status = %d, want 403 (owner platform yöneticisi değildir)", ep.method, ep.path, rec.Code)
			}
		}
	})

	// Owner1 bu noktada HÂLÂ firmanın TEK aktif Sahibidir -- ikinci Sahip
	// AŞAĞIDA, bu kontrolden SONRA provision edilir (sıra bilinçli: aksi
	// halde son-Sahip koruması hiç TETİKLENMEZ).
	t.Run("last_active_owner_cannot_be_deleted", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, base+"/users/"+owner1.ID+"/delete", superToken, "")
		if rec.Code != http.StatusConflict {
			t.Fatalf("status = %d, want 409 (son aktif Sahip -- body=%v)", rec.Code, body)
		}
	})

	var secondOwnerID string
	var owner2Token string
	t.Run("super_admin_provisions_second_owner_for_delete_tests", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, base+"/users", superToken,
			`{"username":"sd_http_owner_2","full_name":"İkinci Sahip","temporary_password":"GeciciSifre123!","organization_role_code":"owner"}`)
		if rec.Code != http.StatusCreated {
			t.Fatalf("status = %d, want 201 (body=%v)", rec.Code, body)
		}
		secondOwnerID, _ = body["id"].(string)
		var err error
		owner2Token, err = d.issuer.IssueAccessToken(secondOwnerID, domain.RoleAdmin, orgID)
		if err != nil {
			t.Fatalf("owner2 token: %v", err)
		}
		// Gerçek ilk-giriş akışını izler (firma silinmeden ÖNCE, aksi
		// halde RequireAuth'un organizasyon-durumu kontrolü bu uca bile
		// hiç ulaştırmaz) ki sonraki alt testte RequireOnboarded'ın
		// must_change_password kapısına takılmadan business ucuna
		// (offers) erişim denenebilsin.
		rec, _ = rbacDo(t, d.router, http.MethodPost, "/api/v1/users/me/set-initial-password", owner2Token, `{"new_password":"KaliciSifre123!"}`)
		if rec.Code != http.StatusOK {
			t.Fatalf("owner2 ilk şifre belirleme: status = %d", rec.Code)
		}
	})

	t.Run("super_admin_deletes_and_restores_user", func(t *testing.T) {
		// Artık iki Sahip var -- owner1 silinebilir.
		rec, _ := rbacDo(t, d.router, http.MethodPost, base+"/users/"+owner1.ID+"/delete", superToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("delete: status = %d, want 200", rec.Code)
		}
		rec, _ = rbacDo(t, d.router, http.MethodGet, base+"/users", superToken, "")
		_, body := rbacDo(t, d.router, http.MethodGet, base+"/users", superToken, "")
		users, _ := body["users"].([]any)
		for _, raw := range users {
			u := raw.(map[string]any)
			if u["id"] == owner1.ID {
				t.Errorf("silinen kullanıcı normal listede hâlâ görünüyor")
			}
		}
		rec, body = rbacDo(t, d.router, http.MethodGet, base+"/users?view=deleted", superToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("silinenler listesi: status = %d, want 200", rec.Code)
		}
		deletedUsers, _ := body["users"].([]any)
		found := false
		for _, raw := range deletedUsers {
			u := raw.(map[string]any)
			if u["id"] == owner1.ID {
				found = true
				if u["deleted_at"] == nil || u["deleted_at"] == "" {
					t.Errorf("silinenler görünümünde deleted_at boş: %+v", u)
				}
			}
		}
		if !found {
			t.Errorf("silinen kullanıcı Silinenler görünümünde yok")
		}

		rec, _ = rbacDo(t, d.router, http.MethodPost, base+"/users/"+owner1.ID+"/restore", superToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("restore: status = %d, want 200", rec.Code)
		}
		_, body = rbacDo(t, d.router, http.MethodGet, base+"/users", superToken, "")
		users, _ = body["users"].([]any)
		found = false
		for _, raw := range users {
			if raw.(map[string]any)["id"] == owner1.ID {
				found = true
			}
		}
		if !found {
			t.Errorf("restore edilen kullanıcı normal listede yok")
		}
	})

	t.Run("super_admin_deletes_and_restores_organization", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodPost, base+"/delete", superToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("delete: status = %d, want 200", rec.Code)
		}
		_, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/platform/organizations?status=&limit=200", superToken, "")
		orgs, _ := body["organizations"].([]any)
		for _, raw := range orgs {
			if raw.(map[string]any)["id"] == orgID {
				t.Errorf("silinen firma normal firmalar listesinde hâlâ görünüyor")
			}
		}
		_, body = rbacDo(t, d.router, http.MethodGet, "/api/v1/platform/organizations?status=deleted&limit=200", superToken, "")
		orgs, _ = body["organizations"].([]any)
		found := false
		for _, raw := range orgs {
			o := raw.(map[string]any)
			if o["id"] == orgID {
				found = true
				if o["status"] != "active" {
					t.Errorf("silinen firmanın status'ü değişti: %v (want active, korunmalı)", o["status"])
				}
			}
		}
		if !found {
			t.Errorf("silinen firma Silinenler görünümünde yok")
		}

		// İkinci Sahip ile giriş -- firma silinmişken erişim reddedilmeli
		// (owner2Token zaten onboarded, bkz. provisions_second_owner alt
		// testi).
		rec, _ = rbacDo(t, d.router, http.MethodGet, "/api/v1/offers/", owner2Token, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("silinen firma mid-session erişim: status = %d, want 403", rec.Code)
		}

		rec, _ = rbacDo(t, d.router, http.MethodPost, base+"/restore", superToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("restore: status = %d, want 200", rec.Code)
		}
		rec, _ = rbacDo(t, d.router, http.MethodGet, "/api/v1/offers/", owner2Token, "")
		if rec.Code != http.StatusOK {
			t.Errorf("restore sonrası erişim: status = %d, want 200", rec.Code)
		}
	})
}

// TestNoHardDeleteStatementsForUsersOrOrganizations, ÜRÜN kaynak ağacında
// (backend/internal, backend/db/migrations, backend/cmd -- *_test.go
// HARİÇ: test dosyalarının kendi fixture/cleanup'ı gerçek DB'de ephemeral
// test satırları oluşturup siler, bu KOD İNCELEMESİ o meşru, mevcut
// desene DOKUNMAZ, bkz. örn. tenant_isolation_test.go cleanupOrganization)
// users/organizations tabloları için fiziksel bir "DELETE FROM
// users"/"DELETE FROM organizations" SQL ifadesinin YOK olduğunu doğrular
// -- statik bir kaynak taraması, gerçek DB gerektirmez, DB_URL'den
// BAĞIMSIZ her zaman çalışır.
func TestNoHardDeleteStatementsForUsersOrOrganizations(t *testing.T) {
	root := "../../../.." // internal/httpapi/middleware -> backend
	out, err := exec.Command("grep", "-rniE", "--include=*.go", "--include=*.sql",
		`DELETE\s+FROM\s+(users|organizations)\b`,
		root+"/internal", root+"/db/migrations", root+"/cmd").CombinedOutput()
	lines := []string{}
	for _, l := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if l == "" || strings.Contains(l, "_test.go:") {
			continue
		}
		lines = append(lines, l)
	}
	if len(lines) > 0 {
		t.Fatalf("ÜRÜN kodunda users/organizations üzerinde fiziksel DELETE ifadesi bulundu:\n%s", strings.Join(lines, "\n"))
	}
	// exec.Command grep exit code 1 = eşleşme yok (beklenen); >1 gerçek hata.
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); !ok || exitErr.ExitCode() != 1 {
			t.Fatalf("grep taraması başarısız: %v (out=%s)", err, out)
		}
	}
}
