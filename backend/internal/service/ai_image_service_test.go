package service_test

// Yapay zekâ görselleri (migration 0079): iş yaşam döngüsü (sırada -> bitti /
// başarısız), sonuç YENİ ve işaretli fotoğraf, kaynak dokunulmaz, aylık ve
// kişi başı sınırlar, firma/proje izolasyonu, açılışta yarım kalan işler.
// OpenAI'ye ASLA gidilmez: gerçek istemci httptest sahte sunucusuna bağlanır.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/openai"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// fakeOpenAI: sahte Images API. mode: "ok" görsel döner, "moderation"
// güvenlik reddi, "quota" kredi bitti.
type fakeOpenAI struct {
	mu    sync.Mutex
	mode  string
	calls []fakeOpenAICall
	srv   *httptest.Server
	seq   int
}

type fakeOpenAICall struct {
	Path   string
	Model  string
	Prompt string
	Image  []byte // edits: image[] parçası
	Fields map[string]string
}

func newFakeOpenAI(t *testing.T) *fakeOpenAI {
	t.Helper()
	f := &fakeOpenAI{mode: "ok"}
	f.srv = httptest.NewServer(http.HandlerFunc(f.handle))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeOpenAI) setMode(m string) {
	f.mu.Lock()
	f.mode = m
	f.mu.Unlock()
}

func (f *fakeOpenAI) last() fakeOpenAICall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls[len(f.calls)-1]
}

func (f *fakeOpenAI) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

func (f *fakeOpenAI) handle(w http.ResponseWriter, r *http.Request) {
	call := fakeOpenAICall{Path: r.URL.Path, Fields: map[string]string{}}
	if strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/") {
		if err := r.ParseMultipartForm(32 << 20); err == nil {
			for k, v := range r.MultipartForm.Value {
				call.Fields[k] = v[0]
			}
			if files := r.MultipartForm.File["image[]"]; len(files) > 0 {
				fh, _ := files[0].Open()
				call.Image, _ = io.ReadAll(fh)
				fh.Close()
			}
		}
	} else {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		for k, v := range body {
			call.Fields[k] = fmt.Sprint(v)
		}
	}
	call.Model, call.Prompt = call.Fields["model"], call.Fields["prompt"]
	f.mu.Lock()
	f.calls = append(f.calls, call)
	mode := f.mode
	f.seq++
	seq := f.seq
	f.mu.Unlock()

	switch mode {
	case "moderation":
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"message":"Your request was rejected by the safety system.","type":"image_generation_user_error","code":"moderation_blocked"}}`))
		return
	case "quota":
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","code":"insufficient_quota"}}`))
		return
	}
	// Her yanıt farklı bayt (aynı projede SHA çakışmasın).
	_ = json.NewEncoder(w).Encode(map[string]any{
		"created":       time.Now().Unix(),
		"data":          []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(testJPEG(nil, uint8(seq)))}},
		"output_format": "jpeg",
	})
}

