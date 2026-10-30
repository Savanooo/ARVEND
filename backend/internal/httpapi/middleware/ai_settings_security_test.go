package middleware_test

// Yapay Zekâ Ayarları (migration 0081) HTTP katmanında: uçların kapısı
// (requireAdmin + organization.roles.manage), ayar CRUD ve doğrulama,
// sunucu tavanına kırpma, kişi kişi izin (kişiye özel ai.images.use ayarı:
// açma/kapama/role bırakma, Sahip kapatılamaz, taşeron listede yok ve
// ayarlanamaz), proje ve stüdyo işlerinde firma kapatması, firma ve kişi
// aylık sınırı, /ai/status yansıması ve firma izolasyonu.
// OpenAI'ye ASLA gidilmez: httptest sahte sunucusu.

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/handler"
	"github.com/Savanooo/ARVEND/backend/internal/platform/openai"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestAISettingsHTTP(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "ai-settings-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	other := mustCreateReadyOrg(t, ctx, d, "ai-settings-org-b")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, other.Organization.ID) })
	orgID := org.Organization.ID

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatal(err)
	}
	otherToken, err := d.issuer.IssueAccessToken(other.Owner.ID, domain.RoleAdmin, other.Organization.ID)
	if err != nil {
		t.Fatal(err)
	}
	adminUser, _ := mustCreateRoleUser(t, ctx, d, orgID, "ai_set_admin", domain.OrgRoleAdmin)
	// Yönetici rolü kaba rolü admin'e çeker; üretimde token da öyle üretilir.
	adminToken, err := d.issuer.IssueAccessToken(adminUser.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatal(err)
	}
	pmUser, pmToken := mustCreateRoleUser(t, ctx, d, orgID, "ai_set_pm", domain.OrgRoleProjectManager)
	fieldUser, fieldToken := mustCreateRoleUser(t, ctx, d, orgID, "ai_set_field", domain.OrgRoleField)
	otherPM, _ := mustCreateRoleUser(t, ctx, d, other.Organization.ID, "ai_set_other_pm", domain.OrgRoleProjectManager)

	// Taşeron hesabı: taşeron kartına bağlı, kilitli Taşeron rolünde.
	card, err := d.supplierSvc.CreateSubcontractorCard(ctx, orgID, service.SupplierInput{LegalName: "Ayar Taşeron"})
	if err != nil {
		t.Fatal(err)
	}
	subUser, _ := mustCreateRoleUser(t, ctx, d, orgID, "ai_set_sub", domain.OrgRoleField)
	if _, err := d.pool.Exec(ctx, `UPDATE users SET supplier_id = $2,
		organization_role_id = (SELECT id FROM organization_roles WHERE organization_id = $3 AND code = 'subcontractor')
		WHERE id = $1`, subUser.ID, card.ID, orgID); err != nil {
		t.Fatal(err)
	}

	p := mustCreateProject(t, ctx, d, orgID, "Ayar Projesi")

	fake := &studioFakeOpenAI{mode: "ok"}
	fakeSrv := httptest.NewServer(fake.handle(t))
	t.Cleanup(fakeSrv.Close)
	client, err := openai.New("sk-test-sahte", openai.WithBaseURL(fakeSrv.URL))
	if err != nil {
		t.Fatal(err)
	}
	const serverMax = 200
	newRouter := func(cfg service.AIImageConfig) (http.Handler, *service.AIImageService) {
		svc := service.NewAIImageService(d.pool, d.q, d.projectSvc, client, cfg)
		if err := svc.ScopeToOrganization(orgID); err != nil {
			t.Fatal(err)
		}
		return httpapi.NewRouter(httpapi.Deps{
			JWT: d.issuer, Queries: d.q, AuthorizationSvc: d.authzSvc,
			Projects: handler.NewProjectHandler(d.projectSvc), AIImages: handler.NewAIImageHandler(svc, d.authzSvc),
			CORSOrigins: []string{"*"},
		}), svc
	}
	router, svc := newRouter(service.AIImageConfig{Model: "gpt-image-2.5-sunburst", MonthlyLimit: serverMax, UserHourlyLimit: 200, Workers: 1})

	const settingsPath = "/api/v1/ai/settings"
	do := func(t *testing.T, method, path, token, body string) (int, map[string]any) {
		t.Helper()
		rec, parsed := rbacDo(t, router, method, path, token, body)
		return rec.Code, parsed
	}
	usersOf := func(body map[string]any) map[string]map[string]any {
		out := map[string]map[string]any{}
		list, _ := body["users"].([]any)
		for _, raw := range list {
			u := raw.(map[string]any)
			out[u["user_id"].(string)] = u
		}
		return out
	}
	processAll := func(t *testing.T) {
		t.Helper()
		for {
			ok, err := svc.ProcessNext(ctx)
			if err != nil {
				t.Fatal(err)
			}
			if !ok {
				return
			}
		}
	}
	studioJob := func(t *testing.T, token string) (int, map[string]any) {
		t.Helper()
		rec, body := studioMultipart(t, router, "/api/v1/ai/studio/jobs", token, map[string]string{"kind": "generate", "prompt": "Kafe tabelası"})
		processAll(t) // süren iş sınırına (2) takılmasın
		return rec.Code, body
	}
	projectJob := func(t *testing.T, token string) (int, map[string]any) {
		t.Helper()
		code, body := do(t, http.MethodPost, "/api/v1/projects/"+p.ID+"/ai-image-jobs", token, `{"kind":"generate","prompt":"Bitmiş salon"}`)
		processAll(t)
		return code, body
	}
	status := func(t *testing.T, token string) map[string]any {
		t.Helper()
		code, body := do(t, http.MethodGet, "/api/v1/ai/status", token, "")
		if code != http.StatusOK {
			t.Fatalf("durum: %d %v", code, body)
		}
		return body
	}
	putSettings := func(t *testing.T, body string) (int, map[string]any) {
		t.Helper()
		return do(t, http.MethodPut, settingsPath, ownerToken, body)
	}
	setUser := func(t *testing.T, token, userID, body string) (int, map[string]any) {
		t.Helper()
		return do(t, http.MethodPut, settingsPath+"/users/"+userID, token, body)
	}
	overrideOf := func(t *testing.T, userID string) string {
		t.Helper()
		var effect string
		err := d.pool.QueryRow(ctx, "SELECT COALESCE((SELECT effect FROM user_permission_overrides WHERE user_id = $1 AND permission_code = $2), '')",
			userID, domain.PermAIImagesUse).Scan(&effect)
		if err != nil {
			t.Fatal(err)
		}
		return effect
	}

	t.Run("01_kapı_yalnızca_rol_yöneticisi", func(t *testing.T) {
		for name, tok := range map[string]string{"pm": pmToken, "saha": fieldToken} {
			if code, body := do(t, http.MethodGet, settingsPath, tok, ""); code != http.StatusForbidden {
				t.Errorf("%s ayarları görmemeli: %d %v", name, code, body)
			}
			if code, _ := do(t, http.MethodPut, settingsPath, tok, `{"enabled":false}`); code != http.StatusForbidden {
				t.Errorf("%s ayar değiştirmemeli: %d", name, code)
			}
			if code, _ := setUser(t, tok, pmUser.ID, `{"can_use":true}`); code != http.StatusForbidden {
				t.Errorf("%s kişiye izin açmamalı: %d", name, code)
			}
		}
		// pm'e ai.images.use kişiye özel verilse bile ayar ekranı kapalı kalır.
		if code, _ := do(t, http.MethodGet, settingsPath, "", ""); code != http.StatusUnauthorized {
			t.Errorf("kimliksiz: %d", code)
		}
		for name, tok := range map[string]string{"sahip": ownerToken, "yönetici": adminToken} {
			if code, body := do(t, http.MethodGet, settingsPath, tok, ""); code != http.StatusOK {
				t.Errorf("%s görmeli: %d %v", name, code, body)
			}
		}
		if st := status(t, ownerToken); st["can_manage"] != true {
			t.Errorf("sahip can_manage: %v", st)
		}
		if st := status(t, pmToken); st["can_manage"] != false {
			t.Errorf("pm can_manage olmamalı: %v", st)
		}
	})

	t.Run("02_varsayılanlar_ve_kişi_listesi", func(t *testing.T) {
		code, body := do(t, http.MethodGet, settingsPath, ownerToken, "")
		if code != http.StatusOK {
			t.Fatalf("%d %v", code, body)
		}
		if body["enabled"] != true || body["monthly_limit"] != nil || body["per_user_monthly_limit"] != nil ||
			body["effective_monthly_limit"] != float64(serverMax) || body["server_max"] != float64(serverMax) ||
			body["used_this_month"] != float64(0) || body["resets_at"] == "" {
			t.Fatalf("varsayılanlar: %v", body)
		}
		list := body["users"].([]any)
		if first := list[0].(map[string]any); first["user_id"] != org.Owner.ID || first["is_owner"] != true {
			t.Errorf("Sahip önce gelmeli: %v", first)
		}
		users := usersOf(body)
		want := map[string]struct {
			canUse bool
			source string
		}{
			org.Owner.ID: {true, "role"}, adminUser.ID: {true, "role"},
			pmUser.ID: {false, "role"}, fieldUser.ID: {false, "role"},
		}
		for id, w := range want {
			u, ok := users[id]
			if !ok {
				t.Fatalf("%s listede yok: %v", id, body)
			}
			if u["can_use"] != w.canUse || u["source"] != w.source {
				t.Errorf("%s: %v (beklenen %v)", u["full_name"], u, w)
			}
		}
		if _, ok := users[subUser.ID]; ok {
			t.Errorf("taşeron hesabı listede olmamalı")
		}
		if _, ok := users[otherPM.ID]; ok {
			t.Errorf("başka firmanın kişisi listede olmamalı")
		}
	})

	t.Run("03_ayar_doğrulama_ve_kayıt", func(t *testing.T) {
		for body, wantText := range map[string]string{
			`{"enabled":true,"monthly_limit":201}`:          "en fazla 200",
			`{"enabled":true,"monthly_limit":-1}`:           "0 ya da daha büyük",
			`{"enabled":true,"per_user_monthly_limit":500}`: "en fazla 200",
			`{"monthly_limit":5}`:                           "açık mı kapalı mı",
		} {
			code, resp := putSettings(t, body)
			if code != http.StatusBadRequest || !strings.Contains(fmt.Sprint(resp["error"]), wantText) {
				t.Errorf("%s: %d %v", body, code, resp)
			}
		}
		code, resp := putSettings(t, `{"enabled":true,"monthly_limit":150,"per_user_monthly_limit":40}`)
		if code != http.StatusOK || resp["monthly_limit"] != float64(150) || resp["effective_monthly_limit"] != float64(150) ||
			resp["per_user_monthly_limit"] != float64(40) {
			t.Fatalf("kayıt: %d %v", code, resp)
		}
		code, resp = putSettings(t, `{"enabled":true,"monthly_limit":null,"per_user_monthly_limit":null}`)
		if code != http.StatusOK || resp["monthly_limit"] != nil || resp["effective_monthly_limit"] != float64(serverMax) {
			t.Fatalf("null = sunucu varsayılanı: %d %v", code, resp)
		}
	})

	t.Run("04_tavan_düşerse_kırpılır", func(t *testing.T) {
		if code, resp := putSettings(t, `{"enabled":true,"monthly_limit":150}`); code != http.StatusOK {
			t.Fatalf("%d %v", code, resp)
		}
		low, _ := newRouter(service.AIImageConfig{Model: "gpt-image-2.5-sunburst", MonthlyLimit: 20, UserHourlyLimit: 200, Workers: 1})
		rec, body := rbacDo(t, low, http.MethodGet, settingsPath, ownerToken, "")
		if rec.Code != http.StatusOK || body["monthly_limit"] != float64(150) || body["effective_monthly_limit"] != float64(20) ||
			body["server_max"] != float64(20) {
			t.Fatalf("kırpma: %d %v", rec.Code, body)
		}
		rec, st := rbacDo(t, low, http.MethodGet, "/api/v1/ai/status", ownerToken, "")
		if q, _ := st["quota"].(map[string]any); rec.Code != http.StatusOK || q["monthly_limit"] != float64(20) {
			t.Fatalf("durumda etkin sınır: %v", st)
		}
		if code, resp := putSettings(t, `{"enabled":true}`); code != http.StatusOK {
			t.Fatalf("%d %v", code, resp)
		}
	})

	t.Run("05_kişi_izni_aç_kapat_role_bırak", func(t *testing.T) {
		if code, body := studioJob(t, pmToken); code != http.StatusForbidden {
			t.Fatalf("pm önce kullanamamalı: %d %v", code, body)
		}
		code, body := setUser(t, ownerToken, pmUser.ID, `{"can_use":true}`)
		if u := usersOf(body)[pmUser.ID]; code != http.StatusOK || u["can_use"] != true || u["source"] != "override_allow" {
			t.Fatalf("pm aç: %d %v", code, body)
		}
		if got := overrideOf(t, pmUser.ID); got != "grant" {
			t.Fatalf("kişiye özel grant yazılmalı (mevcut düzenek): %q", got)
		}
		if st := status(t, pmToken); st["can_use"] != true {
			t.Fatalf("pm durumu: %v", st)
		}
		if code, body := studioJob(t, pmToken); code != http.StatusAccepted {
			t.Fatalf("pm artık kullanabilmeli: %d %v", code, body)
		}
		// Roller & Yetkiler ekranı aynı ayarı görür.
		rec, perms := rbacDo(t, d.router, http.MethodGet, "/api/v1/users/"+pmUser.ID+"/permissions", ownerToken, "")
		if code := rec.Code; code != http.StatusOK || !strings.Contains(fmt.Sprint(perms["granted"]), domain.PermAIImagesUse) {
			t.Fatalf("yetki ekranı grant'ı görmeli: %d %v", rec.Code, perms)
		}

		code, body = setUser(t, adminToken, pmUser.ID, `{"can_use":null}`)
		if u := usersOf(body)[pmUser.ID]; code != http.StatusOK || u["can_use"] != false || u["source"] != "role" {
			t.Fatalf("pm role bırak: %d %v", code, body)
		}
		if got := overrideOf(t, pmUser.ID); got != "" {
			t.Fatalf("ayar silinmeli: %q", got)
		}
		if code, _ := studioJob(t, pmToken); code != http.StatusForbidden {
			t.Fatalf("role bırakınca pm yine kullanamamalı: %d", code)
		}

		// Yönetici rolü izni verir: "kapat" revoke yazar, "aç" ayarı siler.
		code, body = setUser(t, ownerToken, adminUser.ID, `{"can_use":false}`)
		if u := usersOf(body)[adminUser.ID]; code != http.StatusOK || u["can_use"] != false || u["source"] != "override_deny" {
			t.Fatalf("yönetici kapat: %d %v", code, body)
		}
		if got := overrideOf(t, adminUser.ID); got != "revoke" {
			t.Fatalf("revoke yazılmalı: %q", got)
		}
		if st := status(t, adminToken); st["can_use"] != false {
			t.Fatalf("yönetici durumu: %v", st)
		}
		code, body = setUser(t, ownerToken, adminUser.ID, `{"can_use":true}`)
		if u := usersOf(body)[adminUser.ID]; code != http.StatusOK || u["can_use"] != true || u["source"] != "role" {
			t.Fatalf("yönetici aç (rolü veriyor): %d %v", code, body)
		}
		if got := overrideOf(t, adminUser.ID); got != "" {
			t.Fatalf("rolün verdiği izin için ayar tutulmamalı: %q", got)
		}

		if code, body := setUser(t, ownerToken, pmUser.ID, `{}`); code != http.StatusBadRequest {
			t.Errorf("can_use zorunlu: %d %v", code, body)
		}
	})

	t.Run("06_sahip_kapatılamaz_taşeron_ve_başka_firma", func(t *testing.T) {
		code, body := setUser(t, adminToken, org.Owner.ID, `{"can_use":false}`)
		if code != http.StatusConflict || body["error"] != "Sahip her zaman yapay zekâyı kullanabilir; kapatılamaz" {
			t.Fatalf("Sahip kapatma: %d %v", code, body)
		}
		if got := overrideOf(t, org.Owner.ID); got != "" {
			t.Fatalf("Sahip için ayar yazılmamalı: %q", got)
		}
		if code, body := setUser(t, adminToken, org.Owner.ID, `{"can_use":true}`); code != http.StatusOK || usersOf(body)[org.Owner.ID]["can_use"] != true {
			t.Errorf("Sahip aç (değişiklik yok): %d %v", code, body)
		}
		if code, body := setUser(t, ownerToken, subUser.ID, `{"can_use":true}`); code != http.StatusConflict {
			t.Errorf("taşerona izin açılmamalı: %d %v", code, body)
		}
		if got := overrideOf(t, subUser.ID); got != "" {
			t.Errorf("taşeron ayarı yazılmamalı: %q", got)
		}
		if code, _ := setUser(t, ownerToken, otherPM.ID, `{"can_use":true}`); code != http.StatusNotFound {
			t.Errorf("başka firmanın kişisi 404 olmalı: %d", code)
		}
		if code, _ := setUser(t, otherToken, pmUser.ID, `{"can_use":true}`); code != http.StatusNotFound {
			t.Errorf("başka firma bu kişiyi değiştirememeli: %d", code)
		}
		if got := overrideOf(t, otherPM.ID) + overrideOf(t, pmUser.ID); got != "" {
			t.Errorf("çapraz firma yazımı olmamalı: %q", got)
		}
	})

	t.Run("07_kişi_aylık_sınırı_proje_ve_stüdyo", func(t *testing.T) {
		used := int(status(t, ownerToken)["quota"].(map[string]any)["user_used_this_month"].(float64))
		if code, resp := putSettings(t, fmt.Sprintf(`{"enabled":true,"per_user_monthly_limit":%d}`, used+1)); code != http.StatusOK {
			t.Fatalf("%d %v", code, resp)
		}
		code, body := studioJob(t, ownerToken)
		if code != http.StatusAccepted {
			t.Fatalf("hakkın sonuncusu: %d %v", code, body)
		}
		if q := body["quota"].(map[string]any); q["user_remaining"] != float64(0) || q["user_monthly_limit"] != float64(used+1) {
			t.Errorf("iş sonrası kişi hakkı: %v", q)
		}
		wantMsg := fmt.Sprintf("Bu ay sana ayrılan yapay zekâ hakkı doldu (%d/%d)", used+1, used+1)
		for name, job := range map[string]func(*testing.T, string) (int, map[string]any){"stüdyo": studioJob, "proje": projectJob} {
			code, body := job(t, ownerToken)
			if code != http.StatusTooManyRequests || body["code"] != "ai_user_monthly_limit" || body["error"] != wantMsg {
				t.Errorf("%s: %d %v", name, code, body)
			}
		}
		if st := status(t, ownerToken); st["blocked_code"] != "ai_user_monthly_limit" || st["blocked_reason"] != wantMsg {
			t.Errorf("durum kişinin dolduğunu söylemeli: %v", st)
		}
		// Başka kişinin hakkı ayrı.
		if code, body := studioJob(t, adminToken); code != http.StatusAccepted {
			t.Errorf("yönetici yine açabilmeli: %d %v", code, body)
		}
	})

	t.Run("08_firma_aylık_sınırı", func(t *testing.T) {
		used := int(status(t, ownerToken)["quota"].(map[string]any)["used_this_month"].(float64))
		if code, resp := putSettings(t, fmt.Sprintf(`{"enabled":true,"monthly_limit":%d}`, used)); code != http.StatusOK {
			t.Fatalf("%d %v", code, resp)
		}
		for name, job := range map[string]func(*testing.T, string) (int, map[string]any){"stüdyo": studioJob, "proje": projectJob} {
			code, body := job(t, adminToken)
			if code != http.StatusTooManyRequests || body["code"] != "ai_monthly_limit" ||
				!strings.Contains(fmt.Sprint(body["error"]), fmt.Sprintf("(%d/%d)", used, used)) {
				t.Errorf("%s: %d %v", name, code, body)
			}
		}
		if st := status(t, adminToken); st["blocked_code"] != "ai_monthly_limit" {
			t.Errorf("durum: %v", st)
		}
	})

	t.Run("09_firma_kapalı", func(t *testing.T) {
		if code, resp := putSettings(t, `{"enabled":false}`); code != http.StatusOK || resp["enabled"] != false {
			t.Fatalf("%d %v", code, resp)
		}
		before := fake.count()
		for name, job := range map[string]func(*testing.T, string) (int, map[string]any){"stüdyo": studioJob, "proje": projectJob} {
			code, body := job(t, ownerToken)
			if code != http.StatusForbidden || body["code"] != service.AIDisabledByAdminCode ||
				body["error"] != "Yapay zekâ bu firmada yönetici tarafından kapatıldı" {
				t.Errorf("%s: %d %v", name, code, body)
			}
		}
		if fake.count() != before {
			t.Errorf("kapalıyken OpenAI'ye gidilmemeli")
		}
		st := status(t, ownerToken)
		if st["enabled"] != false || st["server_enabled"] != true || st["firm_enabled"] != false ||
			st["blocked_code"] != service.AIDisabledByAdminCode || st["can_use"] != true {
			t.Errorf("durum kapalıyı yansıtmalı: %v", st)
		}
		// Ayar ekranı kapalıyken de çalışır (yeniden açılabilsin).
		if code, resp := putSettings(t, `{"enabled":true}`); code != http.StatusOK || resp["enabled"] != true {
			t.Fatalf("yeniden açma: %d %v", code, resp)
		}
		if st := status(t, ownerToken); st["enabled"] != true || st["firm_enabled"] != true {
			t.Errorf("açınca: %v", st)
		}
	})

	t.Run("10_firma_izolasyonu", func(t *testing.T) {
		if code, resp := putSettings(t, `{"enabled":false,"monthly_limit":3}`); code != http.StatusOK {
			t.Fatalf("%d %v", code, resp)
		}
		t.Cleanup(func() { putSettings(t, `{"enabled":true}`) })
		code, body := do(t, http.MethodGet, settingsPath, otherToken, "")
		if code != http.StatusOK || body["enabled"] != true || body["monthly_limit"] != nil || body["used_this_month"] != float64(0) {
			t.Fatalf("başka firma kendi varsayılanını görmeli: %d %v", code, body)
		}
		users := usersOf(body)
		if _, ok := users[pmUser.ID]; ok || len(users) == 0 {
			t.Fatalf("başka firmanın listesi yalnızca kendi kişileri: %v", body)
		}
		if st := status(t, otherToken); st["firm_enabled"] != true {
			t.Errorf("başka firmanın durumu etkilenmemeli: %v", st)
		}
	})
}
