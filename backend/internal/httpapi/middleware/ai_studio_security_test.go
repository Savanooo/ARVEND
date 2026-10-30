package middleware_test

// Yapay Zekâ Stüdyo (migration 0080) HTTP katmanında: projesiz işler (bütün
// türler, yükleme doğrulaması, kaynak proje fotoğrafı ve stüdyo görseli),
// görünürlük (kendi / Sahip-Yönetici firma geneli), indirme ve silme
// kuralları, "Projeye ekle" (erişim, izin, tekrar aynı fotoğraf, işaret),
// bölge düzenleme maskesi (stüdyo ve proje ucu), proje ucunun yeni 'edit'
// türü, proje işleriyle ORTAK hak/sınır, firma izolasyonu, açılış
// kurtarması ve eski proje ucunun değişmeden çalışması.
// OpenAI'ye ASLA gidilmez: httptest sahte sunucusu.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"image/png"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/handler"
	"github.com/Savanooo/ARVEND/backend/internal/platform/openai"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func studioJPEG(t *testing.T, w, h int, shade uint8) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for x := 0; x < w; x++ {
		for y := 0; y < h; y++ {
			img.Set(x, y, color.RGBA{R: shade, G: 80, B: 160, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, nil); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func studioPNG(t *testing.T, w, h int, shade uint8) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for x := 0; x < w; x++ {
		for y := 0; y < h; y++ {
			img.Set(x, y, color.RGBA{R: 30, G: shade, B: 60, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// studioMask: w×h alfa maskesi -- sol yarısı saydam (kalemle boyanan yer).
func studioMask(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for x := 0; x < w; x++ {
		for y := 0; y < h; y++ {
			a := uint8(255)
			if x < w/2 {
				a = 0
			}
			img.SetNRGBA(x, y, color.NRGBA{A: a})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// studioWithEXIFOrientation: SOI'den sonra yalnızca Orientation etiketli bir
// EXIF APP1 bölümü (little-endian) -- telefon kamerasının yaptığı gibi.
func studioWithEXIFOrientation(jpg []byte, orientation byte) []byte {
	tiff := []byte{'I', 'I', 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0, orientation, 0, 0, 0, 0, 0, 0, 0}
	payload := append([]byte("Exif\x00\x00"), tiff...)
	seg := append([]byte{0xFF, 0xE1, byte((len(payload) + 2) >> 8), byte(len(payload) + 2)}, payload...)
	out := append([]byte{}, jpg[:2]...)
	out = append(out, seg...)
	return append(out, jpg[2:]...)
}

type studioPart struct {
	field, name string
	data        []byte
}

// studioMultipart: multipart/form-data isteği (uygulamanın Dio FormData'sı gibi).
func studioMultipart(t *testing.T, router http.Handler, path, token string, fields map[string]string, files ...studioPart) (*httptest.ResponseRecorder, map[string]any) {
	t.Helper()
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	for k, v := range fields {
		if err := w.WriteField(k, v); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range files {
		part, err := w.CreateFormFile(f.field, f.name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := part.Write(f.data); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, path, &buf)
	req.Header.Set("Content-Type", w.FormDataContentType())
	if token != "" {
		req.AddCookie(&http.Cookie{Name: "access_token", Value: token})
	}
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	var parsed map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &parsed)
	return rec, parsed
}

func studioGetRaw(t *testing.T, router http.Handler, path, token string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	req.AddCookie(&http.Cookie{Name: "access_token", Value: token})
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	return rec
}

type studioFakeCall struct {
	Path, Prompt string
	Image        []byte
	ImageType    string
	Mask         []byte
	// Images: bütün image[] parçaları (maskeli işte ikincisi işaretli kaynak).
	Images [][]byte
}

// studioFakeOpenAI: sahte Images API; her yanıt farklı bayt, son yanıt saklanır.
type studioFakeOpenAI struct {
	mu      sync.Mutex
	mode    string
	calls   []studioFakeCall
	outputs [][]byte
	seq     int
}

func (f *studioFakeOpenAI) handle(t *testing.T) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer sk-test-sahte" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		call := studioFakeCall{Path: r.URL.Path}
		if strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/") {
			if err := r.ParseMultipartForm(64 << 20); err == nil {
				call.Prompt = r.FormValue("prompt")
				read := func(field string) ([]byte, string) {
					fhs := r.MultipartForm.File[field]
					if len(fhs) == 0 {
						return nil, ""
					}
					fh, _ := fhs[0].Open()
					defer fh.Close()
					b, _ := io.ReadAll(fh)
					return b, fhs[0].Header.Get("Content-Type")
				}
				call.Image, call.ImageType = read("image[]")
				call.Mask, _ = read("mask")
				for _, fh := range r.MultipartForm.File["image[]"] {
					f, _ := fh.Open()
					b, _ := io.ReadAll(f)
					f.Close()
					call.Images = append(call.Images, b)
				}
			}
		} else {
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			call.Prompt = fmt.Sprint(body["prompt"])
		}
		f.mu.Lock()
		f.calls = append(f.calls, call)
		mode := f.mode
		f.seq++
		out := studioJPEG(t, 24, 16, uint8(f.seq*5))
		f.outputs = append(f.outputs, out)
		f.mu.Unlock()
		if mode == "moderation" {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":{"message":"Your request was rejected by the safety system.","type":"image_generation_user_error","code":"moderation_blocked"}}`))
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(out)}},
		})
	}
}

func (f *studioFakeOpenAI) setMode(m string) {
	f.mu.Lock()
	f.mode = m
	f.mu.Unlock()
}

func (f *studioFakeOpenAI) last() (studioFakeCall, []byte) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls[len(f.calls)-1], f.outputs[len(f.outputs)-1]
}

func (f *studioFakeOpenAI) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

func TestAIStudioHTTP(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "ai-studio-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	other := mustCreateReadyOrg(t, ctx, d, "ai-studio-org-b")
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
	_, adminToken := mustCreateRoleUser(t, ctx, d, orgID, "ai_studio_admin", domain.OrgRoleAdmin)
	pmUser, pmToken := mustCreateRoleUser(t, ctx, d, orgID, "ai_studio_pm", domain.OrgRoleProjectManager)
	finUser, finToken := mustCreateRoleUser(t, ctx, d, orgID, "ai_studio_fin", domain.OrgRoleFinance)
	_, fieldToken := mustCreateRoleUser(t, ctx, d, orgID, "ai_studio_field", domain.OrgRoleField)
	// Yapay zekâ varsayılan yalnızca Sahip/Yönetici: PM ve finansa kişiye özel izin.
	for _, u := range []*domain.User{pmUser, finUser} {
		if _, err := d.pool.Exec(ctx,
			"INSERT INTO user_permission_overrides (user_id, organization_id, permission_code, effect) VALUES ($1, $2, $3, 'grant')",
			u.ID, orgID, domain.PermAIImagesUse); err != nil {
			t.Fatal(err)
		}
	}

	p := mustCreateProject(t, ctx, d, orgID, "Stüdyo Proje (üye)")
	p2 := mustCreateProject(t, ctx, d, orgID, "Stüdyo Proje (üye değil)")
	pClosed := mustCreateProject(t, ctx, d, orgID, "Stüdyo Proje (kapalı)")
	pOther := mustCreateProject(t, ctx, d, other.Organization.ID, "Başka Firma Projesi")
	if _, err := d.authzSvc.AddProjectUser(ctx, p.ID, orgID, service.ProjectUserInput{
		UserID: pmUser.ID, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := d.pool.Exec(ctx, "UPDATE projects SET status = $2 WHERE id = $1", pClosed.ID, domain.ProjectStatusCompleted); err != nil {
		t.Fatal(err)
	}
	srcBytes := studioJPEG(t, 32, 24, 10)
	src, err := d.projectSvc.UploadPhoto(ctx, p.ID, orgID, service.UploadInput{
		OriginalName: "salon.jpg", Reader: bytes.NewReader(srcBytes), Stage: domain.PhotoStageBefore, UserID: org.Owner.ID,
	})
	if err != nil {
		t.Fatal(err)
	}
	srcP2, err := d.projectSvc.UploadPhoto(ctx, p2.ID, orgID, service.UploadInput{
		OriginalName: "ofis.jpg", Reader: bytes.NewReader(studioJPEG(t, 32, 24, 20)), UserID: org.Owner.ID,
	})
	if err != nil {
		t.Fatal(err)
	}

	fake := &studioFakeOpenAI{mode: "ok"}
	fakeSrv := httptest.NewServer(fake.handle(t))
	t.Cleanup(fakeSrv.Close)
	client, err := openai.New("sk-test-sahte", openai.WithBaseURL(fakeSrv.URL))
	if err != nil {
		t.Fatal(err)
	}
	baseCfg := service.AIImageConfig{Model: "gpt-image-2.5-sunburst", Quality: "medium", MonthlyLimit: 200, UserHourlyLimit: 200, Workers: 1}
	newRouter := func(gen service.ImageGenerator, cfg service.AIImageConfig) (http.Handler, *service.AIImageService) {
		svc := service.NewAIImageService(d.pool, d.q, d.projectSvc, gen, cfg)
		if err := svc.ScopeToOrganization(orgID); err != nil {
			t.Fatal(err)
		}
		return httpapi.NewRouter(httpapi.Deps{
			JWT: d.issuer, Queries: d.q, AuthorizationSvc: d.authzSvc,
			Projects: handler.NewProjectHandler(d.projectSvc), AIImages: handler.NewAIImageHandler(svc, d.authzSvc),
			CORSOrigins: []string{"*"},
		}), svc
	}
	offRouter, _ := newRouter(nil, baseCfg)
	router, svc := newRouter(client, baseCfg)

	const jobsPath = "/api/v1/ai/studio/jobs"
	const imagesPath = "/api/v1/ai/studio/images"
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
	jobOf := func(t *testing.T, rec *httptest.ResponseRecorder, body map[string]any) map[string]any {
		t.Helper()
		if rec.Code != http.StatusAccepted {
			t.Fatalf("iş açılamadı: %d %v", rec.Code, body)
		}
		job, ok := body["job"].(map[string]any)
		if !ok {
			t.Fatalf("yanıtta job yok: %v", body)
		}
		return job
	}
	openStudio := func(t *testing.T, token string, fields map[string]string, files ...studioPart) map[string]any {
		t.Helper()
		rec, body := studioMultipart(t, router, jobsPath, token, fields, files...)
		return jobOf(t, rec, body)
	}
	getJob := func(t *testing.T, token, id string) (int, map[string]any) {
		t.Helper()
		rec, body := rbacDo(t, router, http.MethodGet, jobsPath+"/"+id, token, "")
		return rec.Code, body
	}
	// runStudio: işi açar, işler, bitmiş işi ve sonuç görselinin kimliğini döner.
	runStudio := func(t *testing.T, token string, fields map[string]string, files ...studioPart) (map[string]any, string) {
		t.Helper()
		job := openStudio(t, token, fields, files...)
		processAll(t)
		code, done := getJob(t, token, job["id"].(string))
		imageID, _ := done["studio_image_id"].(string)
		if code != http.StatusOK || done["status"] != "done" || imageID == "" || done["error"] != nil {
			t.Fatalf("iş bitmedi: %d %v", code, done)
		}
		return done, imageID
	}
	listImages := func(t *testing.T, token, query string) (int, map[string]any) {
		t.Helper()
		rec, body := rbacDo(t, router, http.MethodGet, imagesPath+query, token, "")
		return rec.Code, body
	}
	imageIDs := func(body map[string]any) map[string]map[string]any {
		out := map[string]map[string]any{}
		images, _ := body["images"].([]any)
		for _, raw := range images {
			img := raw.(map[string]any)
			out[img["id"].(string)] = img
		}
		return out
	}
	projectPhotos := func(t *testing.T, projectID string) map[string]map[string]any {
		t.Helper()
		rec, body := rbacDo(t, router, http.MethodGet, "/api/v1/projects/"+projectID+"/photos", ownerToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("fotoğraflar: %d %v", rec.Code, body)
		}
		out := map[string]map[string]any{}
		for _, raw := range body["photos"].([]any) {
			ph := raw.(map[string]any)
			out[ph["id"].(string)] = ph
		}
		return out
	}
	countJobs := func(t *testing.T) int {
		t.Helper()
		var n int
		if err := d.pool.QueryRow(ctx, "SELECT count(*) FROM ai_image_jobs WHERE organization_id = $1", orgID).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}

	var (
		ownerGenImage string // sahibin "yeni görsel"i
		ownerEditJob  map[string]any
		ownerEnhImage string // proje fotoğrafından iyileştirme (kaynak bağı)
		pmImage       string
	)

	t.Run("01_anahtar_yoksa_503", func(t *testing.T) {
		rec, body := studioMultipart(t, offRouter, jobsPath, ownerToken, map[string]string{"kind": "generate", "prompt": "Kafe tabelası"})
		if rec.Code != http.StatusServiceUnavailable || body["code"] != "ai_disabled" {
			t.Fatalf("kapalıyken: %d %v", rec.Code, body)
		}
	})

	t.Run("02_izinsiz_403_kimliksiz_401", func(t *testing.T) {
		if rec, body := studioMultipart(t, router, jobsPath, fieldToken, map[string]string{"kind": "generate", "prompt": "x"}); rec.Code != http.StatusForbidden || body["code"] != "permission_denied" {
			t.Errorf("saha iş açmamalı: %d %v", rec.Code, body)
		}
		if code, body := listImages(t, fieldToken, ""); code != http.StatusForbidden {
			t.Errorf("saha listeyi görmemeli: %d %v", code, body)
		}
		if rec, _ := studioMultipart(t, router, jobsPath, "", map[string]string{"kind": "generate", "prompt": "x"}); rec.Code != http.StatusUnauthorized {
			t.Errorf("kimliksiz: %d", rec.Code)
		}
	})

	t.Run("03_yeni_görsel_projeye_dokunmaz", func(t *testing.T) {
		before := len(projectPhotos(t, p.ID))
		rec, body := studioMultipart(t, router, jobsPath, ownerToken, map[string]string{"kind": "generate", "prompt": "  Kafe tabelası, ahşap  "})
		job := jobOf(t, rec, body)
		if job["status"] != "queued" || job["kind"] != "generate" || job["prompt"] != "Kafe tabelası, ahşap" ||
			job["error"] != nil || job["studio_image_id"] != nil || body["limit"] != 200.0 || body["remaining"] == nil {
			t.Fatalf("yanıt: %v", body)
		}
		if _, ok := job["project_id"]; ok {
			t.Error("stüdyo işinde proje alanı olmamalı")
		}
		if code, got := getJob(t, ownerToken, job["id"].(string)); code != http.StatusOK || got["status"] != "queued" {
			t.Fatalf("sırada: %d %v", code, got)
		}
		processAll(t)
		code, done := getJob(t, ownerToken, job["id"].(string))
		if code != http.StatusOK || done["status"] != "done" || done["studio_image_id"] == nil {
			t.Fatalf("bitti: %d %v", code, done)
		}
		ownerGenImage = done["studio_image_id"].(string)
		call, out := fake.last()
		if call.Path != "/images/generations" || !strings.Contains(call.Prompt, "Kafe tabelası, ahşap") ||
			strings.Contains(call.Prompt, "construction") || call.Image != nil {
			t.Errorf("OpenAI isteği: %+v", call)
		}
		content := studioGetRaw(t, router, imagesPath+"/"+ownerGenImage+"/content", ownerToken)
		if content.Code != http.StatusOK || content.Header().Get("Content-Type") != "image/jpeg" || !bytes.Equal(content.Body.Bytes(), out) ||
			content.Header().Get("X-Content-Type-Options") != "nosniff" {
			t.Errorf("içerik: %d %s", content.Code, content.Header().Get("Content-Type"))
		}
		if after := len(projectPhotos(t, p.ID)); after != before {
			t.Errorf("stüdyo işi projeye fotoğraf eklememeli: %d -> %d", before, after)
		}
		code, list := listImages(t, ownerToken, "")
		img := imageIDs(list)[ownerGenImage]
		if code != http.StatusOK || img == nil || img["kind"] != "generate" || img["user_name"] != "Matrix Owner" ||
			img["user_id"] != org.Owner.ID || img["mime"] != "image/jpeg" || img["size_bytes"].(float64) <= 0 {
			t.Fatalf("liste: %d %v", code, list)
		}
		if projects, ok := img["projects"].([]any); !ok || len(projects) != 0 {
			t.Errorf("projects boş dizi olmalı: %v", img["projects"])
		}
		// Dosyasız istek JSON da olabilir.
		rec, body = rbacDo(t, router, http.MethodPost, jobsPath, ownerToken, `{"kind":"generate","prompt":"Broşür kapağı"}`)
		jobOf(t, rec, body)
		processAll(t)
	})

	t.Run("04_düzenle_bitmiş_hali_iyileştir_yüklenen_fotoğrafla", func(t *testing.T) {
		upload := studioJPEG(t, 32, 24, 40)
		done, _ := runStudio(t, ownerToken, map[string]string{"kind": "edit", "prompt": "duvarı griye boya"},
			studioPart{"image", "foto.jpg", upload})
		ownerEditJob = done
		call, _ := fake.last()
		if call.Path != "/images/edits" || !bytes.Equal(call.Image, upload) || call.Mask != nil ||
			!strings.Contains(call.Prompt, "Apply only the requested change") || !strings.Contains(call.Prompt, "duvarı griye boya") {
			t.Errorf("düzenleme isteği: path=%s maske=%v prompt=%q", call.Path, call.Mask != nil, call.Prompt)
		}

		pngUpload := studioPNG(t, 32, 24, 70)
		runStudio(t, ownerToken, map[string]string{"kind": "before_after", "prompt": "Alçıpan asma tavan, spot ışıklı"},
			studioPart{"image", "oda.png", pngUpload})
		call, _ = fake.last()
		if !bytes.Equal(call.Image, pngUpload) || call.ImageType != "image/png" || !strings.Contains(call.Prompt, "same perspective") {
			t.Errorf("bitmiş hali isteği: tür=%s prompt=%q", call.ImageType, call.Prompt)
		}

		webp := append([]byte("RIFF\x00\x00\x00\x00WEBPVP8 "), bytes.Repeat([]byte{7}, 64)...)
		runStudio(t, ownerToken, map[string]string{"kind": "enhance"}, studioPart{"image", "karanlik.webp", webp})
		call, _ = fake.last()
		if !bytes.Equal(call.Image, webp) || call.ImageType != "image/webp" || !strings.Contains(call.Prompt, "Do not add, remove") {
			t.Errorf("iyileştirme isteği: tür=%s prompt=%q", call.ImageType, call.Prompt)
		}
	})

	t.Run("05_yükleme_doğrulaması_400_iş_açılmaz", func(t *testing.T) {
		jobsBefore, callsBefore := countJobs(t), fake.count()
		var g bytes.Buffer
		if err := gif.Encode(&g, image.NewPaletted(image.Rect(0, 0, 4, 4), []color.Color{color.White, color.Black}), nil); err != nil {
			t.Fatal(err)
		}
		heic := append([]byte("\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic"), make([]byte, 64)...)
		edit := map[string]string{"kind": "edit", "prompt": "duvarı griye boya"}
		cases := []struct {
			name   string
			fields map[string]string
			files  []studioPart
			code   int
			want   string
		}{
			{"HEIC", edit, []studioPart{{"image", "IMG_0001.HEIC", heic}}, 400, "HEIC"},
			{"metin dosyası", edit, []studioPart{{"image", "not.jpg", []byte("bu bir fotoğraf değil")}}, 400, "JPEG, PNG ya da WebP"},
			{"GIF", edit, []studioPart{{"image", "a.gif", g.Bytes()}}, 400, "JPEG, PNG ya da WebP"},
			{"bozuk JPEG", edit, []studioPart{{"image", "b.jpg", []byte("\xff\xd8\xff\xe0bozuk")}}, 400, "okunamadı"},
			{"boş dosya", edit, []studioPart{{"image", "c.jpg", nil}}, 400, "boş dosya"},
			{"25 MB üstü", edit, []studioPart{{"image", "d.jpg", make([]byte, service.MaxUploadBytes+1)}}, 413, "25 MB"},
			{"kaynaksız düzenleme", edit, nil, 400, "fotoğraf seçin"},
			{"yeni görselde fotoğraf", map[string]string{"kind": "generate", "prompt": "x"}, []studioPart{{"image", "e.jpg", studioJPEG(t, 8, 8, 1)}}, 400, "yalnızca açıklamadan"},
			{"iki kaynak", map[string]string{"kind": "edit", "prompt": "x", "source_project_photo_id": src.ID}, []studioPart{{"image", "f.jpg", studioJPEG(t, 8, 8, 2)}}, 400, "Tek bir kaynak"},
			{"açıklamasız düzenleme", map[string]string{"kind": "edit"}, []studioPart{{"image", "g.jpg", studioJPEG(t, 8, 8, 3)}}, 400, "kısaca yazın"},
			{"geçersiz tür", map[string]string{"kind": "boya", "prompt": "x"}, nil, 400, "Geçersiz görsel türü"},
			{"uzun açıklama", map[string]string{"kind": "generate", "prompt": strings.Repeat("ğ", 1001)}, nil, 400, "1000"},
		}
		for _, c := range cases {
			rec, body := studioMultipart(t, router, jobsPath, ownerToken, c.fields, c.files...)
			if msg, _ := body["error"].(string); rec.Code != c.code || !strings.Contains(msg, c.want) {
				t.Errorf("%s: %d %v (beklenen %d, %q)", c.name, rec.Code, body, c.code, c.want)
			}
		}
		// Ne multipart ne JSON.
		req := httptest.NewRequest(http.MethodPost, jobsPath, strings.NewReader(url.Values{"kind": {"generate"}}.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.AddCookie(&http.Cookie{Name: "access_token", Value: ownerToken})
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("urlencoded gövde: %d %s", rec.Code, rec.Body.String())
		}
		if countJobs(t) != jobsBefore || fake.count() != callsBefore {
			t.Error("reddedilen istek iş açmamalı, OpenAI'ye gitmemeli")
		}
	})

	t.Run("06_kaynak_proje_fotoğrafı_okuma_erişimiyle", func(t *testing.T) {
		before := len(projectPhotos(t, p.ID))
		_, ownerEnhImage = runStudio(t, ownerToken, map[string]string{"kind": "enhance", "source_project_photo_id": src.ID})
		call, _ := fake.last()
		if !bytes.Equal(call.Image, srcBytes) {
			t.Error("OpenAI'ye giden görsel proje fotoğrafı değil")
		}
		if after := len(projectPhotos(t, p.ID)); after != before {
			t.Errorf("stüdyo işi projeye otomatik eklememeli: %d -> %d", before, after)
		}
		// Üye PM kendi projesindeki fotoğrafla açar.
		_, pmImage = runStudio(t, pmToken, map[string]string{"kind": "before_after", "prompt": "Laminat parke", "source_project_photo_id": src.ID})

		rec, body := studioMultipart(t, router, jobsPath, pmToken, map[string]string{"kind": "enhance", "source_project_photo_id": srcP2.ID})
		if rec.Code != http.StatusForbidden || body["code"] != "project_access_denied" {
			t.Errorf("üye olmadığı projenin fotoğrafı: %d %v", rec.Code, body)
		}
		rec, body = studioMultipart(t, router, jobsPath, finToken, map[string]string{"kind": "enhance", "source_project_photo_id": src.ID})
		if rec.Code != http.StatusForbidden || body["code"] != "permission_denied" {
			t.Errorf("operasyon okuma izni olmayan: %d %v", rec.Code, body)
		}
		rec, body = studioMultipart(t, router, jobsPath, otherToken, map[string]string{"kind": "enhance", "source_project_photo_id": src.ID})
		if rec.Code != http.StatusNotFound || body["error"] != "Kaynak fotoğraf bulunamadı" {
			t.Errorf("başka firmanın fotoğrafı: %d %v", rec.Code, body)
		}
		// Kaynak iş açılırken kopyalanır: fotoğraf sonradan silinse de iş biter.
		tmp, err := d.projectSvc.UploadPhoto(ctx, p.ID, orgID, service.UploadInput{
			OriginalName: "gecici.jpg", Reader: bytes.NewReader(studioJPEG(t, 32, 24, 90)), UserID: org.Owner.ID,
		})
		if err != nil {
			t.Fatal(err)
		}
		job := openStudio(t, ownerToken, map[string]string{"kind": "enhance", "source_project_photo_id": tmp.ID})
		if err := d.projectSvc.DeletePhoto(ctx, p.ID, tmp.ID, orgID, org.Owner.ID); err != nil {
			t.Fatal(err)
		}
		processAll(t)
		if code, done := getJob(t, ownerToken, job["id"].(string)); code != http.StatusOK || done["status"] != "done" {
			t.Errorf("silinen kaynakla iş: %d %v", code, done)
		}
		rec, body = studioMultipart(t, router, jobsPath, ownerToken, map[string]string{"kind": "enhance", "source_project_photo_id": tmp.ID})
		if rec.Code != http.StatusNotFound {
			t.Errorf("silinmiş fotoğraf kaynak olamaz: %d %v", rec.Code, body)
		}
	})

	t.Run("07_stüdyo_görselini_yeniden_düzenle", func(t *testing.T) {
		source := studioGetRaw(t, router, imagesPath+"/"+ownerGenImage+"/content", ownerToken).Body.Bytes()
		_, again := runStudio(t, ownerToken, map[string]string{"kind": "edit", "prompt": "yazıyı kırmızı yap", "source_studio_image_id": ownerGenImage})
		call, _ := fake.last()
		if again == ownerGenImage || !bytes.Equal(call.Image, source) {
			t.Errorf("yeniden düzenleme yeni görsel olmalı ve kaynağı göndermeli: %s", again)
		}
		_, list := listImages(t, ownerToken, "")
		if ids := imageIDs(list); ids[ownerGenImage] == nil || ids[again] == nil {
			t.Error("kaynak görsel yerinde kalmalı, yenisi eklenmeli")
		}
		// Yeniden düzenlemenin sonucu da kaynak olabilir (art arda).
		runStudio(t, ownerToken, map[string]string{"kind": "enhance", "source_studio_image_id": again})

		if rec, body := studioMultipart(t, router, jobsPath, ownerToken, map[string]string{"kind": "generate", "prompt": "x", "source_studio_image_id": ownerGenImage}); rec.Code != http.StatusBadRequest {
			t.Errorf("yeni görselde kaynak: %d %v", rec.Code, body)
		}
		rec, body := studioMultipart(t, router, jobsPath, pmToken, map[string]string{"kind": "enhance", "source_studio_image_id": ownerGenImage})
		if rec.Code != http.StatusNotFound || body["error"] != "Kaynak görsel bulunamadı" {
			t.Errorf("başkasının görseli kaynak olamaz: %d %v", rec.Code, body)
		}
		if rec, body := studioMultipart(t, router, jobsPath, otherToken, map[string]string{"kind": "enhance", "source_studio_image_id": ownerGenImage}); rec.Code != http.StatusNotFound {
			t.Errorf("başka firma: %d %v", rec.Code, body)
		}
		// Yönetici firmadaki görseli kaynak gösterebilir.
		job := openStudio(t, adminToken, map[string]string{"kind": "enhance", "source_studio_image_id": pmImage})
		processAll(t)
		if code, done := getJob(t, adminToken, job["id"].(string)); code != http.StatusOK || done["status"] != "done" {
			t.Errorf("yönetici, PM'nin görseliyle: %d %v", code, done)
		}
	})

	t.Run("08_bölge_düzenleme_maskesi_stüdyo", func(t *testing.T) {
		photo := studioJPEG(t, 32, 24, 120)
		mask := studioMask(t, 32, 24)
		done, _ := runStudio(t, ownerToken, map[string]string{"kind": "edit", "prompt": "bu alana pencere ekle"},
			studioPart{"image", "duvar.jpg", photo}, studioPart{"mask", "mask.png", mask})
		call, _ := fake.last()
		if !bytes.Equal(call.Mask, mask) || call.ImageType != "image/png" || http.DetectContentType(call.Image) != "image/png" ||
			!strings.Contains(call.Prompt, "The second image only marks, in red, the exact area to change") ||
			!strings.Contains(call.Prompt, "Do not change anything outside the marked area") ||
			strings.Contains(call.Prompt, "Completely remove") {
			t.Errorf("maskeli istek: maske=%v kaynak=%s prompt=%q", bytes.Equal(call.Mask, mask), call.ImageType, call.Prompt)
		}
		// İkinci görsel: kaynak, maskenin saydam (sol yarı) alanı kırmızıyla.
		if len(call.Images) != 2 || !bytes.Equal(call.Images[0], call.Image) {
			t.Fatalf("maskeli işte iki görsel gitmeli: %d", len(call.Images))
		}
		baseImg, err1 := png.Decode(bytes.NewReader(call.Images[0]))
		markImg, err2 := png.Decode(bytes.NewReader(call.Images[1]))
		if err1 != nil || err2 != nil {
			t.Fatalf("görseller PNG olmalı: %v %v", err1, err2)
		}
		px := func(img image.Image, x, y int) color.NRGBA {
			return color.NRGBAModel.Convert(img.At(x, y)).(color.NRGBA)
		}
		if in, orig := px(markImg, 4, 12), px(baseImg, 4, 12); int(in.R) < int(orig.R)+50 || in.G >= orig.G {
			t.Errorf("maskenin saydam alanı kırmızı işaretli olmalı: %v (kaynak %v)", in, orig)
		}
		if out, orig := px(markImg, 28, 12), px(baseImg, 28, 12); out != orig {
			t.Errorf("maskenin opak alanı aynen kalmalı: %v != %v", out, orig)
		}
		cfg, _, err := image.DecodeConfig(bytes.NewReader(call.Image))
		if err != nil || cfg.Width != 32 || cfg.Height != 24 {
			t.Errorf("PNG'ye çevrilen kaynağın boyutu: %+v %v", cfg, err)
		}
		var maskKey string
		if err := d.pool.QueryRow(ctx, "SELECT mask_storage_key FROM ai_image_jobs WHERE id = $1", done["id"]).Scan(&maskKey); err != nil || maskKey == "" {
			t.Errorf("maske anahtarı işte saklanmalı (denetim): %q %v", maskKey, err)
		}
		// Proje fotoğrafından açılan maskeli düzenleme de olur.
		runStudio(t, ownerToken, map[string]string{"kind": "edit", "prompt": "zemini parke yap", "source_project_photo_id": src.ID},
			studioPart{"mask", "mask.png", mask})
		if call, _ := fake.last(); !bytes.Equal(call.Mask, mask) || len(call.Images) != 2 {
			t.Error("proje fotoğrafı kaynağında maske ya da işaretli görsel gitmedi")
		}
		// Canlı hata: maskeli "sil" işi açık kaldırma talimatı almalı.
		for _, prompt := range []string{"Kalemle seçilen alanı sil", "Seçilen yeri sil sadece duvar kalsın", "BURAYI KALDIR"} {
			runStudio(t, ownerToken, map[string]string{"kind": "edit", "prompt": prompt},
				studioPart{"image", "duvar.jpg", photo}, studioPart{"mask", "mask.png", mask})
			call, _ := fake.last()
			if !strings.Contains(call.Prompt, "Completely remove every object inside the marked area") ||
				!strings.Contains(call.Prompt, `"`+prompt+`"`) || !bytes.Equal(call.Mask, mask) || len(call.Images) != 2 {
				t.Errorf("silme talimatı (%s): prompt=%q görsel=%d", prompt, call.Prompt, len(call.Images))
			}
		}
		// Maskesiz düzenleme tek görsel gönderir.
		runStudio(t, ownerToken, map[string]string{"kind": "edit", "prompt": "duvarı griye boya"}, studioPart{"image", "duvar.jpg", photo})
		if call, _ := fake.last(); call.Mask != nil || len(call.Images) != 1 || !strings.Contains(call.Prompt, "Apply only the requested change") {
			t.Errorf("maskesiz düzenleme değişmemeli: maske=%v görsel=%d prompt=%q", call.Mask != nil, len(call.Images), call.Prompt)
		}

		jobsBefore := countJobs(t)
		for _, c := range []struct {
			name   string
			fields map[string]string
			files  []studioPart
			want   string
		}{
			{"boyut farkı", map[string]string{"kind": "edit", "prompt": "x"}, []studioPart{{"image", "a.jpg", photo}, {"mask", "m.png", studioMask(t, 24, 32)}}, "aynı boyutta"},
			{"PNG olmayan maske", map[string]string{"kind": "edit", "prompt": "x"}, []studioPart{{"image", "a.jpg", photo}, {"mask", "m.jpg", studioJPEG(t, 32, 24, 1)}}, "PNG olmalı"},
			{"boyalı yer yok", map[string]string{"kind": "edit", "prompt": "x"}, []studioPart{{"image", "a.jpg", photo}, {"mask", "m.png", studioPNG(t, 32, 24, 1)}}, "boyayın"},
			{"düzenleme dışı tür", map[string]string{"kind": "enhance"}, []studioPart{{"image", "a.jpg", photo}, {"mask", "m.png", mask}}, "yalnızca düzenlemede"},
			{"çok büyük maske", map[string]string{"kind": "edit", "prompt": "x"}, []studioPart{{"image", "a.jpg", photo}, {"mask", "m.png", make([]byte, 10<<20+1)}}, "10 MB"},
		} {
			rec, body := studioMultipart(t, router, jobsPath, ownerToken, c.fields, c.files...)
			if msg, _ := body["error"].(string); rec.Code != http.StatusBadRequest || !strings.Contains(msg, c.want) {
				t.Errorf("%s: %d %v", c.name, rec.Code, body)
			}
		}
		if countJobs(t) != jobsBefore {
			t.Error("geçersiz maske iş açmamalı")
		}
	})

	t.Run("09_proje_ucu_edit_türü_maskeli_ve_maskesiz", func(t *testing.T) {
		projectJobs := "/api/v1/projects/" + p.ID + "/ai-image-jobs"
		mask := studioMask(t, 32, 24)
		rec, body := studioMultipart(t, router, projectJobs, ownerToken,
			map[string]string{"kind": "edit", "prompt": "kapıyı beyaz boya", "source_photo_id": src.ID},
			studioPart{"mask", "mask.png", mask})
		job := jobOf(t, rec, body)
		processAll(t)
		rec, done := rbacDo(t, router, http.MethodGet, projectJobs+"/"+job["id"].(string), ownerToken, "")
		resultID, _ := done["result_photo_id"].(string)
		if rec.Code != http.StatusOK || done["status"] != "done" || resultID == "" {
			t.Fatalf("proje edit işi: %d %v", rec.Code, done)
		}
		if call, _ := fake.last(); !bytes.Equal(call.Mask, mask) || len(call.Images) != 2 ||
			!strings.Contains(call.Prompt, "output the first image edited only in that area") {
			t.Error("proje ucunda maske, işaretli görsel ya da düzenleme talimatı gitmedi")
		}
		ph := projectPhotos(t, p.ID)[resultID]
		ai, _ := ph["ai"].(map[string]any)
		if ph["ai_generated"] != true || ai["kind"] != "edit" || ph["stage"] != domain.PhotoStageBefore || ai["source_photo_id"] != src.ID {
			t.Errorf("sonuç fotoğrafı kaynağın aşamasında, işaretli olmalı: %v", ph)
		}
		// Eski uygulamanın JSON gövdesiyle maskesiz edit.
		rec, body = rbacDo(t, router, http.MethodPost, projectJobs, ownerToken,
			`{"kind":"edit","prompt":"duvara raf ekle","source_photo_id":"`+src.ID+`"}`)
		jobOf(t, rec, body)
		processAll(t)
		if call, _ := fake.last(); call.Mask != nil || call.Path != "/images/edits" {
			t.Error("maskesiz edit maske göndermemeli")
		}
		for _, b := range []string{`{"kind":"edit","source_photo_id":"` + src.ID + `"}`, `{"kind":"edit","prompt":"x"}`} {
			if rec, body := rbacDo(t, router, http.MethodPost, projectJobs, ownerToken, b); rec.Code != http.StatusBadRequest {
				t.Errorf("edit açıklama ve kaynak ister: %s -> %d %v", b, rec.Code, body)
			}
		}
		rec, body = studioMultipart(t, router, projectJobs, ownerToken,
			map[string]string{"kind": "edit", "prompt": "x", "source_photo_id": src.ID}, studioPart{"mask", "m.png", studioMask(t, 10, 10)})
		if msg, _ := body["error"].(string); rec.Code != http.StatusBadRequest || !strings.Contains(msg, "32×24") {
			t.Errorf("proje ucunda maske boyut farkı: %d %v", rec.Code, body)
		}
		rec, body = studioMultipart(t, router, projectJobs, ownerToken,
			map[string]string{"kind": "before_after", "prompt": "x", "source_photo_id": src.ID}, studioPart{"mask", "m.png", mask})
		if rec.Code != http.StatusBadRequest {
			t.Errorf("proje ucunda edit dışı maske: %d %v", rec.Code, body)
		}
	})

	t.Run("10_görünürlük_kendi_ve_firma_geneli", func(t *testing.T) {
		_, mine := listImages(t, ownerToken, "")
		ids := imageIDs(mine)
		if ids[ownerGenImage] == nil || ids[pmImage] != nil {
			t.Errorf("sahibin kendi listesi yalnızca kendisininki: %v", ids)
		}
		code, pmList := listImages(t, pmToken, "?scope=mine")
		pmIDs := imageIDs(pmList)
		if code != http.StatusOK || pmIDs[pmImage] == nil || pmIDs[ownerGenImage] != nil || len(pmIDs) != 1 {
			t.Errorf("PM yalnızca kendisininkini görür: %d %v", code, pmIDs)
		}
		if code, body := listImages(t, pmToken, "?scope=firm"); code != http.StatusForbidden || body["code"] != "permission_denied" {
			t.Errorf("PM firma geneli: %d %v", code, body)
		}
		for name, tok := range map[string]string{"sahip": ownerToken, "yönetici": adminToken} {
			code, firm := listImages(t, tok, "?scope=firm&limit=100")
			f := imageIDs(firm)
			if code != http.StatusOK || f[ownerGenImage] == nil || f[pmImage] == nil || f[pmImage]["user_name"] != "ai_studio_pm" {
				t.Errorf("%s firma geneli: %d %d görsel", name, code, len(f))
			}
		}
		if code, body := listImages(t, ownerToken, "?scope=herkes"); code != http.StatusBadRequest {
			t.Errorf("geçersiz scope: %d %v", code, body)
		}
		if code, _ := listImages(t, ownerToken, "?before=dun"); code != http.StatusBadRequest {
			t.Errorf("geçersiz before: %d", code)
		}
		if code, _ := listImages(t, ownerToken, "?limit=0"); code != http.StatusBadRequest {
			t.Errorf("geçersiz limit: %d", code)
		}
		// Başka firma: kendi listesi boş, firma geneli de A'yı içermez.
		for _, q := range []string{"", "?scope=firm"} {
			if code, body := listImages(t, otherToken, q); code != http.StatusOK || len(imageIDs(body)) != 0 {
				t.Errorf("başka firma %q: %d %v", q, code, body)
			}
		}

		// Süren iş "Hazırlanıyor" kutucuğu: yalnızca açanın listesinde.
		job := openStudio(t, pmToken, map[string]string{"kind": "generate", "prompt": "Sırada bekleyen"})
		_, pmList = listImages(t, pmToken, "")
		pending, _ := pmList["pending_jobs"].([]any)
		if len(pending) != 1 || pending[0].(map[string]any)["id"] != job["id"] || pending[0].(map[string]any)["status"] != "queued" {
			t.Errorf("PM'nin süren işi: %v", pmList["pending_jobs"])
		}
		_, firm := listImages(t, ownerToken, "?scope=firm")
		if pending, _ := firm["pending_jobs"].([]any); len(pending) != 0 {
			t.Errorf("başkasının süren işi görünmemeli: %v", pending)
		}
		processAll(t)
		_, pmList = listImages(t, pmToken, "")
		if pending, _ := pmList["pending_jobs"].([]any); len(pending) != 0 {
			t.Errorf("bitince pending boşalmalı: %v", pending)
		}
	})

	t.Run("11_sayfalama_aynı_anlı_görseller_atlanmaz", func(t *testing.T) {
		_, all := listImages(t, ownerToken, "?limit=100")
		want := imageIDs(all)
		if len(want) < 4 || all["next_before"] != nil {
			t.Fatalf("tek sayfada hepsi: %d %v", len(want), all["next_before"])
		}
		// İki görseli aynı ana çek: imleç yalnızca zaman taşır.
		var first, second string
		for id := range want {
			if first == "" {
				first = id
			} else if second == "" {
				second = id
			}
		}
		if _, err := d.pool.Exec(ctx, "UPDATE ai_studio_images SET created_at = (SELECT created_at FROM ai_studio_images WHERE id = $1) WHERE id = $2", first, second); err != nil {
			t.Fatal(err)
		}
		seen := map[string]int{}
		before := ""
		for pages := 0; pages < 50; pages++ {
			q := "?limit=1"
			if before != "" {
				q += "&before=" + url.QueryEscape(before)
			}
			code, page := listImages(t, ownerToken, q)
			if code != http.StatusOK {
				t.Fatalf("sayfa: %d %v", code, page)
			}
			for id := range imageIDs(page) {
				seen[id]++
			}
			next, _ := page["next_before"].(string)
			if next == "" {
				break
			}
			before = next
		}
		if len(seen) != len(want) {
			t.Errorf("sayfalarda %d görsel, beklenen %d", len(seen), len(want))
		}
		for id, n := range seen {
			if n != 1 || want[id] == nil {
				t.Errorf("görsel %s %d kez", id, n)
			}
		}
	})

	t.Run("12_indirme_ve_iş_gizliliği", func(t *testing.T) {
		content := imagesPath + "/" + ownerGenImage + "/content"
		if rec := studioGetRaw(t, router, content, pmToken); rec.Code != http.StatusNotFound {
			t.Errorf("PM başkasının görselini indirememeli: %d", rec.Code)
		}
		if rec := studioGetRaw(t, router, content, adminToken); rec.Code != http.StatusOK {
			t.Errorf("Yönetici firmadaki görseli indirir: %d", rec.Code)
		}
		if rec := studioGetRaw(t, router, content, otherToken); rec.Code != http.StatusNotFound {
			t.Errorf("başka firma: %d", rec.Code)
		}
		jobID := ownerEditJob["id"].(string)
		if code, _ := getJob(t, pmToken, jobID); code != http.StatusNotFound {
			t.Errorf("başkasının işi: %d", code)
		}
		if code, _ := getJob(t, adminToken, jobID); code != http.StatusNotFound {
			t.Errorf("iş yalnızca açanına görünür (Yönetici dahil): %d", code)
		}
		if code, _ := getJob(t, otherToken, jobID); code != http.StatusNotFound {
			t.Errorf("başka firma işi: %d", code)
		}
		// Stüdyo işi proje yolundan, proje işi stüdyo yolundan görünmez.
		if rec, _ := rbacDo(t, router, http.MethodGet, "/api/v1/projects/"+p.ID+"/ai-image-jobs/"+jobID, ownerToken, ""); rec.Code != http.StatusNotFound {
			t.Errorf("stüdyo işi proje yolunda: %d", rec.Code)
		}
		_, projectJobs := rbacDo(t, router, http.MethodGet, "/api/v1/projects/"+p.ID+"/ai-image-jobs", ownerToken, "")
		list, _ := projectJobs["jobs"].([]any)
		if len(list) == 0 {
			t.Fatal("proje işleri listesi boş")
		}
		for _, raw := range list {
			if raw.(map[string]any)["id"] == jobID {
				t.Error("stüdyo işi proje iş listesinde")
			}
		}
		if code, _ := getJob(t, ownerToken, list[0].(map[string]any)["id"].(string)); code != http.StatusNotFound {
			t.Errorf("proje işi stüdyo yolunda: %d", code)
		}
	})

	t.Run("13_projeye_ekle", func(t *testing.T) {
		img := ownerEditJob["studio_image_id"].(string)
		addPath := imagesPath + "/" + img + "/add-to-project"
		before := len(projectPhotos(t, p.ID))
		rec, body := rbacDo(t, router, http.MethodPost, addPath, ownerToken, `{"project_id":"`+p.ID+`","stage":"after"}`)
		photoID, _ := body["project_photo_id"].(string)
		if rec.Code != http.StatusOK || photoID == "" || body["already_added"] != false {
			t.Fatalf("projeye ekle: %d %v", rec.Code, body)
		}
		ph := projectPhotos(t, p.ID)[photoID]
		ai, _ := ph["ai"].(map[string]any)
		if ph == nil || ph["ai_generated"] != true || ai["kind"] != "edit" || ai["prompt"] != "duvarı griye boya" || ph["stage"] != "after" {
			t.Errorf("projedeki kopya işaretli olmalı: %v", ph)
		}
		content := studioGetRaw(t, router, "/api/v1/projects/"+p.ID+"/photos/"+photoID+"/content", ownerToken)
		studio := studioGetRaw(t, router, imagesPath+"/"+img+"/content", ownerToken)
		if !bytes.Equal(content.Body.Bytes(), studio.Body.Bytes()) {
			t.Error("projeye eklenen fotoğraf stüdyo görselinin kopyası olmalı")
		}
		rec, body = rbacDo(t, router, http.MethodPost, addPath, ownerToken, `{"project_id":"`+p.ID+`","stage":"progress"}`)
		if rec.Code != http.StatusOK || body["project_photo_id"] != photoID || body["already_added"] != true {
			t.Errorf("tekrar aynı fotoğraf dönmeli: %d %v", rec.Code, body)
		}
		if after := len(projectPhotos(t, p.ID)); after != before+1 {
			t.Errorf("tek kopya: %d -> %d", before, after)
		}
		_, list := listImages(t, ownerToken, "?limit=100")
		projects, _ := imageIDs(list)[img]["projects"].([]any)
		if len(projects) != 1 || projects[0].(map[string]any)["project_id"] != p.ID ||
			projects[0].(map[string]any)["project_name"] != p.Name || projects[0].(map[string]any)["project_photo_id"] != photoID {
			t.Errorf("görselin projeleri: %v", projects)
		}
		// Kopya projeden silinirse yeniden eklenebilir (yeni fotoğraf).
		if err := d.projectSvc.DeletePhoto(ctx, p.ID, photoID, orgID, org.Owner.ID); err != nil {
			t.Fatal(err)
		}
		_, list = listImages(t, ownerToken, "?limit=100")
		if projects, _ := imageIDs(list)[img]["projects"].([]any); len(projects) != 0 {
			t.Errorf("silinen kopya listede görünmemeli: %v", projects)
		}
		rec, body = rbacDo(t, router, http.MethodPost, addPath, ownerToken, `{"project_id":"`+p.ID+`"}`)
		if rec.Code != http.StatusOK || body["project_photo_id"] == photoID || body["already_added"] != false {
			t.Errorf("silinen kopyadan sonra yeni fotoğraf: %d %v", rec.Code, body)
		}
		if ph := projectPhotos(t, p.ID)[body["project_photo_id"].(string)]; ph["stage"] != "progress" {
			t.Errorf("aşama verilmezse düzenleme 'İlerleme': %v", ph["stage"])
		}

		// Kaynağı bu projenin fotoğrafı olan görselde bağ kurulur.
		rec, body = rbacDo(t, router, http.MethodPost, imagesPath+"/"+ownerEnhImage+"/add-to-project", ownerToken, `{"project_id":"`+p.ID+`"}`)
		if rec.Code != http.StatusOK {
			t.Fatalf("iyileştirme görseli: %d %v", rec.Code, body)
		}
		ph = projectPhotos(t, p.ID)[body["project_photo_id"].(string)]
		if ai, _ := ph["ai"].(map[string]any); ai["source_photo_id"] != src.ID || ai["source_date"] == nil {
			t.Errorf("aynı projedeki kaynak bağı: %v", ph["ai"])
		}
		// Başka projeye eklenince kaynak bağı kurulmaz (başka projenin fotoğrafı).
		rec, body = rbacDo(t, router, http.MethodPost, imagesPath+"/"+ownerEnhImage+"/add-to-project", ownerToken, `{"project_id":"`+p2.ID+`"}`)
		if rec.Code != http.StatusOK {
			t.Fatalf("p2: %d %v", rec.Code, body)
		}
		if ai, _ := projectPhotos(t, p2.ID)[body["project_photo_id"].(string)]["ai"].(map[string]any); ai["source_photo_id"] != nil {
			t.Errorf("başka projede kaynak bağı olmamalı: %v", ai)
		}

		// PM: kendi görseli, üyesi olduğu projeye evet; diğerine 403; sahibinkine 404.
		rec, body = rbacDo(t, router, http.MethodPost, imagesPath+"/"+pmImage+"/add-to-project", pmToken, `{"project_id":"`+p.ID+`","stage":"after"}`)
		if rec.Code != http.StatusOK {
			t.Errorf("PM kendi görselini üye projesine: %d %v", rec.Code, body)
		}
		rec, body = rbacDo(t, router, http.MethodPost, imagesPath+"/"+pmImage+"/add-to-project", pmToken, `{"project_id":"`+p2.ID+`"}`)
		if rec.Code != http.StatusForbidden || body["code"] != "project_access_denied" {
			t.Errorf("PM üye olmadığı proje: %d %v", rec.Code, body)
		}
		rec, body = rbacDo(t, router, http.MethodPost, addPath, pmToken, `{"project_id":"`+p.ID+`"}`)
		if rec.Code != http.StatusNotFound {
			t.Errorf("PM sahibin görselini ekleyememeli: %d %v", rec.Code, body)
		}
		// Yönetici PM'nin görselini PM'nin üye olmadığı projeye ekler; PM o
		// projenin adını kendi listesinde görmez.
		if rec, body := rbacDo(t, router, http.MethodPost, imagesPath+"/"+pmImage+"/add-to-project", adminToken, `{"project_id":"`+p2.ID+`"}`); rec.Code != http.StatusOK {
			t.Errorf("Yönetici: %d %v", rec.Code, body)
		}
		_, pmList := listImages(t, pmToken, "")
		for _, raw := range imageIDs(pmList)[pmImage]["projects"].([]any) {
			if raw.(map[string]any)["project_id"] == p2.ID {
				t.Error("PM üye olmadığı projenin adını görmemeli")
			}
		}
		_, firm := listImages(t, ownerToken, "?scope=firm&limit=100")
		if projects, _ := imageIDs(firm)[pmImage]["projects"].([]any); len(projects) != 2 {
			t.Errorf("sahip iki projeyi de görür: %v", projects)
		}

		// Operasyon yazma izni yok (finans): 403; kendi görseli olsa da.
		_, finImage := runStudio(t, finToken, map[string]string{"kind": "generate", "prompt": "Rapor kapağı"})
		rec, body = rbacDo(t, router, http.MethodPost, imagesPath+"/"+finImage+"/add-to-project", finToken, `{"project_id":"`+p.ID+`"}`)
		if rec.Code != http.StatusForbidden || body["code"] != "permission_denied" {
			t.Errorf("finans: %d %v", rec.Code, body)
		}
		rec, body = rbacDo(t, router, http.MethodPost, addPath, ownerToken, `{"project_id":"`+pClosed.ID+`"}`)
		if rec.Code != http.StatusConflict || !strings.Contains(body["error"].(string), "tamamlandı") {
			t.Errorf("kapalı proje: %d %v", rec.Code, body)
		}
		for _, b := range []string{`{"project_id":"` + p.ID + `","stage":"bitti"}`, `{"stage":"after"}`, `{"project_id":"` + p.ID + `","fazla":1}`} {
			if rec, body := rbacDo(t, router, http.MethodPost, addPath, ownerToken, b); rec.Code != http.StatusBadRequest {
				t.Errorf("%s: %d %v", b, rec.Code, body)
			}
		}
		// Firma izolasyonu: başka firmanın görseli de projesi de 404.
		if rec, body := rbacDo(t, router, http.MethodPost, addPath, otherToken, `{"project_id":"`+pOther.ID+`"}`); rec.Code != http.StatusNotFound {
			t.Errorf("başka firma A'nın görselini: %d %v", rec.Code, body)
		}
		if rec, body := rbacDo(t, router, http.MethodPost, addPath, ownerToken, `{"project_id":"`+pOther.ID+`"}`); rec.Code != http.StatusNotFound {
			t.Errorf("A, B'nin projesine: %d %v", rec.Code, body)
		}
	})

	t.Run("14_silme_kuralları", func(t *testing.T) {
		del := func(token, id string) int {
			rec, _ := rbacDo(t, router, http.MethodDelete, imagesPath+"/"+id, token, "")
			return rec.Code
		}
		if code := del(pmToken, ownerGenImage); code != http.StatusNotFound {
			t.Errorf("PM sahibin görselini silememeli: %d", code)
		}
		if code := del(otherToken, ownerGenImage); code != http.StatusNotFound {
			t.Errorf("başka firma: %d", code)
		}
		_, own := runStudio(t, pmToken, map[string]string{"kind": "generate", "prompt": "Silinecek"})
		if code := del(pmToken, own); code != http.StatusNoContent {
			t.Errorf("PM kendi görselini siler: %d", code)
		}
		if rec := studioGetRaw(t, router, imagesPath+"/"+own+"/content", pmToken); rec.Code != http.StatusNotFound {
			t.Errorf("silinen görselin içeriği 404: %d", rec.Code)
		}
		if code := del(pmToken, own); code != http.StatusNotFound {
			t.Errorf("ikinci silme: %d", code)
		}
		// Yönetici PM'nin görselini siler; projeye eklenmiş kopyası projede kalır.
		before := len(projectPhotos(t, p.ID))
		if code := del(adminToken, pmImage); code != http.StatusNoContent {
			t.Errorf("Yönetici silme: %d", code)
		}
		_, pmList := listImages(t, pmToken, "")
		if imageIDs(pmList)[pmImage] != nil {
			t.Error("silinen görsel listede")
		}
		if after := len(projectPhotos(t, p.ID)); after != before {
			t.Errorf("projedeki kopya kalmalı: %d -> %d", before, after)
		}
		if rec, _ := rbacDo(t, router, http.MethodPost, imagesPath+"/"+pmImage+"/add-to-project", ownerToken, `{"project_id":"`+p.ID+`"}`); rec.Code != http.StatusNotFound {
			t.Errorf("silinen görsel projeye eklenemez: %d", rec.Code)
		}
	})

	t.Run("15_hak_ve_sınırlar_proje_işleriyle_ortak", func(t *testing.T) {
		var used int
		if err := d.pool.QueryRow(ctx,
			"SELECT count(*) FROM ai_image_jobs WHERE organization_id = $1 AND status <> 'failed'", orgID).Scan(&used); err != nil {
			t.Fatal(err)
		}
		var studioJobs, projectJobs int
		_ = d.pool.QueryRow(ctx, "SELECT count(*) FILTER (WHERE project_id IS NULL), count(*) FILTER (WHERE project_id IS NOT NULL) FROM ai_image_jobs WHERE organization_id = $1", orgID).Scan(&studioJobs, &projectJobs)
		if studioJobs == 0 || projectJobs == 0 {
			t.Fatalf("iki tür iş de olmalı: stüdyo %d, proje %d", studioJobs, projectJobs)
		}
		rec, body := rbacDo(t, router, http.MethodGet, "/api/v1/ai/status", ownerToken, "")
		if q, _ := body["quota"].(map[string]any); rec.Code != http.StatusOK || q["used_this_month"] != float64(used) {
			t.Errorf("durum ucu stüdyo + proje işlerini birlikte saymalı (%d): %v", used, body)
		}
		limited := baseCfg
		limited.MonthlyLimit = used
		lr, _ := newRouter(client, limited)
		rec, body = studioMultipart(t, lr, jobsPath, ownerToken, map[string]string{"kind": "generate", "prompt": "x"})
		if rec.Code != http.StatusTooManyRequests || body["code"] != "ai_monthly_limit" || body["remaining"] != 0.0 {
			t.Errorf("stüdyoda aylık sınır: %d %v", rec.Code, body)
		}
		rec, body = rbacDo(t, lr, http.MethodPost, "/api/v1/projects/"+p.ID+"/ai-image-jobs", ownerToken, `{"kind":"generate","prompt":"x"}`)
		if rec.Code != http.StatusTooManyRequests || body["code"] != "ai_monthly_limit" {
			t.Errorf("proje ucunda aynı aylık sınır: %d %v", rec.Code, body)
		}
		// Aynı anda süren iş sınırı (kişi başı 2) iki ucu birlikte sayar.
		openStudio(t, pmToken, map[string]string{"kind": "generate", "prompt": "bir"})
		rec, body = rbacDo(t, router, http.MethodPost, "/api/v1/projects/"+p.ID+"/ai-image-jobs", pmToken, `{"kind":"generate","prompt":"iki"}`)
		jobOf(t, rec, body)
		rec, body = studioMultipart(t, router, jobsPath, pmToken, map[string]string{"kind": "generate", "prompt": "üç"})
		if rec.Code != http.StatusTooManyRequests || body["code"] != "ai_user_busy" {
			t.Errorf("süren iş sınırı: %d %v", rec.Code, body)
		}
		processAll(t)
		// Saatlik sınır da ortak.
		var hourly int
		_ = d.pool.QueryRow(ctx, "SELECT count(*) FROM ai_image_jobs WHERE organization_id = $1 AND user_id = $2 AND created_at >= now() - interval '1 hour'", orgID, org.Owner.ID).Scan(&hourly)
		h := baseCfg
		h.UserHourlyLimit = hourly
		hr, _ := newRouter(client, h)
		rec, body = studioMultipart(t, hr, jobsPath, ownerToken, map[string]string{"kind": "generate", "prompt": "x"})
		if rec.Code != http.StatusTooManyRequests || body["code"] != "ai_user_rate_limit" {
			t.Errorf("saatlik sınır: %d %v", rec.Code, body)
		}
	})

	t.Run("16_OpenAI_reddi_Türkçe_neden_görsel_yok_hak_düşmez", func(t *testing.T) {
		_, st0 := rbacDo(t, router, http.MethodGet, "/api/v1/ai/status", ownerToken, "")
		fake.setMode("moderation")
		defer fake.setMode("ok")
		job := openStudio(t, ownerToken, map[string]string{"kind": "generate", "prompt": "Reddedilecek"})
		processAll(t)
		code, done := getJob(t, ownerToken, job["id"].(string))
		msg, _ := done["error"].(string)
		if code != http.StatusOK || done["status"] != "failed" || !strings.Contains(msg, "güvenlik kurallarına") || done["studio_image_id"] != nil {
			t.Errorf("başarısız iş: %d %v", code, done)
		}
		_, st1 := rbacDo(t, router, http.MethodGet, "/api/v1/ai/status", ownerToken, "")
		if st0["quota"].(map[string]any)["used_this_month"] != st1["quota"].(map[string]any)["used_this_month"] {
			t.Error("başarısız iş hakkı düşürmemeli")
		}
	})

	t.Run("17_yeniden_başlatma_yarım_stüdyo_işi_başarısız", func(t *testing.T) {
		job := openStudio(t, ownerToken, map[string]string{"kind": "edit", "prompt": "x"},
			studioPart{"image", "a.jpg", studioJPEG(t, 16, 16, 5)})
		if n, err := svc.RecoverInterrupted(ctx); err != nil || n != 1 {
			t.Fatalf("kurtarma: %d %v", n, err)
		}
		code, done := getJob(t, ownerToken, job["id"].(string))
		if msg, _ := done["error"].(string); code != http.StatusOK || done["status"] != "failed" || !strings.Contains(msg, "yeniden başlatıldığı") {
			t.Errorf("yarım iş: %d %v", code, done)
		}
	})

	t.Run("18_EXIF_yönlü_telefon_fotoğrafı_maskesi_gösterilen_boyutta", func(t *testing.T) {
		// Sensör yönünde 32×24 kaydedilmiş, EXIF 6 (90° saat yönünde):
		// uygulama 24×32 gösterir ve maskeyi 24×32 çizer.
		rotated := studioWithEXIFOrientation(studioJPEG(t, 32, 24, 150), 6)
		mask := studioMask(t, 24, 32)
		checkUpright := func(t *testing.T) {
			t.Helper()
			call, _ := fake.last()
			cfg, _, err := image.DecodeConfig(bytes.NewReader(call.Image))
			if err != nil || cfg.Width != 24 || cfg.Height != 32 || !bytes.Equal(call.Mask, mask) {
				t.Errorf("OpenAI'ye dik kaynak ve maske gitmeli: %+v %v", cfg, err)
			}
		}
		runStudio(t, ownerToken, map[string]string{"kind": "edit", "prompt": "rafı kaldır"},
			studioPart{"image", "IMG_0042.jpg", rotated}, studioPart{"mask", "mask.png", mask})
		checkUpright(t)
		rec, body := studioMultipart(t, router, jobsPath, ownerToken, map[string]string{"kind": "edit", "prompt": "x"},
			studioPart{"image", "IMG_0042.jpg", rotated}, studioPart{"mask", "mask.png", studioMask(t, 32, 24)})
		if msg, _ := body["error"].(string); rec.Code != http.StatusBadRequest || !strings.Contains(msg, "24×32") {
			t.Errorf("ham (döndürülmemiş) boyutta maske reddedilmeli: %d %v", rec.Code, body)
		}

		// Proje ucu: projeye ham haliyle yüklenmiş yönlü fotoğraf.
		ph, err := d.projectSvc.UploadPhoto(ctx, p.ID, orgID, service.UploadInput{
			OriginalName: "yonlu.jpg", Reader: bytes.NewReader(rotated), UserID: org.Owner.ID,
		})
		if err != nil {
			t.Fatal(err)
		}
		projectJobs := "/api/v1/projects/" + p.ID + "/ai-image-jobs"
		rec, body = studioMultipart(t, router, projectJobs, ownerToken,
			map[string]string{"kind": "edit", "prompt": "prizi kaldır", "source_photo_id": ph.ID}, studioPart{"mask", "mask.png", mask})
		job := jobOf(t, rec, body)
		processAll(t)
		if rec, done := rbacDo(t, router, http.MethodGet, projectJobs+"/"+job["id"].(string), ownerToken, ""); rec.Code != http.StatusOK || done["status"] != "done" {
			t.Fatalf("proje işi: %d %v", rec.Code, done)
		}
		checkUpright(t)
	})

	t.Run("19_eski_proje_ucu_değişmeden_projeye_kaydeder", func(t *testing.T) {
		projectJobs := "/api/v1/projects/" + p.ID + "/ai-image-jobs"
		rec, body := rbacDo(t, router, http.MethodPost, projectJobs, ownerToken,
			`{"kind":"before_after","prompt":"Duvarlar beyaz boyalı, laminat parke","source_photo_id":"`+src.ID+`"}`)
		job := jobOf(t, rec, body)
		if job["project_id"] != p.ID || body["quota"] == nil {
			t.Errorf("eski yanıt biçimi: %v", body)
		}
		processAll(t)
		rec, done := rbacDo(t, router, http.MethodGet, projectJobs+"/"+job["id"].(string), ownerToken, "")
		resultID, _ := done["result_photo_id"].(string)
		if rec.Code != http.StatusOK || done["status"] != "done" || resultID == "" {
			t.Fatalf("proje işi: %d %v", rec.Code, done)
		}
		if ph := projectPhotos(t, p.ID)[resultID]; ph["ai_generated"] != true || ph["stage"] != "after" {
			t.Errorf("sonuç projeye otomatik eklenmeli: %v", ph)
		}
		_, firm := listImages(t, ownerToken, "?scope=firm&limit=100")
		for _, img := range imageIDs(firm) {
			if img["prompt"] == "Duvarlar beyaz boyalı, laminat parke" {
				t.Error("proje işinin sonucu stüdyoda görünmemeli")
			}
		}
	})
}
