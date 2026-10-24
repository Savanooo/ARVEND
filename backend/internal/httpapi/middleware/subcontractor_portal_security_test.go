package middleware_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// Taşeron Paneli (migration 0075, docs/taseron-paneli.md) -- gerçek bir
// PostgreSQL bağlantısı gerektirir. Taşeron hesabı varsayılan retle
// karşılanır: router'daki BÜTÜN rotalar gezilir, kimlik isteyen her uç
// (izinli birkaç uç dışında) taşeron hesabına 403 "portal_only" dönmeli.
// Yeni eklenen bir rota da bu teste kendiliğinden girer.

// portalSelfRoutes: taşeron hesabının da girebildiği uçlar (kendi hesabı,
// bildirimler, telefon kaydı, portal) ve kapısız oturum uçları.
var portalSelfRoutes = []string{
	"/api/v1/auth/",
	"/api/v1/mobile/app-download",
	"/api/v1/users/me/",
	"/api/v1/notifications",
	"/api/v1/push/devices",
	"/api/v1/portal/",
}

func isPortalSelfRoute(path string) bool {
	for _, p := range portalSelfRoutes {
		if strings.HasPrefix(path, p) {
			return true
		}
	}
	return false
}

const zeroUUID = "00000000-0000-0000-0000-000000000000"