func testJPEG(t *testing.T, shade uint8) []byte {
	img := image.NewRGBA(image.Rect(0, 0, 48, 32))
	for x := 0; x < 48; x++ {
		for y := 0; y < 32; y++ {
			img.Set(x, y, color.RGBA{R: shade, G: 90, B: 140, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, nil); err != nil && t != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestAIImageJobs(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	box := testSecretBox(t)
	orgSvc := service.NewOrganizationService(q)
	userSvc := service.NewUserService(pool, q)
	settingsSvc := service.NewSettingsService(q, box)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000")

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "YZ Görsel Firma A", "yz-gorsel-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "YZ Görsel Firma B", "yz-gorsel-b")
	suffix := fmt.Sprintf("%d", time.Now().UnixNano()%1_000_000_000)
	newUser := func(t *testing.T, orgID, name string) *domain.User {
		t.Helper()
		oid, _ := repository.StringToUUID(orgID)
		_ = q.SeedSystemRolesForOrg(ctx, oid) // ikinci çağrı çakışır, zararsız
		u, err := userSvc.Create(ctx, orgID, name+"_"+suffix, "GeciciSifre123!", name, domain.RoleAdmin, domain.OrgRoleOwner)
		if err != nil {
			t.Fatal(err)
		}
		return u
	}
	ownerA := newUser(t, orgA.ID, "yz_sahip_a")
	otherA := newUser(t, orgA.ID, "yz_yonetici_a")
	ownerB := newUser(t, orgB.ID, "yz_sahip_b")

	newProject := func(t *testing.T, orgID, name string) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID, CustomerName: "Müşteri", VatRate: ptrFloat(0),
			Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 100000}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatal(err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgID, "", nil)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatal(err)
		}
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: name})
		if err != nil {
			t.Fatal(err)
		}
		return p
	}
	pA := newProject(t, orgA.ID, "Kadıköy Daire")
	pA2 := newProject(t, orgA.ID, "Üsküdar Ofis")
	pB := newProject(t, orgB.ID, "Başka Firma Projesi")

	upload := func(t *testing.T, p *domain.Project, orgID string, shade uint8, stage string) *domain.ProjectPhoto {
		t.Helper()
		ph, err := projectSvc.UploadPhoto(ctx, p.ID, orgID, service.UploadInput{
			OriginalName: "salon.jpg", Reader: bytes.NewReader(testJPEG(t, shade)), Stage: stage,
			Description: "Salon, sıva bitti", UserID: ownerA.ID,
		})
		if err != nil {
			t.Fatal(err)
		}
		return ph
	}
	src := upload(t, pA, orgA.ID, 10, domain.PhotoStageBefore)
	srcOtherProject := upload(t, pA2, orgA.ID, 20, domain.PhotoStageProgress)
	srcB := upload(t, pB, orgB.ID, 30, domain.PhotoStageProgress)

	fake := newFakeOpenAI(t)
	client, err := openai.New("sk-test-sahte", openai.WithBaseURL(fake.srv.URL), openai.WithRetryDelay(time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	cfg := service.AIImageConfig{Model: "gpt-image-2.5-sunburst", Quality: "medium", MonthlyLimit: 50, UserHourlyLimit: 50, Workers: 1}
	newSvc := func(t *testing.T, gen service.ImageGenerator, cfg service.AIImageConfig) *service.AIImageService {
		t.Helper()
		s := service.NewAIImageService(pool, q, projectSvc, gen, cfg)
		// Paralel koşan başka test paketlerinin işlerine dokunma.
		if err := s.ScopeToOrganization(orgA.ID); err != nil {
			t.Fatal(err)
		}
		return s
	}
	svc := newSvc(t, client, cfg)

	photoByID := func(t *testing.T, projectID, orgID, id string) *domain.ProjectPhoto {
		t.Helper()
		list, err := projectSvc.ListPhotos(ctx, projectID, orgID)
		if err != nil {
			t.Fatal(err)
		}
		for i := range list {
			if list[i].ID == id {
				return &list[i]
			}
		}
		return nil
	}
	photoCount := func(t *testing.T, projectID, orgID string) int {
		t.Helper()
		list, err := projectSvc.ListPhotos(ctx, projectID, orgID)
		if err != nil {
			t.Fatal(err)
		}
		return len(list)
	}
	processAll := func(t *testing.T, s *service.AIImageService) {
		t.Helper()
		for {
			ok, err := s.ProcessNext(ctx)
			if err != nil {
				t.Fatal(err)
			}
			if !ok {
				return
			}
		}
	}
	readPhoto := func(t *testing.T, projectID, photoID, orgID string) []byte {
		t.Helper()
		_, rc, err := projectSvc.OpenPhoto(ctx, projectID, photoID, orgID)
		if err != nil {
			t.Fatal(err)
		}
		defer rc.Close()
		b, _ := io.ReadAll(rc)
		return b
	}

	t.Run("anahtar yoksa kapalı: iş açılmaz, durum kapalı der", func(t *testing.T) {
		off := newSvc(t, nil, cfg)
		if off.Enabled() {
			t.Fatal("anahtarsız servis açık görünüyor")
		}
		_, _, err := off.CreateJob(ctx, service.CreateAIImageJobInput{
			OrganizationID: orgA.ID, ProjectID: pA.ID, UserID: ownerA.ID,
			Kind: domain.AIImageKindBeforeAfter, Prompt: "Beyaz boya", SourcePhotoID: src.ID,
		})
		if !errors.Is(err, service.ErrAIDisabled) {
			t.Fatalf("ErrAIDisabled bekleniyordu: %v", err)
		}
		st, err := off.Status(ctx, orgA.ID, "", true, true)
		if err != nil || st.Enabled || st.Model != "" {
			t.Fatalf("durum: %+v, %v", st, err)
		}
	})

	t.Run("önce/sonra: sırada -> bitti; sonuç yeni işaretli fotoğraf, kaynak dokunulmadı", func(t *testing.T) {
		before := readPhoto(t, pA.ID, src.ID, orgA.ID)
		countBefore := photoCount(t, pA.ID, orgA.ID)

		job, quota, err := svc.CreateJob(ctx, service.CreateAIImageJobInput{
			OrganizationID: orgA.ID, ProjectID: pA.ID, UserID: ownerA.ID,
			Kind: domain.AIImageKindBeforeAfter, Prompt: "  Alçıpan asma tavan, spot ışıklı, beyaz boya  ", SourcePhotoID: src.ID,
		})
		if err != nil {
			t.Fatal(err)
		}
		if job.Status != domain.AIImageJobQueued || job.Prompt != "Alçıpan asma tavan, spot ışıklı, beyaz boya" || job.Model != cfg.Model {
			t.Fatalf("iş: %+v", job)
		}
		if quota.UsedThisMonth != 1 || quota.Remaining != 49 || quota.MonthlyLimit != 50 {
			t.Fatalf("hak: %+v", quota)
		}
		got, err := svc.GetJob(ctx, pA.ID, job.ID, orgA.ID, ownerA.ID)
		if err != nil || got.Status != domain.AIImageJobQueued {
			t.Fatalf("GET (sırada): %+v, %v", got, err)
		}

		processAll(t, svc)

		got, err = svc.GetJob(ctx, pA.ID, job.ID, orgA.ID, ownerA.ID)
		if err != nil || got.Status != domain.AIImageJobDone || got.ResultPhotoID == nil || got.Error != "" || got.FinishedAt == nil {
			t.Fatalf("GET (bitti): %+v, %v", got, err)
		}
		call := fake.last()
		if call.Path != "/images/edits" || call.Model != cfg.Model || call.Fields["output_format"] != "jpeg" || call.Fields["quality"] != "medium" {
			t.Errorf("OpenAI isteği: %+v", call)
		}
		if _, ok := call.Fields["input_fidelity"]; ok {
			t.Error("gpt-image-2.5'te input_fidelity gönderilmemeli")
		}
		if !bytes.Equal(call.Image, before) {
			t.Error("OpenAI'ye giden görsel kaynak fotoğraf değil")
		}
		if !strings.Contains(call.Prompt, "same perspective and camera angle") || !strings.Contains(call.Prompt, "Alçıpan asma tavan, spot ışıklı") {
			t.Errorf("prompt: %q", call.Prompt)
		}
		if len(call.Fields["safety_identifier"]) != 64 || strings.Contains(call.Fields["safety_identifier"], ownerA.ID) {
			t.Errorf("safety_identifier kişisel veri taşımamalı: %q", call.Fields["safety_identifier"])
		}

		res := photoByID(t, pA.ID, orgA.ID, *got.ResultPhotoID)
		if res == nil || res.AI == nil {
			t.Fatalf("sonuç fotoğrafı listede yok ya da işaretsiz: %+v", res)
		}
		if res.ID == src.ID || res.Stage != domain.PhotoStageAfter || res.AI.Kind != domain.AIImageKindBeforeAfter ||
			res.AI.Prompt != job.Prompt || res.AI.SourcePhotoID == nil || *res.AI.SourcePhotoID != src.ID ||
			res.AI.SourceDate == nil || !strings.Contains(res.Description, "yapay zekâ") || res.TakenAt != nil ||
			res.UploadedBy == nil || *res.UploadedBy != ownerA.ID || res.MIMEType != "image/jpeg" {
			t.Errorf("sonuç fotoğrafı: %+v / %+v", res, res.AI)
		}
		if photoCount(t, pA.ID, orgA.ID) != countBefore+1 {
			t.Error("tam bir yeni fotoğraf eklenmeli")
		}
		orig := photoByID(t, pA.ID, orgA.ID, src.ID)
		if orig == nil || orig.AI != nil || orig.SHA256 != src.SHA256 || orig.Stage != src.Stage || orig.Description != src.Description {
			t.Errorf("kaynak fotoğraf değişti: %+v", orig)
		}
		if !bytes.Equal(readPhoto(t, pA.ID, src.ID, orgA.ID), before) {
			t.Error("kaynak fotoğrafın baytları değişti")
		}
		// Günlük rapor gerçek şantiye kaydıdır: üretilmiş görsel girmez.
		pid, _ := repository.StringToUUID(pA.ID)
		oid, _ := repository.StringToUUID(orgA.ID)
		day, err := q.ListPhotosTakenOn(ctx, sqlc.ListPhotosTakenOnParams{ProjectID: pid, OrganizationID: oid, ReportDate: repository.TimeToDate(service.IstanbulToday())})
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range day {
			if d.ID.String() == res.ID {
				t.Error("yapay zekâ görseli günlük rapor fotoğraflarına girdi")
			}
		}
	})

	t.Run("iyileştir: açıklama isteğe bağlı, kaynağın aşamasında kalır", func(t *testing.T) {
		job, _, err := svc.CreateJob(ctx, service.CreateAIImageJobInput{
			OrganizationID: orgA.ID, ProjectID: pA.ID, UserID: ownerA.ID,
			Kind: domain.AIImageKindEnhance, SourcePhotoID: src.ID,
		})
		if err != nil {
			t.Fatal(err)
		}
		processAll(t, svc)
		got, _ := svc.GetJob(ctx, pA.ID, job.ID, orgA.ID, ownerA.ID)
		if got.Status != domain.AIImageJobDone {
			t.Fatalf("iş: %+v", got)
		}
		if p := fake.last().Prompt; !strings.Contains(p, "Do not add, remove") {
			t.Errorf("iyileştirme talimatı: %q", p)
		}
		res := photoByID(t, pA.ID, orgA.ID, *got.ResultPhotoID)
		if res == nil || res.Stage != src.Stage || res.AI.Kind != domain.AIImageKindEnhance {
			t.Errorf("sonuç: %+v", res)
		}
	})

	t.Run("yeni görsel: kaynaksız üretim ucu", func(t *testing.T) {
		job, _, err := svc.CreateJob(ctx, service.CreateAIImageJobInput{
			OrganizationID: orgA.ID, ProjectID: pA.ID, UserID: ownerA.ID,
			Kind: domain.AIImageKindGenerate, Prompt: "Banyo seramik, duşakabin",
		})
		if err != nil {
			t.Fatal(err)
		}
		processAll(t, svc)
		got, _ := svc.GetJob(ctx, pA.ID, job.ID, orgA.ID, ownerA.ID)
		if got.Status != domain.AIImageJobDone {
			t.Fatalf("iş: %+v", got)
		}
		call := fake.last()
		if call.Path != "/images/generations" || !strings.Contains(call.Prompt, "Banyo seramik, duşakabin") || call.Image != nil {
			t.Errorf("OpenAI isteği: %+v", call)
		}
		res := photoByID(t, pA.ID, orgA.ID, *got.ResultPhotoID)
		if res == nil || res.Stage != domain.PhotoStageProgress || res.AI.SourcePhotoID != nil || res.AI.SourceDate != nil {
			t.Errorf("sonuç: %+v", res)
		}
	})

	t.Run("girdi kuralları", func(t *testing.T) {
		cases := []struct {
			in   service.CreateAIImageJobInput
			want error
		}{
			{service.CreateAIImageJobInput{Kind: "boya"}, service.ErrAIInvalidKind},
			{service.CreateAIImageJobInput{Kind: domain.AIImageKindBeforeAfter, SourcePhotoID: src.ID}, service.ErrAIPromptRequired},
			{service.CreateAIImageJobInput{Kind: domain.AIImageKindBeforeAfter, Prompt: "x"}, service.ErrAISourceRequired},
			{service.CreateAIImageJobInput{Kind: domain.AIImageKindGenerate, Prompt: strings.Repeat("ğ", 1001)}, service.ErrAIPromptTooLong},
		}
		for _, c := range cases {
			c.in.OrganizationID, c.in.ProjectID, c.in.UserID = orgA.ID, pA.ID, ownerA.ID
			if _, _, err := svc.CreateJob(ctx, c.in); !errors.Is(err, c.want) {
				t.Errorf("%+v: %v, beklenen %v", c.in, err, c.want)
			}
		}
	})

	t.Run("OpenAI reddi: iş Türkçe nedenle başarısız, fotoğraf eklenmez, hak düşmez", func(t *testing.T) {
		count := photoCount(t, pA.ID, orgA.ID)
		st0, _ := svc.Status(ctx, orgA.ID, "", true, false)
		fake.setMode("moderation")
		defer fake.setMode("ok")
		job, _, err := svc.CreateJob(ctx, service.CreateAIImageJobInput{
			OrganizationID: orgA.ID, ProjectID: pA.ID, UserID: ownerA.ID,
			Kind: domain.AIImageKindBeforeAfter, Prompt: "Duvarlar beyaz boyalı", SourcePhotoID: src.ID,
		})
		if err != nil {
			t.Fatal(err)
		}
		processAll(t, svc)
		got, _ := svc.GetJob(ctx, pA.ID, job.ID, orgA.ID, ownerA.ID)
		if got.Status != domain.AIImageJobFailed || !strings.Contains(got.Error, "güvenlik kurallarına") || got.ResultPhotoID != nil {
			t.Fatalf("iş: %+v", got)
		}
		if strings.Contains(got.Error, "safety system") {
			t.Error("kullanıcıya OpenAI'nin İngilizce metni gösterilmemeli")
		}
		if photoCount(t, pA.ID, orgA.ID) != count {
			t.Error("başarısız işte fotoğraf eklenmemeli")
		}
		st1, _ := svc.Status(ctx, orgA.ID, "", true, false)
		if st1.Quota.UsedThisMonth != st0.Quota.UsedThisMonth {
			t.Errorf("başarısız iş hakkı düşürmemeli: %d -> %d", st0.Quota.UsedThisMonth, st1.Quota.UsedThisMonth)
		}

		fake.setMode("quota")
		job, _, err = svc.CreateJob(ctx, service.CreateAIImageJobInput{
			OrganizationID: orgA.ID, ProjectID: pA.ID, UserID: ownerA.ID,
			Kind: domain.AIImageKindGenerate, Prompt: "Mutfak dolabı",
		})
		if err != nil {
			t.Fatal(err)
		}
		processAll(t, svc)
		got, _ = svc.GetJob(ctx, pA.ID, job.ID, orgA.ID, ownerA.ID)
		if got.Status != domain.AIImageJobFailed || !strings.Contains(got.Error, "kredisi") {
			t.Fatalf("kota işi: %+v", got)
		}
	})

	t.Run("kaynak sonradan silindiyse iş başarısız", func(t *testing.T) {
		tmp := upload(t, pA, orgA.ID, 40, domain.PhotoStageProgress)
		job, _, err := svc.CreateJob(ctx, service.CreateAIImageJobInput{
			OrganizationID: orgA.ID, ProjectID: pA.ID, UserID: ownerA.ID,
			Kind: domain.AIImageKindEnhance, SourcePhotoID: tmp.ID,
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := projectSvc.DeletePhoto(ctx, pA.ID, tmp.ID, orgA.ID, ownerA.ID); err != nil {
			t.Fatal(err)
		}
		calls := fake.callCount()
		processAll(t, svc)
		got, _ := svc.GetJob(ctx, pA.ID, job.ID, orgA.ID, ownerA.ID)
		if got.Status != domain.AIImageJobFailed || !strings.Contains(got.Error, "silinmiş") {
			t.Fatalf("iş: %+v", got)
		}
		if fake.callCount() != calls {
			t.Error("silinmiş kaynak OpenAI'ye gönderilmemeli")
		}
	})

	t.Run("aylık firma sınırı: dolunca 429 kalan 0; başka firma etkilenmez", func(t *testing.T) {
		st, err := svc.Status(ctx, orgA.ID, "", true, true)
		if err != nil {
			t.Fatal(err)
		}
		if st.Quota.UsedThisMonth != 3 {
			t.Fatalf("bu ay 3 başarılı görsel bekleniyordu (başarısızlar sayılmaz): %+v", st.Quota)
		}
		limited := cfg
		limited.MonthlyLimit = st.Quota.UsedThisMonth
		ls := newSvc(t, client, limited)
		_, _, err = ls.CreateJob(ctx, service.CreateAIImageJobInput{
			OrganizationID: orgA.ID, ProjectID: pA.ID, UserID: otherA.ID,
			Kind: domain.AIImageKindGenerate, Prompt: "Cephe",
		})
		var lim *service.AILimitError
		if !errors.As(err, &lim) || lim.Code != "ai_monthly_limit" || lim.Quota.Remaining != 0 ||
			!strings.Contains(lim.Message, "3/3") || !strings.Contains(lim.Message, "doldu") {
			t.Fatalf("aylık sınır: %v (%+v)", err, lim)
		}
		// Firma B'nin hakkı ayrı.
		stB, err := ls.Status(ctx, orgB.ID, "", true, true)
		if err != nil || stB.Quota.UsedThisMonth != 0 || len(stB.UsageByUser) != 0 {
			t.Fatalf("firma B: %+v, %v", stB, err)
		}
		// Sahip/Yönetici kişi kişi görür; izni olmayan ve Sahip olmayan hiç görmez.
		if len(st.UsageByUser) != 1 || st.UsageByUser[0].FullName != "yz_sahip_a" || st.UsageByUser[0].Images != 3 {
			t.Errorf("kişi kişi kullanım: %+v", st.UsageByUser)
		}
		none, _ := svc.Status(ctx, orgA.ID, "", false, false)
		if none.Quota != nil || none.UsageByUser != nil || !none.Enabled || none.CanUse {
			t.Errorf("izinsiz durum: %+v", none)
		}
	})

	t.Run("kişi başı sınırlar: saatlik ve aynı anda süren iş", func(t *testing.T) {
		hourly := cfg
		hourly.UserHourlyLimit = 2
		hs := newSvc(t, client, hourly)
		_, _, err := hs.CreateJob(ctx, service.CreateAIImageJobInput{
			OrganizationID: orgA.ID, ProjectID: pA.ID, UserID: ownerA.ID,
			Kind: domain.AIImageKindGenerate, Prompt: "Cephe",
		})
		var lim *service.AILimitError
		if !errors.As(err, &lim) || lim.Code != "ai_user_rate_limit" || !strings.Contains(lim.Message, "saatte en fazla 2") ||
			!strings.Contains(lim.Message, "kalan hak: 47") {
			t.Fatalf("saatlik sınır: %v (%+v)", err, lim)
		}
		// Aynı firmada başka kişi etkilenmez; o da aynı anda en çok 2 iş.
		for i := 0; i < 2; i++ {
			if _, _, err := hs.CreateJob(ctx, service.CreateAIImageJobInput{
				OrganizationID: orgA.ID, ProjectID: pA.ID, UserID: otherA.ID,
				Kind: domain.AIImageKindGenerate, Prompt: fmt.Sprintf("Cephe %d", i),
			}); err != nil {
				t.Fatalf("diğer kişi %d: %v", i, err)
			}
		}
		_, _, err = svc.CreateJob(ctx, service.CreateAIImageJobInput{
			OrganizationID: orgA.ID, ProjectID: pA.ID, UserID: otherA.ID,
			Kind: domain.AIImageKindGenerate, Prompt: "Cephe 3",
		})
		if !errors.As(err, &lim) || lim.Code != "ai_user_busy" {
			t.Fatalf("süren iş sınırı: %v", err)
		}
		processAll(t, svc)
	})

	t.Run("firma ve proje izolasyonu", func(t *testing.T) {
		// Başka firmanın kullanıcısı A'nın projesinde iş açamaz.
		_, _, err := svc.CreateJob(ctx, service.CreateAIImageJobInput{
			OrganizationID: orgB.ID, ProjectID: pA.ID, UserID: ownerB.ID,
			Kind: domain.AIImageKindBeforeAfter, Prompt: "x", SourcePhotoID: src.ID,
		})
		if !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("başka firmanın projesi: %v", err)
		}
		// Kendi projesinde başka firmanın fotoğrafını kaynak gösteremez.
		_, _, err = svc.CreateJob(ctx, service.CreateAIImageJobInput{
			OrganizationID: orgB.ID, ProjectID: pB.ID, UserID: ownerB.ID,
			Kind: domain.AIImageKindBeforeAfter, Prompt: "x", SourcePhotoID: src.ID,
		})
		var nf *service.NotFoundError
		if !errors.As(err, &nf) {
			t.Errorf("başka firmanın fotoğrafı kaynak: %v", err)
		}
		// Aynı firmada başka projenin fotoğrafı da kaynak olamaz.
		_, _, err = svc.CreateJob(ctx, service.CreateAIImageJobInput{
			OrganizationID: orgA.ID, ProjectID: pA.ID, UserID: ownerA.ID,
			Kind: domain.AIImageKindEnhance, SourcePhotoID: srcOtherProject.ID,
		})
		if !errors.As(err, &nf) {
			t.Errorf("başka projenin fotoğrafı kaynak: %v", err)
		}
		_ = srcB

		jobs, err := svc.ListJobs(ctx, pA.ID, orgA.ID, ownerA.ID)
		if err != nil || len(jobs) == 0 {
			t.Fatalf("liste: %v %v", jobs, err)
		}
		mine := jobs[0]
		for _, probe := range []struct{ name, project, org, user string }{
			{"başka firma", pA.ID, orgB.ID, ownerB.ID},
			{"aynı firmada başka kişi", pA.ID, orgA.ID, otherA.ID},
			{"başka proje yolu", pA2.ID, orgA.ID, ownerA.ID},
		} {
			if _, err := svc.GetJob(ctx, probe.project, mine.ID, probe.org, probe.user); !errors.Is(err, service.ErrAIJobNotFound) {
				t.Errorf("%s işi görmemeli: %v", probe.name, err)
			}
		}
		if other, _ := svc.ListJobs(ctx, pA.ID, orgB.ID, ownerB.ID); len(other) != 0 {
			t.Errorf("başka firma listesi boş olmalı: %d", len(other))
		}
	})

	t.Run("kapalı projede iş açılmaz; iş sürerken kapanırsa görsel eklenmez", func(t *testing.T) {
		job, _, err := svc.CreateJob(ctx, service.CreateAIImageJobInput{
			OrganizationID: orgA.ID, ProjectID: pA2.ID, UserID: ownerA.ID,
			Kind: domain.AIImageKindEnhance, SourcePhotoID: srcOtherProject.ID,
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(ctx, "UPDATE projects SET status = $2 WHERE id = $1", pA2.ID, domain.ProjectStatusCompleted); err != nil {
			t.Fatal(err)
		}
		count := photoCount(t, pA2.ID, orgA.ID)
		processAll(t, svc)
		got, _ := svc.GetJob(ctx, pA2.ID, job.ID, orgA.ID, ownerA.ID)
		if got.Status != domain.AIImageJobFailed || !strings.Contains(got.Error, "tamamlandı") {
			t.Fatalf("iş: %+v", got)
		}
		if photoCount(t, pA2.ID, orgA.ID) != count {
			t.Error("kapalı projeye görsel eklenmemeli")
		}
		_, _, err = svc.CreateJob(ctx, service.CreateAIImageJobInput{
			OrganizationID: orgA.ID, ProjectID: pA2.ID, UserID: ownerA.ID,
			Kind: domain.AIImageKindGenerate, Prompt: "x",
		})
		if !errors.Is(err, service.ErrProjectLocked) {
			t.Errorf("kapalı projede iş: %v", err)
		}
	})

	t.Run("yeniden başlatma: sırada ve çalışırken kalan işler başarısız olur", func(t *testing.T) {
		mk := func(prompt string) *domain.AIImageJob {
			j, _, err := svc.CreateJob(ctx, service.CreateAIImageJobInput{
				OrganizationID: orgA.ID, ProjectID: pA.ID, UserID: otherA.ID,
				Kind: domain.AIImageKindGenerate, Prompt: prompt,
			})
			if err != nil {
				t.Fatal(err)
			}
			return j
		}
		queued := mk("Sırada kalan")
		running := mk("Çalışırken kalan")
		// Önceki süreç birini almış ve yarıda ölmüş gibi: doğrudan "running".
		if _, err := pool.Exec(ctx, "UPDATE ai_image_jobs SET status = 'running', started_at = now() WHERE id = $1", running.ID); err != nil {
			t.Fatal(err)
		}
		n, err := newSvc(t, client, cfg).RecoverInterrupted(ctx)
		if err != nil || n != 2 {
			t.Fatalf("kapatılan: %d, %v", n, err)
		}
		for _, j := range []*domain.AIImageJob{queued, running} {
			got, _ := svc.GetJob(ctx, pA.ID, j.ID, orgA.ID, otherA.ID)
			if got.Status != domain.AIImageJobFailed || !strings.Contains(got.Error, "yeniden başlatıldığı") || got.FinishedAt == nil {
				t.Errorf("iş %s: %+v", j.Prompt, got)
			}
		}
		if ok, _ := svc.ProcessNext(ctx); ok {
			t.Error("kapatılan iş yeniden çalışmamalı")
		}
	})

	t.Run("işçi: Run uyandırılınca işi kendiliğinden bitirir, ctx iptaliyle durur", func(t *testing.T) {
		runCtx, cancel := context.WithCancel(ctx)
		done := make(chan struct{})
		go func() {
			svc.Run(runCtx)
			close(done)
		}()
		job, _, err := svc.CreateJob(ctx, service.CreateAIImageJobInput{
			OrganizationID: orgA.ID, ProjectID: pA.ID, UserID: ownerA.ID,
			Kind: domain.AIImageKindGenerate, Prompt: "İşçi testi",
		})
		if err != nil {
			cancel()
			t.Fatal(err)
		}
		deadline := time.Now().Add(10 * time.Second)
		for {
			got, _ := svc.GetJob(ctx, pA.ID, job.ID, orgA.ID, ownerA.ID)
			if got.Status == domain.AIImageJobDone {
				break
			}
			if time.Now().After(deadline) {
				cancel()
				t.Fatalf("işçi işi bitirmedi: %+v", got)
			}
			time.Sleep(50 * time.Millisecond)
		}
		cancel()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Fatal("Run ctx iptalinde dönmedi")
		}
	})
}
