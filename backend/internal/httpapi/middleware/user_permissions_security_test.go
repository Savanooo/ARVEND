package middleware_test

// Kişiye özel yetkiler (GET/PUT /users/{id}/permissions) gerçek router'a
// karşı: kim düzenleyebilir, ayarlar yetki middleware'inde ve /auth/me'de
// gerçekten uygulanıyor mu, rol değişimi ayarları sıfırlıyor mu.

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

func TestUserPermissionsEndpoints(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "userperm-http")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	orgID := org.Organization.ID
	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatalf("owner token: %v", err)
	}
	field, fieldToken := mustCreateRoleUser(t, ctx, d, orgID, "userperm_http_field", domain.OrgRoleField)
	_, otherFieldToken := mustCreateRoleUser(t, ctx, d, orgID, "userperm_http_field2", domain.OrgRoleField)
	permsPath := "/api/v1/users/" + field.ID + "/permissions"

	type detail struct {
		RoleCode        string   `json:"role_code"`
		RolePermissions []string `json:"role_permissions"`
		Permissions     []string `json:"permissions"`
		Granted         []string `json:"granted"`
		Revoked         []string `json:"revoked"`
		Editable        bool     `json:"editable"`
	}
	decode := func(t *testing.T, body []byte) detail {
		t.Helper()
		var out detail
		if err := json.Unmarshal(body, &out); err != nil {
			t.Fatalf("yanıt çözümlenemedi: %v (%s)", err, body)
		}
		return out
	}
	put := func(t *testing.T, token string, perms []string) (int, detail, map[string]any) {
		t.Helper()
		body, _ := json.Marshal(map[string][]string{"permissions": perms})
		rec, parsed := rbacDo(t, d.router, http.MethodPut, permsPath, token, string(body))
		if rec.Code != http.StatusOK {
			return rec.Code, detail{}, parsed
		}
		return rec.Code, decode(t, rec.Body.Bytes()), parsed
	}
	mePermissions := func(t *testing.T, token string) []string {
		t.Helper()
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/auth/me", token, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("/auth/me %d", rec.Code)
		}
		return decode(t, rec.Body.Bytes()).Permissions
	}

	rec, _ := rbacDo(t, d.router, http.MethodGet, permsPath, ownerToken, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("Sahip okuyamadı: %d %s", rec.Code, rec.Body.String())
	}
	base := decode(t, rec.Body.Bytes())
	if base.RoleCode != domain.OrgRoleField || !base.Editable || !slices.Equal(base.Permissions, base.RolePermissions) {
		t.Fatalf("başlangıç yanlış: %+v", base)
	}

	t.Run("Saha kullanıcısı kimsenin yetkisini okuyamaz ve değiştiremez", func(t *testing.T) {
		if rec, _ := rbacDo(t, d.router, http.MethodGet, permsPath, fieldToken, ""); rec.Code != http.StatusForbidden {
			t.Fatalf("GET 403 bekleniyordu, geldi %d", rec.Code)
		}
		if code, _, _ := put(t, fieldToken, append(slices.Clone(base.RolePermissions), "offers.read")); code != http.StatusForbidden {
			t.Fatalf("kendine yetki vermeye çalışan Saha 403 almalı, geldi %d", code)
		}
	})

	t.Run("revoke uçtan uca uygulanır: ilgili uç 403 döner, /auth/me listede göstermez", func(t *testing.T) {
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/attendance?month=2026-09", fieldToken, ""); rec.Code != http.StatusOK {
			t.Fatalf("ön koşul: Saha puantajı görebilmeli, geldi %d", rec.Code)
		}
		desired := []string{}
		for _, p := range base.RolePermissions {
			if p != "attendance.read" {
				desired = append(desired, p)
			}
		}
		code, got, parsed := put(t, ownerToken, desired)
		if code != http.StatusOK || !slices.Equal(got.Revoked, []string{"attendance.read"}) {
			t.Fatalf("revoke kaydedilemedi: %d %v %+v", code, parsed, got)
		}
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/attendance?month=2026-09", fieldToken, "")
		if rec.Code != http.StatusForbidden || body["code"] != "permission_denied" {
			t.Fatalf("revoke sonrası 403 permission_denied bekleniyordu, geldi %d %v", rec.Code, body)
		}
		if slices.Contains(mePermissions(t, fieldToken), "attendance.read") {
			t.Fatal("/auth/me revoke edilen izni hâlâ listeliyor")
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/attendance?month=2026-09", otherFieldToken, ""); rec.Code != http.StatusOK {
			t.Fatalf("aynı roldeki diğer Saha etkilenmemeli, geldi %d", rec.Code)
		}
	})

	t.Run("grant uçtan uca uygulanır: rolde olmayan uç açılır", func(t *testing.T) {
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/offers/", fieldToken, ""); rec.Code != http.StatusForbidden {
			t.Fatalf("ön koşul: Saha teklifleri görememeli, geldi %d", rec.Code)
		}
		code, got, parsed := put(t, ownerToken, append(slices.Clone(base.RolePermissions), "offers.read"))
		if code != http.StatusOK || !slices.Equal(got.Granted, []string{"offers.read"}) {
			t.Fatalf("grant kaydedilemedi: %d %v %+v", code, parsed, got)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/offers/", fieldToken, ""); rec.Code != http.StatusOK {
			t.Fatalf("grant sonrası 200 bekleniyordu, geldi %d", rec.Code)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/offers/", otherFieldToken, ""); rec.Code != http.StatusForbidden {
			t.Fatalf("grant yalnızca hedef kişiye uygulanmalı, diğer Saha %d aldı", rec.Code)
		}
		if !slices.Contains(mePermissions(t, fieldToken), "offers.read") {
			t.Fatal("/auth/me grant edilen izni listelemiyor")
		}
	})

	t.Run("tanımsız izin kodu 400", func(t *testing.T) {
		if code, _, _ := put(t, ownerToken, []string{"boyle.bir.izin.yok"}); code != http.StatusBadRequest {
			t.Fatalf("400 bekleniyordu, geldi %d", code)
		}
	})

	t.Run("yönetim kataloğu izni Saha'ya verilince ilgili uç açılır (requireAdmin yok)", func(t *testing.T) {
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/employees", fieldToken, ""); rec.Code != http.StatusForbidden {
			t.Fatalf("ön koşul: Saha personel listesini görememeli, geldi %d", rec.Code)
		}
		code, _, parsed := put(t, ownerToken, append(slices.Clone(base.RolePermissions), "employees.read", "products.read"))
		if code != http.StatusOK {
			t.Fatalf("grant kaydedilemedi: %d %v", code, parsed)
		}
		for _, path := range []string{"/api/v1/employees", "/api/v1/products"} {
			if rec, _ := rbacDo(t, d.router, http.MethodGet, path, fieldToken, ""); rec.Code != http.StatusOK {
				t.Fatalf("%s: grant sonrası 200 bekleniyordu, geldi %d", path, rec.Code)
			}
		}

		// Personeli görmek maaşları görmek demek değil: ücretler yalnızca
		// employees.manage ile döner (liste ve detay).
		rec, created := rbacDo(t, d.router, http.MethodPost, "/api/v1/employees", ownerToken,
			`{"full_name":"Ucretli Personel","salary":45000,"daily_wage":1500}`)
		if rec.Code != http.StatusCreated {
			t.Fatalf("personel oluşturulamadı: %d %s", rec.Code, rec.Body.String())
		}
		empPath := "/api/v1/employees/" + created["id"].(string)
		rec, body := rbacDo(t, d.router, http.MethodGet, empPath, fieldToken, "")
		if rec.Code != http.StatusOK || body["salary"] != nil || body["daily_wage"] != nil {
			t.Fatalf("görüntüleme izniyle ücretler boş dönmeli: %d %v", rec.Code, body)
		}
		rec, _ = rbacDo(t, d.router, http.MethodGet, "/api/v1/employees", fieldToken, "")
		if strings.Contains(rec.Body.String(), "45000") || strings.Contains(rec.Body.String(), "1500") {
			t.Fatalf("personel listesi ücretleri sızdırıyor: %s", rec.Body.String())
		}
		if _, body := rbacDo(t, d.router, http.MethodGet, empPath, ownerToken, ""); body["salary"] != float64(45000) || body["daily_wage"] != float64(1500) {
			t.Fatalf("düzenleme izni olan Sahip ücretleri görmeli: %v", body)
		}
	})

	t.Run("Yönetici'ye kilitli izin Saha'ya kişiye özel eklenemez (400)", func(t *testing.T) {
		code, _, parsed := put(t, ownerToken, append(slices.Clone(base.RolePermissions), "organization.users.read"))
		if code != http.StatusBadRequest {
			t.Fatalf("400 bekleniyordu, geldi %d %v", code, parsed)
		}
		if slices.Contains(mePermissions(t, fieldToken), "organization.users.read") {
			t.Fatal("reddedilen izin /auth/me'de görünmemeli")
		}
	})

	t.Run("Sahip'e kişiye özel ayar yapılamaz (409)", func(t *testing.T) {
		body, _ := json.Marshal(map[string][]string{"permissions": {}})
		rec, _ := rbacDo(t, d.router, http.MethodPut, "/api/v1/users/"+org.Owner.ID+"/permissions", ownerToken, string(body))
		if rec.Code != http.StatusConflict {
			t.Fatalf("409 bekleniyordu, geldi %d %s", rec.Code, rec.Body.String())
		}
	})

	t.Run("rol değişimi kişiye özel ayarları sıfırlar", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodPut, "/api/v1/users/"+field.ID+"/organization-role", ownerToken, `{"role_code":"finance"}`)
		if rec.Code != http.StatusOK {
			t.Fatalf("rol değişmedi: %d %s", rec.Code, rec.Body.String())
		}
		rec, _ = rbacDo(t, d.router, http.MethodGet, permsPath, ownerToken, "")
		got := decode(t, rec.Body.Bytes())
		if got.RoleCode != domain.OrgRoleFinance || len(got.Granted)+len(got.Revoked) != 0 {
			t.Fatalf("rol değişiminde ayarlar sıfırlanmalı: %+v", got)
		}
	})
}