// concretePath: chi deseninden ({param}, *) istek yolu üretir.
func concretePath(pattern string) string {
	var b strings.Builder
	depth := 0
	for _, r := range pattern {
		switch {
		case r == '{':
			if depth == 0 {
				b.WriteString(zeroUUID)
			}
			depth++
		case r == '}':
			depth--
		case depth > 0:
		case r == '*':
			b.WriteString("x")
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

func TestSubcontractorPortalSecurity(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "portal-sec-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	other := mustCreateReadyOrg(t, ctx, d, "portal-sec-org-b")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, other.Organization.ID) })
	orgID := org.Organization.ID

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatal(err)
	}
	_, fieldToken := mustCreateRoleUser(t, ctx, d, orgID, "portal_sec_field", domain.OrgRoleField)

	pA := mustCreateProject(t, ctx, d, orgID, "Portal Projesi A")
	pB := mustCreateProject(t, ctx, d, orgID, "Portal Projesi B")
	foreign := mustCreateProject(t, ctx, d, other.Organization.ID, "Başka Firma Projesi")

	card, err := d.supplierSvc.CreateSubcontractorCard(ctx, orgID, service.SupplierInput{LegalName: "Usta Elektrik"})
	if err != nil {
		t.Fatal(err)
	}
	otherCard, err := d.supplierSvc.CreateSubcontractorCard(ctx, orgID, service.SupplierInput{LegalName: "Başka Taşeron"})
	if err != nil {
		t.Fatal(err)
	}
	engage := func(projectID, supplierID string, contract, paid float64) {
		t.Helper()
		sub, err := d.projectSvc.CreateSubcontractor(ctx, projectID, orgID, service.SubcontractorInput{
			ContractAmount: contract, Currency: "TRY", SupplierID: supplierID,
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := d.projectSvc.CreateSubcontractorPayment(ctx, projectID, sub.ID, orgID, service.SubcontractorPaymentInput{
			Amount: paid, Currency: "TRY", PaidDate: time.Now(),
		}); err != nil {
			t.Fatal(err)
		}
	}
	engage(pA.ID, card.ID, 100000, 30000)
	engage(pB.ID, card.ID, 50000, 10000)
	engage(pA.ID, otherCard.ID, 80000, 5000)

	base := "/api/v1/subcontractors/" + card.ID + "/portal"
	createBody := `{"full_name":"Usta Ali","username":"portal_sec_usta","temporary_password":"GeciciSifre123!"}`

	t.Run("1_only_user_managers_open_logins", func(t *testing.T) {
		if rec, _ := rbacDo(t, d.router, http.MethodPost, base+"/users", fieldToken, createBody); rec.Code != http.StatusForbidden {
			t.Fatalf("saha giriş açamamalı: %d", rec.Code)
		}
	})

	rec, body := rbacDo(t, d.router, http.MethodPost, base+"/users", ownerToken, createBody)
	if rec.Code != http.StatusCreated {
		t.Fatalf("giriş açılamadı: %d %v", rec.Code, body)
	}
	portalUserID, _ := body["id"].(string)
	if body["must_change_password"] != true {
		t.Fatalf("geçici şifreyle açılmalı: %v", body)
	}
	if rec, _ := rbacDo(t, d.router, http.MethodPost, base+"/users", ownerToken, createBody); rec.Code != http.StatusConflict {
		t.Fatalf("aynı kullanıcı adı 409 olmalı: %d", rec.Code)
	}
	portalToken, err := d.issuer.IssueAccessToken(portalUserID, domain.RoleKullanici, orgID)
	if err != nil {
		t.Fatal(err)
	}

	t.Run("2_temporary_password_must_be_changed_first", func(t *testing.T) {
		if rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/portal/overview", portalToken, ""); rec.Code != http.StatusForbidden || !strings.Contains(body["error"].(string), "şifre") {
			t.Fatalf("şifre değişmeden panel açılmamalı: %d %v", rec.Code, body)
		}
		if rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/users/me/set-initial-password", portalToken,
			`{"new_password":"SabitSifre123!"}`); rec.Code >= 300 {
			t.Fatalf("taşeron kendi şifresini belirleyebilmeli: %d %v", rec.Code, body)
		}
	})

	t.Run("3_project_grants", func(t *testing.T) {
		if rec, _ := rbacDo(t, d.router, http.MethodPut, base+"/projects", ownerToken,
			`{"project_ids":["`+foreign.ID+`"]}`); rec.Code != http.StatusBadRequest {
			t.Fatalf("başka firmanın projesine izin verilememeli: %d", rec.Code)
		}
		rec, body := rbacDo(t, d.router, http.MethodPut, base+"/projects", ownerToken, `{"project_ids":["`+pA.ID+`"]}`)
		if rec.Code != http.StatusOK {
			t.Fatalf("izin verilemedi: %d %v", rec.Code, body)
		}
		granted := 0
		for _, p := range body["projects"].([]any) {
			m := p.(map[string]any)
			if m["granted"] == true {
				granted++
				if m["id"] != pA.ID {
					t.Errorf("yalnızca A izinli olmalı: %v", m)
				}
			}
		}
		if granted != 1 {
			t.Fatalf("tek izin beklenir: %d", granted)
		}
	})

	t.Run("4_overview_shows_only_own_records_in_granted_projects", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/portal/overview", portalToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("panel açılmadı: %d %v", rec.Code, body)
		}
		raw := rec.Body.String()
		for _, leak := range []string{"Başka Taşeron", "Portal Projesi B", "Başka Firma"} {
			if strings.Contains(raw, leak) {
				t.Errorf("panelde görünmemeli: %q", leak)
			}
		}
		engs := body["engagements"].([]any)
		if len(engs) != 1 {
			t.Fatalf("yalnızca A'daki kendi işi: %v", engs)
		}
		e := engs[0].(map[string]any)
		if e["contract_amount"] != 100000.0 || e["paid"] != 30000.0 || e["remaining"] != 70000.0 {
			t.Errorf("iş rakamları: %v", e)
		}
		pays := body["payments"].([]any)
		if len(pays) != 1 || pays[0].(map[string]any)["amount"] != 30000.0 {
			t.Errorf("yalnızca A'daki kendi ödemesi: %v", pays)
		}
		totals := body["totals"].([]any)
		if len(totals) != 1 || totals[0].(map[string]any)["remaining"] != 70000.0 {
			t.Errorf("toplamlar: %v", totals)
		}
		rec, body = rbacDo(t, d.router, http.MethodGet, "/api/v1/auth/me", portalToken, "")
		if rec.Code != http.StatusOK || body["supplier_id"] != card.ID || body["organization_role_code"] != domain.OrgRoleSubcontractor {
			t.Errorf("oturum taşeron hesabını göstermeli: %d %v", rec.Code, body)
		}
	})

	t.Run("5_firm_users_cannot_open_portal", func(t *testing.T) {
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/portal/overview", ownerToken, ""); rec.Code != http.StatusForbidden {
			t.Fatalf("firma kullanıcısı paneli açamamalı: %d", rec.Code)
		}
	})

	t.Run("6_every_other_route_rejects_portal_user", func(t *testing.T) {
		checked := 0
		err := chi.Walk(d.router.(chi.Routes), func(method, route string, _ http.Handler, _ ...func(http.Handler) http.Handler) error {
			path := concretePath(route)
			if isPortalSelfRoute(path) {
				return nil
			}
			// Kimlik istemeyen (herkese açık) uç bu testin konusu değil.
			if rec, _ := rbacDo(t, d.router, method, path, "", ""); rec.Code != http.StatusUnauthorized {
				return nil
			}
			checked++
			rec, _ := rbacDo(t, d.router, method, path, portalToken, "")
			if strings.HasPrefix(path, "/api/v1/platform/") {
				if rec.Code != http.StatusForbidden {
					t.Errorf("%s %s: platform ucu taşerona %d döndü", method, route, rec.Code)
				}
				return nil
			}
			if rec.Code != http.StatusForbidden || !strings.Contains(rec.Body.String(), "portal_only") {
				t.Errorf("%s %s: taşeron hesabı reddedilmedi (%d %s)", method, route, rec.Code, rec.Body.String())
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
		if checked < 100 {
			t.Fatalf("rota gezintisi eksik: %d uç denetlendi", checked)
		}
	})

	t.Run("7_self_routes_allowed", func(t *testing.T) {
		for _, path := range []string{"/api/v1/notifications", "/api/v1/notifications/unread-count"} {
			if rec, body := rbacDo(t, d.router, http.MethodGet, path, portalToken, ""); rec.Code != http.StatusOK {
				t.Errorf("%s taşerona açık olmalı: %d %v", path, rec.Code, body)
			}
		}
	})

	t.Run("8_portal_user_cannot_be_managed_like_staff", func(t *testing.T) {
		if rec, _ := rbacDo(t, d.router, http.MethodPut, "/api/v1/users/"+portalUserID+"/organization-role", ownerToken,
			`{"role_code":"field"}`); rec.Code != http.StatusConflict {
			t.Errorf("taşeron hesabının rolü değiştirilememeli: %d", rec.Code)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodPut, "/api/v1/users/"+portalUserID+"/permissions", ownerToken,
			`{"permissions":["projects.read"]}`); rec.Code != http.StatusConflict {
			t.Errorf("taşeron hesabına kişiye özel izin verilememeli: %d", rec.Code)
		}
	})

	t.Run("9_archived_card_and_closed_login_lock_account", func(t *testing.T) {
		if _, err := d.pool.Exec(ctx, "UPDATE suppliers SET is_active = false WHERE id = $1", card.ID); err != nil {
			t.Fatal(err)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/portal/overview", portalToken, ""); rec.Code != http.StatusUnauthorized {
			t.Errorf("arşivdeki kartın hesabı kapanmalı: %d", rec.Code)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodPost, "/api/v1/auth/login", "",
			`{"username":"portal_sec_usta","password":"SabitSifre123!"}`); rec.Code != http.StatusForbidden {
			t.Errorf("arşivdeki kartın hesabı giriş yapamamalı: %d", rec.Code)
		}
		if _, err := d.pool.Exec(ctx, "UPDATE suppliers SET is_active = true WHERE id = $1", card.ID); err != nil {
			t.Fatal(err)
		}
		if rec, body := rbacDo(t, d.router, http.MethodPost, base+"/users/"+portalUserID+"/active", ownerToken,
			`{"active":false}`); rec.Code != http.StatusOK || body["is_active"] != false {
			t.Fatalf("giriş kapatılamadı: %d %v", rec.Code, body)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/portal/overview", portalToken, ""); rec.Code != http.StatusUnauthorized {
			t.Errorf("kapatılan giriş panele girememeli: %d", rec.Code)
		}
	})
}
