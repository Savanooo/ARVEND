package middleware_test

// Süper Admin firma kullanıcı yönetimi + yaşam döngüsü uçlarının GERÇEK
// router üzerindeki yetki sınırı (setupRBACTestRouter harness'i):
//   - super_admin listeler/yönetir; organizasyon Owner'ı bu uçların HİÇBİRİNİ
//     çağıramaz (403);
//   - son aktif Owner pasifleştirilemez/düşürülemez (409), ikinci Owner kısıtı
//     kaldırır; pasifleştirme satırı korur;
//   - genel "admin" kullanıcı adı ve legacy_user reddedilir (400);
//   - iptal/askı: firma ve kullanıcılar korunur, giriş ve mid-session erişim
//     kapanır, geçersiz geçiş 409.

import (
	"context"
	"net/http"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

func TestPlatformUserManagementSecurity(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "platform-um-http-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	orgID := org.Organization.ID
	owner1 := org.Owner
	base := "/api/v1/platform/organizations/" + orgID

	ownerToken, err := d.issuer.IssueAccessToken(owner1.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatalf("owner token: %v", err)
	}
	// Yazma uçları denetim kaydına actor_user_id (FK -> users) yazar: sahte
	// bir uid yerine GERÇEK bir platform hesabı (CLI'ın kullandığı AYNI
	// CreateSuperAdmin yolu) -- yalnızca bu test için, sonunda kaldırılır.
	_, _ = d.pool.Exec(ctx, "DELETE FROM users WHERE username = $1", "um_http_superadmin")
	superAdmin, err := d.platform.CreateSuperAdmin(ctx, "um_http_superadmin", "SuperGizli123!", "Test Platform Yöneticisi")
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

	t.Run("super_admin_lists_users_enriched_with_organization_role", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, base+"/users", superToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", rec.Code)
		}
		users, _ := body["users"].([]any)
		if len(users) != 1 {
			t.Fatalf("kullanıcı sayısı = %d, want 1", len(users))
		}
		u := users[0].(map[string]any)
		if u["organization_role_code"] != domain.OrgRoleOwner || u["is_active"] != true {
			t.Errorf("owner satırı eksik alanlar: %+v", u)
		}
	})

	t.Run("organization_owner_cannot_use_platform_user_management_api", func(t *testing.T) {
		for _, ep := range []struct{ method, path, body string }{
			{http.MethodGet, base + "/users", ""},
			{http.MethodPost, base + "/users", `{"username":"x","full_name":"X","temporary_password":"GeciciSifre123!","organization_role_code":"owner"}`},
			{http.MethodPost, base + "/users/" + owner1.ID + "/deactivate", ""},
			{http.MethodPost, base + "/users/" + owner1.ID + "/reactivate", ""},
			{http.MethodPut, base + "/users/" + owner1.ID + "/organization-role", `{"role_code":"owner"}`},
			{http.MethodPost, base + "/users/" + owner1.ID + "/reset-initial-password", `{"temporary_password":"GeciciSifre123!"}`},
			{http.MethodGet, base + "/roles", ""},
			{http.MethodPatch, base + "/status", `{"status":"suspended"}`},
			{http.MethodPatch, base + "/plan", `{"plan_code":"pro"}`},
		} {
			rec, _ := rbacDo(t, d.router, ep.method, ep.path, ownerToken, ep.body)
			if rec.Code != http.StatusForbidden {
				t.Errorf("%s %s: status = %d, want 403 (owner platform yöneticisi değildir)", ep.method, ep.path, rec.Code)
			}
		}
	})

	t.Run("generic_admin_username_and_legacy_role_rejected", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodPost, base+"/users", superToken,
			`{"username":"admin","full_name":"Genel","temporary_password":"GeciciSifre123!","organization_role_code":"owner"}`)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("'admin' kullanıcı adı: status = %d, want 400", rec.Code)
		}
		rec, _ = rbacDo(t, d.router, http.MethodPost, base+"/users", superToken,
			`{"username":"um_http_legacy","full_name":"Eski","temporary_password":"GeciciSifre123!","organization_role_code":"legacy_user"}`)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("legacy_user: status = %d, want 400", rec.Code)
		}
	})

	t.Run("last_active_owner_cannot_be_deactivated_or_demoted", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodPost, base+"/users/"+owner1.ID+"/deactivate", superToken, "")
		if rec.Code != http.StatusConflict {
			t.Errorf("deactivate: status = %d, want 409", rec.Code)
		}
		rec, _ = rbacDo(t, d.router, http.MethodPut, base+"/users/"+owner1.ID+"/organization-role", superToken, `{"role_code":"finance"}`)
		if rec.Code != http.StatusConflict {
			t.Errorf("demote: status = %d, want 409", rec.Code)
		}
	})

	var owner2ID string
	t.Run("super_admin_provisions_second_owner", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, base+"/users", superToken,
			`{"username":"um_http_owner_2","full_name":"İkinci Sahip","temporary_password":"GeciciSifre123!","organization_role_code":"owner"}`)
		if rec.Code != http.StatusCreated {
			t.Fatalf("status = %d, want 201 (body=%v)", rec.Code, body)
		}
		owner2ID, _ = body["id"].(string)
		if body["organization_role_code"] != domain.OrgRoleOwner || body["must_change_password"] != true || body["role"] != string(domain.RoleAdmin) {
			t.Errorf("ikinci owner yanıtı: %+v", body)
		}
	})

	t.Run("second_owner_unlocks_first_owner_and_record_is_preserved", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodPost, base+"/users/"+owner1.ID+"/deactivate", superToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("deactivate: status = %d, want 200", rec.Code)
		}
		_, body := rbacDo(t, d.router, http.MethodGet, base+"/users", superToken, "")
		users, _ := body["users"].([]any)
		if len(users) != 2 {
			t.Fatalf("pasifleştirme sonrası kullanıcı sayısı = %d, want 2 (silinmez)", len(users))
		}
		for _, raw := range users {
			u := raw.(map[string]any)
			if u["id"] == owner1.ID && u["is_active"] != false {
				t.Errorf("owner1 hâlâ aktif görünüyor")
			}
		}
		// Artık ikinci Sahip son aktif Sahip.
		rec, _ = rbacDo(t, d.router, http.MethodPost, base+"/users/"+owner2ID+"/deactivate", superToken, "")
		if rec.Code != http.StatusConflict {
			t.Errorf("son aktif owner2 deactivate: status = %d, want 409", rec.Code)
		}
		rec, _ = rbacDo(t, d.router, http.MethodPost, base+"/users/"+owner1.ID+"/reactivate", superToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("reactivate: status = %d, want 200", rec.Code)
		}
		rec, body = rbacDo(t, d.router, http.MethodPut, base+"/users/"+owner2ID+"/organization-role", superToken, `{"role_code":"project_manager"}`)
		if rec.Code != http.StatusOK || body["organization_role_code"] != domain.OrgRoleProjectManager {
			t.Errorf("owner2 düşürme: status = %d body=%v", rec.Code, body)
		}
		rec, _ = rbacDo(t, d.router, http.MethodPut, base+"/users/"+owner1.ID+"/organization-role", superToken, `{"role_code":"finance"}`)
		if rec.Code != http.StatusConflict {
			t.Errorf("tek kalan owner1 düşürme: status = %d, want 409", rec.Code)
		}
	})

	t.Run("reset_initial_password_then_login_requires_change", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodPost, base+"/users/"+owner2ID+"/reset-initial-password", superToken, `{"temporary_password":"YeniGecici123!"}`)
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", rec.Code)
		}
		rec, _ = rbacDo(t, d.router, http.MethodPost, "/api/v1/auth/login", "", `{"username":"um_http_owner_2","password":"GeciciSifre123!"}`)
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("eski şifreyle login: status = %d, want 401", rec.Code)
		}
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/auth/login", "", `{"username":"um_http_owner_2","password":"YeniGecici123!"}`)
		if rec.Code != http.StatusOK || body["must_change_password"] != true {
			t.Errorf("yeni geçici şifreyle login: status = %d body=%v", rec.Code, body)
		}
	})

	t.Run("cancel_preserves_organization_and_blocks_access_then_reactivate", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodPatch, base+"/status", superToken, `{"status":"cancelled"}`)
		if rec.Code != http.StatusOK {
			t.Fatalf("cancel: status = %d, want 200", rec.Code)
		}
		rec, body := rbacDo(t, d.router, http.MethodGet, base, superToken, "")
		if rec.Code != http.StatusOK || body["status"] != string(domain.OrgStatusCancelled) {
			t.Errorf("iptal edilen firma okunamadı/yanlış: status=%d body=%v", rec.Code, body)
		}
		rec, body = rbacDo(t, d.router, http.MethodGet, base+"/users", superToken, "")
		if users, _ := body["users"].([]any); rec.Code != http.StatusOK || len(users) != 2 {
			t.Errorf("iptal edilen firmanın kullanıcıları korunmalı: status=%d n=%d", rec.Code, len(users))
		}
		// Mid-session: hâlâ geçerli access token'lı owner tenant ucuna giremez.
		rec, _ = rbacDo(t, d.router, http.MethodGet, "/api/v1/offers/", ownerToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("iptal sonrası mid-session erişim: status = %d, want 403", rec.Code)
		}
		rec, _ = rbacDo(t, d.router, http.MethodPost, "/api/v1/auth/login", "", `{"username":"um_http_owner_2","password":"YeniGecici123!"}`)
		if rec.Code != http.StatusForbidden {
			t.Errorf("iptal edilen firmaya login: status = %d, want 403", rec.Code)
		}
		rec, _ = rbacDo(t, d.router, http.MethodPatch, base+"/status", superToken, `{"status":"suspended"}`)
		if rec.Code != http.StatusConflict {
			t.Errorf("cancelled -> suspended: status = %d, want 409", rec.Code)
		}
		rec, _ = rbacDo(t, d.router, http.MethodPatch, base+"/status", superToken, `{"status":"active"}`)
		if rec.Code != http.StatusOK {
			t.Fatalf("reactivate: status = %d, want 200", rec.Code)
		}
		rec, _ = rbacDo(t, d.router, http.MethodGet, "/api/v1/offers/", ownerToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("yeniden aktif firma owner erişimi: status = %d, want 200", rec.Code)
		}
	})

	t.Run("roles_listing_for_super_admin_excludes_legacy", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, base+"/roles", superToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", rec.Code)
		}
		roles, _ := body["roles"].([]any)
		if len(roles) == 0 {
			t.Fatalf("rol listesi boş")
		}
		for _, r := range roles {
			if r.(map[string]any)["code"] == domain.OrgRoleLegacyUser {
				t.Errorf("legacy_user platform rol listesinde")
			}
		}
	})
}
