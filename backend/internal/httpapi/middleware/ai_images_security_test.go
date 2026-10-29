package middleware_test

// Yapay zekâ görselleri (migration 0079) HTTP katmanında: anahtar yoksa 503
// + "kapalı" durumu, ai.images.use izni (varsayılan yalnızca Sahip/
// Yönetici), proje erişimi, firma izolasyonu, aylık sınırın 429'u ve iş
// yaşam döngüsü (202 sırada -> GET bitti -> fotoğraf listesinde işaretli).
// Taşeron hesabının bu uçlara giremediğini subcontractor_portal_security_
// test.go'nun bütün rotaları gezen testi kendiliğinden kapsar.
// OpenAI'ye ASLA gidilmez: httptest sahte sunucusu.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/handler"
	"github.com/Savanooo/ARVEND/backend/internal/platform/openai"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func aiTestJPEG(t *testing.T, shade uint8) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 32, 24))
	for x := 0; x < 32; x++ {
		for y := 0; y < 24; y++ {
			img.Set(x, y, color.RGBA{R: shade, G: 120, B: 60, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, nil); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestAIImagesHTTP(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "ai-images-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	other := mustCreateReadyOrg(t, ctx, d, "ai-images-org-b")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, other.Organization.ID) })
	orgID := org.Organization.ID

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatal(err)
	}
	otherOwnerToken, err := d.issuer.IssueAccessToken(other.Owner.ID, domain.RoleAdmin, other.Organization.ID)
	if err != nil {
		t.Fatal(err)
	}
	pmUser, pmToken := mustCreateRoleUser(t, ctx, d, orgID, "ai_pm", domain.OrgRoleProjectManager)
	fieldUser, fieldToken := mustCreateRoleUser(t, ctx, d, orgID, "ai_field", domain.OrgRoleField)

	p := mustCreateProject(t, ctx, d, orgID, "YZ Proje (üye)")
	p2 := mustCreateProject(t, ctx, d, orgID, "YZ Proje (üye değil)")
	for _, u := range []*domain.User{pmUser, fieldUser} {
		if _, err := d.authzSvc.AddProjectUser(ctx, p.ID, orgID, service.ProjectUserInput{
			UserID: u.ID, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
		}); err != nil {
			t.Fatal(err)
		}
	}
	src, err := d.projectSvc.UploadPhoto(ctx, p.ID, orgID, service.UploadInput{
		OriginalName: "oda.jpg", Reader: bytes.NewReader(aiTestJPEG(t, 10)), Stage: domain.PhotoStageBefore, UserID: org.Owner.ID,
	})
	if err != nil {
		t.Fatal(err)
	}

	var seq atomic.Int32
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer sk-test-sahte" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		n := seq.Add(1)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(aiTestJPEG(t, uint8(100+n)))}},
		})
	}))
	t.Cleanup(fake.Close)
	client, err := openai.New("sk-test-sahte", openai.WithBaseURL(fake.URL))
	if err != nil {
		t.Fatal(err)
	}
	cfg := service.AIImageConfig{Model: "gpt-image-2.5-sunburst", Quality: "medium", MonthlyLimit: 2, UserHourlyLimit: 10, Workers: 1}
	newAIRouter := func(gen service.ImageGenerator) (http.Handler, *service.AIImageService) {
		svc := service.NewAIImageService(d.pool, d.q, d.projectSvc, gen, cfg)
		if err := svc.ScopeToOrganization(orgID); err != nil {
			t.Fatal(err)
		}
		// Yalnızca bu testin dokunduğu uçların handler'ları; diğerleri nil
		// (çağrılmadıkça zararsız, bkz. router_test.go).
		return httpapi.NewRouter(httpapi.Deps{
			JWT: d.issuer, Queries: d.q, AuthorizationSvc: d.authzSvc,
			Projects: handler.NewProjectHandler(d.projectSvc), AIImages: handler.NewAIImageHandler(svc),
			CORSOrigins: []string{"*"},
		}), svc
	}
	offRouter, _ := newAIRouter(nil)
	router, svc := newAIRouter(client)

	jobsPath := "/api/v1/projects/" + p.ID + "/ai-image-jobs"
	beforeAfter := `{"kind":"before_after","prompt":"Alçıpan asma tavan, spot ışıklı","source_photo_id":"` + src.ID + `"}`

	t.Run("1_anahtar_yoksa_503_ve_durum_kapalı", func(t *testing.T) {
		rec, body := rbacDo(t, offRouter, http.MethodGet, "/api/v1/ai/status", ownerToken, "")
		if rec.Code != http.StatusOK || body["enabled"] != false || body["can_use"] != true {
			t.Fatalf("durum: %d %v", rec.Code, body)
		}
		rec, body = rbacDo(t, offRouter, http.MethodPost, jobsPath, ownerToken, beforeAfter)
		if rec.Code != http.StatusServiceUnavailable || body["code"] != "ai_disabled" ||
			body["error"] != "Yapay zekâ özelliği bu sunucuda ayarlı değil" {
			t.Fatalf("kapalıyken iş: %d %v", rec.Code, body)
		}
	})

	t.Run("2_kimliksiz_401", func(t *testing.T) {
		if rec, _ := rbacDo(t, router, http.MethodGet, "/api/v1/ai/status", "", ""); rec.Code != http.StatusUnauthorized {
			t.Errorf("durum: %d", rec.Code)
		}
		if rec, _ := rbacDo(t, router, http.MethodPost, jobsPath, "", beforeAfter); rec.Code != http.StatusUnauthorized {
			t.Errorf("iş: %d", rec.Code)
		}
	})

	t.Run("3_varsayılan_izin_yalnızca_sahip_yönetici", func(t *testing.T) {
		for name, tok := range map[string]string{"saha": fieldToken, "proje yöneticisi": pmToken} {
			rec, body := rbacDo(t, router, http.MethodPost, jobsPath, tok, beforeAfter)
			if rec.Code != http.StatusForbidden || body["code"] != "permission_denied" {
				t.Errorf("%s iş açamamalı: %d %v", name, rec.Code, body)
			}
			rec, body = rbacDo(t, router, http.MethodGet, "/api/v1/ai/status", tok, "")
			if rec.Code != http.StatusOK || body["enabled"] != true || body["can_use"] != false || body["quota"] != nil {
				t.Errorf("%s durumu: %d %v", name, rec.Code, body)
			}
			if _, ok := body["usage_by_user"]; ok {
				t.Errorf("%s kişi kişi kullanımı görmemeli", name)
			}
		}
	})

	t.Run("4_sahip_iş_açar_sırada_bitti_fotoğraf_işaretli", func(t *testing.T) {
		rec, body := rbacDo(t, router, http.MethodPost, jobsPath, ownerToken, beforeAfter)
		if rec.Code != http.StatusAccepted {
			t.Fatalf("iş açılamadı: %d %v", rec.Code, body)
		}
		job := body["job"].(map[string]any)
		quota := body["quota"].(map[string]any)
		if job["status"] != "queued" || job["kind"] != "before_after" || job["source_photo_id"] != src.ID ||
			quota["remaining"] != 1.0 || quota["monthly_limit"] != 2.0 {
			t.Fatalf("yanıt: %v", body)
		}
		jobPath := jobsPath + "/" + job["id"].(string)
		if rec, body := rbacDo(t, router, http.MethodGet, jobPath, ownerToken, ""); rec.Code != http.StatusOK || body["status"] != "queued" {
			t.Fatalf("sırada: %d %v", rec.Code, body)
		}
		if ok, err := svc.ProcessNext(ctx); !ok || err != nil {
			t.Fatalf("işlenemedi: %v %v", ok, err)
		}
		rec, body = rbacDo(t, router, http.MethodGet, jobPath, ownerToken, "")
		resultID, _ := body["result_photo_id"].(string)
		if rec.Code != http.StatusOK || body["status"] != "done" || resultID == "" || body["error"] != "" {
			t.Fatalf("bitti: %d %v", rec.Code, body)
		}

		rec, body = rbacDo(t, router, http.MethodGet, "/api/v1/projects/"+p.ID+"/photos", ownerToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("fotoğraflar: %d", rec.Code)
		}
		var sawSource, sawResult bool
		for _, raw := range body["photos"].([]any) {
			ph := raw.(map[string]any)
			switch ph["id"] {
			case src.ID:
				sawSource = true
				if ph["ai_generated"] != false || ph["ai"] != nil {
					t.Errorf("kaynak işaretlenmemeli: %v", ph)
				}
			case resultID:
				sawResult = true
				ai, _ := ph["ai"].(map[string]any)
				if ph["ai_generated"] != true || ai["kind"] != "before_after" || ai["source_photo_id"] != src.ID ||
					ai["prompt"] != "Alçıpan asma tavan, spot ışıklı" || ai["source_date"] == nil || ph["stage"] != "after" {
					t.Errorf("sonuç: %v", ph)
				}
			}
		}
		if !sawSource || !sawResult {
			t.Fatalf("kaynak %v, sonuç %v listede olmalı", sawSource, sawResult)
		}
		// Üretilen görsel de normal fotoğraf gibi açılır.
		if rec, _ := rbacDo(t, router, http.MethodGet, "/api/v1/projects/"+p.ID+"/photos/"+resultID+"/content", ownerToken, ""); rec.Code != http.StatusOK ||
			rec.Header().Get("Content-Type") != "image/jpeg" {
			t.Errorf("görsel indirilemedi: %d %s", rec.Code, rec.Header().Get("Content-Type"))
		}
		rec, body = rbacDo(t, router, http.MethodGet, jobsPath, ownerToken, "")
		if jobs, _ := body["jobs"].([]any); rec.Code != http.StatusOK || len(jobs) != 1 {
			t.Errorf("iş listesi: %d %v", rec.Code, body)
		}
	})

	t.Run("5_kişiye_özel_izinle_proje_yöneticisi_yalnızca_üyesi_olduğu_projede", func(t *testing.T) {
		if _, err := d.pool.Exec(ctx,
			"INSERT INTO user_permission_overrides (user_id, organization_id, permission_code, effect) VALUES ($1, $2, $3, 'grant')",
			pmUser.ID, orgID, domain.PermAIImagesUse); err != nil {
			t.Fatal(err)
		}
		rec, body := rbacDo(t, router, http.MethodPost, "/api/v1/projects/"+p2.ID+"/ai-image-jobs", pmToken,
			`{"kind":"generate","prompt":"Cephe"}`)
		if rec.Code != http.StatusForbidden || body["code"] != "project_access_denied" {
			t.Errorf("üye olmadığı proje: %d %v", rec.Code, body)
		}
		rec, body = rbacDo(t, router, http.MethodPost, jobsPath, pmToken, `{"kind":"generate","prompt":"Banyo seramik, duşakabin"}`)
		if rec.Code != http.StatusAccepted {
			t.Fatalf("izinli PM: %d %v", rec.Code, body)
		}
		pmJob := body["job"].(map[string]any)["id"].(string)
		// İşi yalnızca açan kişi izler: Sahip de dahil başkası 404 alır.
		if rec, _ := rbacDo(t, router, http.MethodGet, jobsPath+"/"+pmJob, ownerToken, ""); rec.Code != http.StatusNotFound {
			t.Errorf("başkasının işi: %d", rec.Code)
		}
		if ok, err := svc.ProcessNext(ctx); !ok || err != nil {
			t.Fatalf("işlenemedi: %v %v", ok, err)
		}
	})

	t.Run("6_başka_firma_görmez_açamaz", func(t *testing.T) {
		// Sahip üyelikten muaf: kapı geçer, servis firmaya göre 404 döner.
		rec, body := rbacDo(t, router, http.MethodPost, jobsPath, otherOwnerToken, beforeAfter)
		if rec.Code != http.StatusNotFound {
			t.Errorf("başka firmanın projesinde iş: %d %v", rec.Code, body)
		}
		rec, body = rbacDo(t, router, http.MethodGet, jobsPath, otherOwnerToken, "")
		if jobs, _ := body["jobs"].([]any); rec.Code == http.StatusOK && len(jobs) != 0 {
			t.Errorf("başka firma işleri görmemeli: %v", body)
		}
		rec, body = rbacDo(t, router, http.MethodGet, "/api/v1/ai/status", otherOwnerToken, "")
		if q, _ := body["quota"].(map[string]any); rec.Code != http.StatusOK || q["used_this_month"] != 0.0 {
			t.Errorf("başka firmanın hakkı ayrı: %d %v", rec.Code, body)
		}
	})

	t.Run("7_aylık_sınır_429_kalan_hakla", func(t *testing.T) {
		rec, body := rbacDo(t, router, http.MethodPost, jobsPath, ownerToken, beforeAfter)
		if rec.Code != http.StatusTooManyRequests || body["code"] != "ai_monthly_limit" || body["remaining"] != 0.0 ||
			!strings.Contains(body["error"].(string), "2/2") {
			t.Fatalf("aylık sınır: %d %v", rec.Code, body)
		}
		rec, body = rbacDo(t, router, http.MethodGet, "/api/v1/ai/status", ownerToken, "")
		q, _ := body["quota"].(map[string]any)
		usage, _ := body["usage_by_user"].([]any)
		if rec.Code != http.StatusOK || q["used_this_month"] != 2.0 || q["remaining"] != 0.0 || len(usage) != 2 {
			t.Errorf("sahip durumu: %d %v", rec.Code, body)
		}
	})

	t.Run("8_hatalı_istek_400", func(t *testing.T) {
		for _, b := range []string{`{"kind":"boya","prompt":"x"}`, `{"kind":"generate"}`, `{"kind":"generate","prompt":"x","fazla":1}`} {
			if rec, body := rbacDo(t, router, http.MethodPost, jobsPath, ownerToken, b); rec.Code != http.StatusBadRequest {
				t.Errorf("%s: %d %v", b, rec.Code, body)
			}
		}
	})

}
