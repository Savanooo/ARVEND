package middleware_test

// "Kişi = tek kayıt" gerçek router'a karşı: POST /users yeni alan
// gönderilmeden (dondurulmuş web) personel kaydını açar, cevap sonucu
// söyler; kullanıcı/personel ekranları bağı gösterir; hesap adları
// personel listesinde yalnızca kullanıcı listesini görebilene döner.

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestUserEmployeeLinkHTTP(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "person-link-http")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	orgID := org.Organization.ID
	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatalf("owner token: %v", err)
	}
	field, fieldToken := mustCreateRoleUser(t, ctx, d, orgID, "plhttp_field", domain.OrgRoleField)
	employeeSvc := service.NewEmployeeService(d.pool, d.q)

	type link struct {
		Status         string `json:"status"`
		EmployeeID     string `json:"employee_id"`
		EmployeeName   string `json:"employee_full_name"`
		EmployeeActive bool   `json:"employee_is_active"`
		Message        string `json:"message"`
	}
	type created struct {
		ID               string  `json:"id"`
		Username         string  `json:"username"`
		EmployeeID       *string `json:"employee_id"`
		EmployeeFullName string  `json:"employee_full_name"`
		EmployeeLink     *link   `json:"employee_link"`
	}
	post := func(t *testing.T, body map[string]any) (int, created, map[string]any) {
		t.Helper()
		b, _ := json.Marshal(body)
		rec, parsed := rbacDo(t, d.router, http.MethodPost, "/api/v1/users", ownerToken, string(b))
		var out created
		_ = json.Unmarshal(rec.Body.Bytes(), &out)
		return rec.Code, out, parsed
	}
	base := func(username, fullName string) map[string]any {
		return map[string]any{
			"username": username, "password": "GeciciSifre123!", "full_name": fullName,
			"organization_role_code": domain.OrgRoleField,
		}
	}

	var createdUserID, createdEmployeeID string
	t.Run("eski gövde (web) personel kaydını varsayılan olarak açar", func(t *testing.T) {
		code, out, parsed := post(t, base("plhttp_web", "Web Kişisi"))
		if code != http.StatusCreated || out.EmployeeLink == nil {
			t.Fatalf("201 + employee_link bekleniyordu: %d %v", code, parsed)
		}
		if out.EmployeeLink.Status != "created" || out.EmployeeLink.EmployeeID == "" || out.EmployeeLink.Message == "" {
			t.Fatalf("employee_link: %+v", out.EmployeeLink)
		}
		if out.EmployeeID == nil || *out.EmployeeID != out.EmployeeLink.EmployeeID || out.EmployeeFullName != "Web Kişisi" {
			t.Fatalf("üst seviye employee_id/employee_full_name: %+v", out)
		}
		createdUserID, createdEmployeeID = out.ID, out.EmployeeLink.EmployeeID

		rec, parsed := rbacDo(t, d.router, http.MethodGet, "/api/v1/users/"+out.ID, ownerToken, "")
		if rec.Code != http.StatusOK || parsed["employee_id"] != createdEmployeeID || parsed["employee_full_name"] != "Web Kişisi" {
			t.Fatalf("GET /users/{id} bağlı personeli göstermeli: %d %v", rec.Code, parsed)
		}
		rec, parsed = rbacDo(t, d.router, http.MethodGet, "/api/v1/users?limit=200", ownerToken, "")
		found := false
		for _, raw := range parsed["users"].([]any) {
			u := raw.(map[string]any)
			if u["id"] == out.ID {
				found = u["employee_id"] == createdEmployeeID
			}
		}
		if rec.Code != http.StatusOK || !found {
			t.Fatalf("GET /users listesi bağlı personeli göstermeli: %d", rec.Code)
		}
	})

	t.Run("create_employee=false personel açmaz", func(t *testing.T) {
		b := base("plhttp_ofis", "Ofis Kişisi")
		b["create_employee"] = false
		code, out, parsed := post(t, b)
		if code != http.StatusCreated || out.EmployeeLink == nil || out.EmployeeLink.Status != "skipped" || out.EmployeeID != nil {
			t.Fatalf("skipped bekleniyordu: %d %v", code, parsed)
		}
	})

	t.Run("employee_id mevcut personele bağlar, bağlı olanı almaz", func(t *testing.T) {
		e, err := employeeSvc.Create(ctx, orgID, service.EmployeeInput{FullName: "Batuhan İnci", IsActive: true})
		if err != nil {
			t.Fatalf("personel: %v", err)
		}
		b := base("plhttp_batu", "batu")
		b["employee_id"] = e.ID
		code, out, parsed := post(t, b)
		if code != http.StatusCreated || out.EmployeeLink == nil || out.EmployeeLink.Status != "linked" || out.EmployeeLink.EmployeeName != "Batuhan İnci" {
			t.Fatalf("linked bekleniyordu: %d %v", code, parsed)
		}
		b = base("plhttp_thief", "Hırsız")
		b["employee_id"] = e.ID
		code, _, parsed = post(t, b)
		if code != http.StatusConflict {
			t.Fatalf("başka hesaba bağlı personel 409 olmalı: %d %v", code, parsed)
		}
		var n int
		if err := d.pool.QueryRow(ctx, "SELECT count(*) FROM users WHERE username = 'plhttp_thief'").Scan(&n); err != nil || n != 0 {
			t.Fatalf("reddedilen istek hesabı açtı (n=%d, err=%v)", n, err)
		}
	})

	t.Run("personel listesi hesap adını yalnızca kullanıcıları görebilene gösterir", func(t *testing.T) {
		usernameOf := func(token string) (int, any, bool) {
			rec, parsed := rbacDo(t, d.router, http.MethodGet, "/api/v1/employees", token, "")
			if rec.Code != http.StatusOK {
				return rec.Code, nil, false
			}
			for _, raw := range parsed["employees"].([]any) {
				e := raw.(map[string]any)
				if e["id"] == createdEmployeeID {
					v, ok := e["user_username"]
					if e["user_id"] != createdUserID {
						t.Fatalf("user_id herkese dönmeli: %v", e)
					}
					return rec.Code, v, ok
				}
			}
			t.Fatalf("personel listede yok")
			return 0, nil, false
		}
		if code, v, ok := usernameOf(ownerToken); code != http.StatusOK || !ok || v != "plhttp_web" {
			t.Fatalf("Sahip hesap adını görmeli: %d %v %v", code, v, ok)
		}
		// Saha'ya kişiye özel personel okuma izni (mesai girişi için tipik):
		// personel listesini görür ama kullanıcı listesini görmez.
		rec, parsed := rbacDo(t, d.router, http.MethodGet, "/api/v1/users/"+field.ID+"/permissions", ownerToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("izinler okunamadı: %d", rec.Code)
		}
		perms := []string{"employees.read"}
		for _, p := range parsed["role_permissions"].([]any) {
			perms = append(perms, p.(string))
		}
		body, _ := json.Marshal(map[string][]string{"permissions": perms})
		if rec, parsed := rbacDo(t, d.router, http.MethodPut, "/api/v1/users/"+field.ID+"/permissions", ownerToken, string(body)); rec.Code != http.StatusOK {
			t.Fatalf("employees.read verilemedi: %d %v", rec.Code, parsed)
		}
		code, v, ok := usernameOf(fieldToken)
		if code != http.StatusOK {
			t.Fatalf("ön koşul: Saha personel listesini görebilmeli, geldi %d", code)
		}
		if ok {
			t.Fatalf("kullanıcı listesini göremeyen hesap adını görmemeli: %v", v)
		}
	})

	t.Run("bağlantı önerileri yalnızca personel yönetimi + kullanıcı okuma ile", func(t *testing.T) {
		rec, parsed := rbacDo(t, d.router, http.MethodGet, "/api/v1/employees/link-suggestions", ownerToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("Sahip önerileri okuyabilmeli: %d %v", rec.Code, parsed)
		}
		if _, ok := parsed["suggestions"].([]any); !ok {
			t.Fatalf("suggestions dizi olmalı (boşken de): %v", parsed)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/employees/link-suggestions", fieldToken, ""); rec.Code != http.StatusForbidden {
			t.Fatalf("Saha önerileri görmemeli: %d", rec.Code)
		}
	})
}
