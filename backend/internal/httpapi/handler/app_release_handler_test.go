package handler

// Uzaktan güncelleme uçları -- HTTP sözleşmesi (mobile/API_CONTRACT.md).
// Veritabanı gerektirmez: handler'lar doğrudan, geçici bir APP_RELEASES_DIR
// ile çağrılır. Kimlik doğrulama zinciri (download 401/403) router
// seviyesinde ayrıca test edilir (httpapi/router_app_release_test.go ve
// middleware/app_release_security_test.go).

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"testing"
	"time"

	chimw "github.com/go-chi/chi/v5/middleware"

	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func writeTestAppRelease(t *testing.T, dir string, build int, sha string) []byte {
	t.Helper()
	apk := make([]byte, 200<<10)
	for i := range apk {
		apk[i] = byte((i*13 + build) % 253)
	}
	sum := sha256.Sum256(apk)
	if sha == "" {
		sha = hex.EncodeToString(sum[:])
	}
	android := filepath.Join(dir, "android")
	if err := os.MkdirAll(android, 0o755); err != nil {
		t.Fatal(err)
	}
	file := fmt.Sprintf("arvend-%d.apk", build)
	if err := os.WriteFile(filepath.Join(android, file), apk, 0o644); err != nil {
		t.Fatal(err)
	}
	manifest, _ := json.Marshal(map[string]any{
		"build": build, "version": "1.2.0", "sha256": sha, "size": len(apk),
		"notes": "Uzaktan güncelleme geldi", "min_build": 2, "file": file,
		"published_at": "2026-09-28T10:00:00Z",
		// Diskteki fazladan alanlar istemciye ASLA taşınmamalı.
		"internal_path": "/var/lib/arvend/app-releases/android/" + file,
	})
	if err := os.WriteFile(filepath.Join(android, "latest.json"), manifest, 0o644); err != nil {
		t.Fatal(err)
	}
	return apk
}

func newTestAppReleaseHandler(dir string) *AppReleaseHandler {
	return NewAppReleaseHandler(service.NewAppReleaseService(dir))
}

func decodeJSONMap(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &m); err != nil {
		t.Fatalf("yanıt JSON değil: %v (%q)", err, rec.Body.String())
	}
	return m
}

func sortedKeys(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func TestAppVersion_ValidRelease(t *testing.T) {
	dir := t.TempDir()
	apk := writeTestAppRelease(t, dir, 3, "")
	h := newTestAppReleaseHandler(dir)

	rec := httptest.NewRecorder()
	h.Version(rec, httptest.NewRequest(http.MethodGet, "/api/v1/mobile/app-version?platform=android", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (%s)", rec.Code, rec.Body.String())
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "no-store" {
		t.Fatalf("Cache-Control = %q, want no-store", cc)
	}
	body := decodeJSONMap(t, rec)
	wantKeys := []string{"build", "min_build", "notes", "platform", "published_at", "sha256", "size", "version"}
	if got := sortedKeys(body); !reflect.DeepEqual(got, wantKeys) {
		t.Fatalf("alanlar = %v, want YALNIZCA %v", got, wantKeys)
	}
	sum := sha256.Sum256(apk)
	want := map[string]any{
		"platform": "android", "build": float64(3), "version": "1.2.0",
		"sha256": hex.EncodeToString(sum[:]), "size": float64(len(apk)),
		"notes": "Uzaktan güncelleme geldi", "min_build": float64(2),
		"published_at": "2026-09-28T10:00:00Z",
	}
	if !reflect.DeepEqual(body, want) {
		t.Fatalf("gövde = %v, want %v", body, want)
	}
}

func TestAppVersion_NoRelease(t *testing.T) {
	for name, setup := range map[string]func(t *testing.T, dir string){
		"dizin yok": func(*testing.T, string) {},
		"bozuk json": func(t *testing.T, dir string) {
			if err := os.MkdirAll(filepath.Join(dir, "android"), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, "android", "latest.json"), []byte("{bozuk"), 0o644); err != nil {
				t.Fatal(err)
			}
		},
		"özet tutmuyor": func(t *testing.T, dir string) {
			writeTestAppRelease(t, dir, 3, "0000000000000000000000000000000000000000000000000000000000000000")
		},
	} {
		t.Run(name, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "app-releases")
			setup(t, dir)
			h := newTestAppReleaseHandler(dir)
			rec := httptest.NewRecorder()
			h.Version(rec, httptest.NewRequest(http.MethodGet, "/api/v1/mobile/app-version?platform=android", nil))
			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200 (yayın yokken asla hata dönmez)", rec.Code)
			}
			if cc := rec.Header().Get("Cache-Control"); cc != "no-store" {
				t.Fatalf("Cache-Control = %q, want no-store", cc)
			}
			body := decodeJSONMap(t, rec)
			want := map[string]any{"platform": "android", "build": float64(0)}
			if !reflect.DeepEqual(body, want) {
				t.Fatalf("gövde = %v, want %v", body, want)
			}
		})
	}
}

func TestAppVersion_UnknownPlatform400(t *testing.T) {
	dir := t.TempDir()
	writeTestAppRelease(t, dir, 3, "")
	h := newTestAppReleaseHandler(dir)
	for _, q := range []string{"", "?platform=", "?platform=ios", "?platform=ANDROID", "?platform=..%2Fandroid"} {
		rec := httptest.NewRecorder()
		h.Version(rec, httptest.NewRequest(http.MethodGet, "/api/v1/mobile/app-version"+q, nil))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%q: status = %d, want 400", q, rec.Code)
			continue
		}
		if body := decodeJSONMap(t, rec); body["error"] == nil || body["build"] != nil {
			t.Errorf("%q: gövde = %v, want yalnızca {error}", q, body)
		}
	}
}

func TestAppDownload_StreamsExactBytesWithHeaders(t *testing.T) {
	dir := t.TempDir()
	apk := writeTestAppRelease(t, dir, 3, "")
	sum := sha256.Sum256(apk)
	h := newTestAppReleaseHandler(dir)

	rec := httptest.NewRecorder()
	h.Download(rec, httptest.NewRequest(http.MethodGet, "/api/v1/mobile/app-download?platform=android", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (%s)", rec.Code, rec.Body.String())
	}
	got := rec.Body.Bytes()
	if len(got) != len(apk) || sha256.Sum256(got) != sum {
		t.Fatalf("akıtılan baytlar farklı: %d bayt, want %d", len(got), len(apk))
	}
	for k, want := range map[string]string{
		"Content-Type":           "application/vnd.android.package-archive",
		"Content-Disposition":    `attachment; filename="ARVEND-1.2.0.apk"`,
		"ETag":                   `"` + hex.EncodeToString(sum[:]) + `"`,
		"Content-Length":         strconv.Itoa(len(apk)),
		"Accept-Ranges":          "bytes",
		"X-Content-Type-Options": "nosniff",
		"Cache-Control":          "private, no-store",
	} {
		if got := rec.Header().Get(k); got != want {
			t.Errorf("%s = %q, want %q", k, got, want)
		}
	}
}

func TestAppDownload_RangeResume(t *testing.T) {
	dir := t.TempDir()
	apk := writeTestAppRelease(t, dir, 3, "")
	sum := sha256.Sum256(apk)
	etag := `"` + hex.EncodeToString(sum[:]) + `"`
	h := newTestAppReleaseHandler(dir)

	// Yarıda kalan indirmenin devamı: If-Range güncel ETag'le -> 206.
	req := httptest.NewRequest(http.MethodGet, "/api/v1/mobile/app-download?platform=android", nil)
	req.Header.Set("Range", "bytes=1000-")
	req.Header.Set("If-Range", etag)
	rec := httptest.NewRecorder()
	h.Download(rec, req)
	if rec.Code != http.StatusPartialContent {
		t.Fatalf("status = %d, want 206", rec.Code)
	}
	if cr, want := rec.Header().Get("Content-Range"), fmt.Sprintf("bytes 1000-%d/%d", len(apk)-1, len(apk)); cr != want {
		t.Fatalf("Content-Range = %q, want %q", cr, want)
	}
	if !reflect.DeepEqual(rec.Body.Bytes(), apk[1000:]) {
		t.Fatal("206 gövdesi dosyanın 1000. baytından sonrasıyla aynı değil")
	}

	// Ara aralık.
	req = httptest.NewRequest(http.MethodGet, "/api/v1/mobile/app-download?platform=android", nil)
	req.Header.Set("Range", "bytes=10-19")
	rec = httptest.NewRecorder()
	h.Download(rec, req)
	if rec.Code != http.StatusPartialContent || !reflect.DeepEqual(rec.Body.Bytes(), apk[10:20]) {
		t.Fatalf("bytes=10-19: status = %d, gövde %d bayt", rec.Code, rec.Body.Len())
	}

	// Arada yeni bir sürüm yayınlandıysa (eski ETag): parçalı devam YOK,
	// dosyanın tamamı baştan gelir -- iki sürümün baytları karışmaz.
	req = httptest.NewRequest(http.MethodGet, "/api/v1/mobile/app-download?platform=android", nil)
	req.Header.Set("Range", "bytes=1000-")
	req.Header.Set("If-Range", `"eski-surumun-ozeti"`)
	rec = httptest.NewRecorder()
	h.Download(rec, req)
	if rec.Code != http.StatusOK || rec.Body.Len() != len(apk) {
		t.Fatalf("eski If-Range: status = %d, %d bayt; want 200 ve tüm dosya", rec.Code, rec.Body.Len())
	}
}

func TestAppDownload_NoRelease404(t *testing.T) {
	for name, setup := range map[string]func(t *testing.T, dir string){
		"dizin yok": func(*testing.T, string) {},
		"özet tutmuyor": func(t *testing.T, dir string) {
			writeTestAppRelease(t, dir, 3, "1111111111111111111111111111111111111111111111111111111111111111")
		},
	} {
		t.Run(name, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "app-releases")
			setup(t, dir)
			h := newTestAppReleaseHandler(dir)
			rec := httptest.NewRecorder()
			h.Download(rec, httptest.NewRequest(http.MethodGet, "/api/v1/mobile/app-download?platform=android", nil))
			if rec.Code != http.StatusNotFound {
				t.Fatalf("status = %d, want 404", rec.Code)
			}
			if body := decodeJSONMap(t, rec); body["error"] == nil {
				t.Fatalf("gövde = %v, want {error}", body)
			}
		})
	}
}

func TestAppDownload_UnknownPlatform400(t *testing.T) {
	dir := t.TempDir()
	writeTestAppRelease(t, dir, 3, "")
	h := newTestAppReleaseHandler(dir)
	for _, q := range []string{"", "?platform=ios", "?platform=..%2F..%2Fetc"} {
		rec := httptest.NewRecorder()
		h.Download(rec, httptest.NewRequest(http.MethodGet, "/api/v1/mobile/app-download"+q, nil))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%q: status = %d, want 400", q, rec.Code)
		}
		if ct := rec.Header().Get("Content-Type"); ct == "application/vnd.android.package-archive" {
			t.Errorf("%q: 400 yanıtı APK gibi işaretlenmiş", q)
		}
	}
}

// writeLargeTestAppRelease, soket tamponlarını kesin aşacak büyüklükte
// (32 MB) bir yayın yazar -- yazma süresi testleri için.
func writeLargeTestAppRelease(t *testing.T, dir string) []byte {
	t.Helper()
	android := filepath.Join(dir, "android")
	if err := os.MkdirAll(android, 0o755); err != nil {
		t.Fatal(err)
	}
	apk := make([]byte, 32<<20)
	for i := range apk {
		apk[i] = byte(i % 251)
	}
	sum := sha256.Sum256(apk)
	if err := os.WriteFile(filepath.Join(android, "arvend-3.apk"), apk, 0o644); err != nil {
		t.Fatal(err)
	}
	manifest, _ := json.Marshal(map[string]any{
		"build": 3, "version": "1.2.0", "sha256": hex.EncodeToString(sum[:]), "size": len(apk),
		"notes": "", "min_build": 0, "file": "arvend-3.apk", "published_at": "2026-09-28T10:00:00Z",
	})
	if err := os.WriteFile(filepath.Join(android, "latest.json"), manifest, 0o644); err != nil {
		t.Fatal(err)
	}
	return apk
}

// startAppDownloadServer: gerçek bir http.Server + chi Logger sarmalayıcısı
// (router'daki gibi), verilen genel WriteTimeout ile.
func startAppDownloadServer(t *testing.T, h *AppReleaseHandler, writeTimeout time.Duration) (*httptest.Server, *http.Client) {
	t.Helper()
	srv := httptest.NewUnstartedServer(chimw.Logger(http.HandlerFunc(h.Download)))
	srv.Config.WriteTimeout = writeTimeout
	srv.Start()
	t.Cleanup(srv.Close)
	client := &http.Client{Transport: &http.Transport{}}
	t.Cleanup(client.CloseIdleConnections)
	return srv, client
}

// Sunucunun genel WriteTimeout'u (üretimde 5 dk) büyük APK'yı yavaş hatta
// yarıda kesmemeli: Download yazma süresini yalnızca kendisi için uzatır.
// Kısa bir WriteTimeout kurulur ve istemci gövdeyi bilerek geç okur.
func TestAppDownload_OutlivesServerWriteTimeout(t *testing.T) {
	dir := t.TempDir()
	apk := writeLargeTestAppRelease(t, dir)
	sum := sha256.Sum256(apk)
	h := newTestAppReleaseHandler(dir)
	srv, client := startAppDownloadServer(t, h, 200*time.Millisecond)

	resp, err := client.Get(srv.URL + "/api/v1/mobile/app-download?platform=android")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	time.Sleep(4 * srv.Config.WriteTimeout)
	got, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("gövde okunurken bağlantı kesildi (WriteTimeout uzatılmamış): %v", err)
	}
	if len(got) != len(apk) || sha256.Sum256(got) != sum {
		t.Fatalf("gövde eksik/farklı: %d bayt, want %d", len(got), len(apk))
	}
}

// Yavaş ama İLERLEYEN bir indirme, boşta kalma süresinin katlarınca sürse
// de kesilmez: her yazma son tarihi erteler.
func TestAppDownload_SlowButProgressingClientFinishes(t *testing.T) {
	dir := t.TempDir()
	apk := writeLargeTestAppRelease(t, dir)
	sum := sha256.Sum256(apk)
	h := newTestAppReleaseHandler(dir)
	h.idleTimeout = 500 * time.Millisecond
	srv, client := startAppDownloadServer(t, h, 200*time.Millisecond)

	start := time.Now()
	resp, err := client.Get(srv.URL + "/api/v1/mobile/app-download?platform=android")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var got []byte
	buf := make([]byte, 2<<20)
	for {
		n, err := io.ReadFull(resp.Body, buf)
		got = append(got, buf[:n]...)
		if err == io.EOF || err == io.ErrUnexpectedEOF {
			break
		}
		if err != nil {
			t.Fatalf("yavaş ama ilerleyen indirme kesildi (%d bayt sonra): %v", len(got), err)
		}
		time.Sleep(100 * time.Millisecond)
	}
	if len(got) != len(apk) || sha256.Sum256(got) != sum {
		t.Fatalf("gövde eksik/farklı: %d bayt, want %d", len(got), len(apk))
	}
	if elapsed := time.Since(start); elapsed < 2*h.idleTimeout {
		t.Fatalf("indirme %v sürdü; test boşta kalma süresini (%v) aşan bir indirmeyi sınamıyor", elapsed, h.idleTimeout)
	}
}

// Okumayı bırakan bir istemci (ör. sıfır TCP penceresi) bağlantıyı, dosya
// tanıtıcısını ve indirme slotunu bir saat TUTAMAZ: boşta kalma süresi
// dolunca sunucu yanıtı keser ve slotu geri verir.
func TestAppDownload_StalledClientIsDropped(t *testing.T) {
	dir := t.TempDir()
	apk := writeLargeTestAppRelease(t, dir)
	h := newTestAppReleaseHandler(dir)
	h.idleTimeout = 300 * time.Millisecond
	// Genel WriteTimeout uzun: bağlantıyı kesen, ilerlemeye bağlı süre olmalı.
	srv, client := startAppDownloadServer(t, h, time.Minute)

	resp, err := client.Get(srv.URL + "/api/v1/mobile/app-download?platform=android")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if _, err := io.ReadFull(resp.Body, make([]byte, 1024)); err != nil {
		t.Fatal(err)
	}
	if h.limiter.inFlight() != 1 {
		t.Fatalf("indirme sürerken inFlight = %d, want 1", h.limiter.inFlight())
	}

	// İstemci artık okumuyor.
	giveUp := time.Now().Add(5 * time.Second)
	for h.limiter.inFlight() != 0 {
		if time.Now().After(giveUp) {
			t.Fatal("okumayan istemci 5 sn sonra hâlâ indirme slotunu tutuyor (boşta kalma süresi uygulanmıyor)")
		}
		time.Sleep(20 * time.Millisecond)
	}
	got, err := io.ReadAll(resp.Body)
	if err == nil && len(got)+1024 == len(apk) {
		t.Fatal("bağlantı kesilmeliydi ama tüm dosya geldi")
	}
}

type failingResponseWriter struct{ http.ResponseWriter }

func (failingResponseWriter) Write([]byte) (int, error) { return 0, errors.New("bağlantı koptu") }

func TestProgressDeadlineWriter_RearmsOnProgressWithinHardCap(t *testing.T) {
	t0 := time.Date(2026, 9, 28, 10, 0, 0, 0, time.UTC)
	now := t0
	var deadlines []time.Time
	set := func(d time.Time) error { deadlines = append(deadlines, d); return nil }
	clock := func() time.Time { return now }
	last := func() time.Time { return deadlines[len(deadlines)-1] }

	p := newProgressDeadlineWriter(httptest.NewRecorder(), set, clock, 2*time.Minute, time.Hour)
	if len(deadlines) != 1 || !last().Equal(t0.Add(2*time.Minute)) {
		t.Fatalf("ilk son tarih = %v, want başlangıç+2dk", deadlines)
	}

	// idle/4'ten (30 sn) kısa aralıkla gelen yazmalar son tarihi her
	// seferinde yeniden kurmaz.
	now = t0.Add(10 * time.Second)
	if _, err := p.Write([]byte("a")); err != nil {
		t.Fatal(err)
	}
	if len(deadlines) != 1 {
		t.Fatalf("10 sn sonra yeniden kuruldu: %v", deadlines)
	}

	// İlerleme: son tarih now+idle'a ertelenir.
	now = t0.Add(40 * time.Second)
	if _, err := p.Write([]byte("b")); err != nil {
		t.Fatal(err)
	}
	if !last().Equal(now.Add(2 * time.Minute)) {
		t.Fatalf("son tarih = %v, want %v", last(), now.Add(2*time.Minute))
	}

	// Mutlak tavan: ilerleyen ama bitmeyen indirme bir saati geçemez.
	now = t0.Add(59 * time.Minute)
	if _, err := p.Write([]byte("c")); err != nil {
		t.Fatal(err)
	}
	if !last().Equal(t0.Add(time.Hour)) {
		t.Fatalf("son tarih = %v, want tavan %v", last(), t0.Add(time.Hour))
	}

	// Hiç bayt yazılamadıysa ilerleme yoktur: son tarih ertelenmez.
	deadlines = nil
	now = t0
	q := newProgressDeadlineWriter(failingResponseWriter{httptest.NewRecorder()}, set, clock, 2*time.Minute, time.Hour)
	now = t0.Add(time.Minute)
	if _, err := q.Write([]byte("d")); err == nil {
		t.Fatal("hata bekleniyordu")
	}
	if len(deadlines) != 1 {
		t.Fatalf("başarısız yazma son tarihi erteledi: %v", deadlines)
	}

	// ResponseController asıl yazıcıya ulaşabilmeli.
	if p.Unwrap() == nil {
		t.Fatal("Unwrap nil")
	}
}

// Kullanıcı başına ve toplam eşzamanlı indirme sınırı: fazlası 429 +
// Retry-After alır, APK baytı/başlığı almaz; biten ya da reddedilen istek
// slot sızdırmaz.
func TestAppDownload_ConcurrencyLimit(t *testing.T) {
	dir := t.TempDir()
	apk := writeTestAppRelease(t, dir, 3, "")
	h := newTestAppReleaseHandler(dir)
	h.userKey = func(r *http.Request) string { return r.Header.Get("X-Test-User") }
	h.limiter = newDownloadLimiter(2, 3)

	download := func(user string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/mobile/app-download?platform=android", nil)
		req.Header.Set("X-Test-User", user)
		rec := httptest.NewRecorder()
		h.Download(rec, req)
		return rec
	}
	assertRejected := func(name string, rec *httptest.ResponseRecorder) {
		t.Helper()
		if rec.Code != http.StatusTooManyRequests {
			t.Fatalf("%s: status = %d, want 429", name, rec.Code)
		}
		if ra := rec.Header().Get("Retry-After"); ra != appDownloadRetryAfter {
			t.Fatalf("%s: Retry-After = %q, want %q", name, ra, appDownloadRetryAfter)
		}
		if rec.Header().Get("Content-Type") == "application/vnd.android.package-archive" || rec.Header().Get("ETag") != "" {
			t.Fatalf("%s: reddedilen istekte APK başlıkları var", name)
		}
		if body := decodeJSONMap(t, rec); body["error"] == nil || len(body) != 1 {
			t.Fatalf("%s: gövde = %v, want yalnızca {error}", name, body)
		}
	}
	assertServed := func(name string, rec *httptest.ResponseRecorder) {
		t.Helper()
		if rec.Code != http.StatusOK || !reflect.DeepEqual(rec.Body.Bytes(), apk) {
			t.Fatalf("%s: status = %d, %d bayt; want 200 ve tüm dosya", name, rec.Code, rec.Body.Len())
		}
	}

	// u1'in iki indirmesi sürüyor: üçüncüsü reddedilir.
	h.limiter.acquire("u1")
	h.limiter.acquire("u1")
	assertRejected("u1 üçüncü indirme", download("u1"))

	// Başka bir kullanıcı etkilenmez; biten indirme slotunu geri verir.
	assertServed("u2", download("u2"))
	if n := h.limiter.inFlight(); n != 2 {
		t.Fatalf("inFlight = %d, want 2 (biten indirme slotu geri vermeli, reddedilen hiç almamalı)", n)
	}

	// Toplam sınır: 3 indirme sürerken kimse başlayamaz.
	h.limiter.acquire("u3")
	assertRejected("toplam sınır", download("u4"))
	h.limiter.release("u1")
	assertServed("slot boşalınca u4", download("u4"))
	h.limiter.release("u1")
	assertServed("u1 yeniden", download("u1"))
	h.limiter.release("u3")
	if n := h.limiter.inFlight(); n != 0 {
		t.Fatalf("inFlight = %d, want 0", n)
	}

	// Yayın yokken (404) ve bilinmeyen platformda (400) slot alınmaz.
	empty := newTestAppReleaseHandler(filepath.Join(t.TempDir(), "yok"))
	rec := httptest.NewRecorder()
	empty.Download(rec, httptest.NewRequest(http.MethodGet, "/api/v1/mobile/app-download?platform=android", nil))
	if rec.Code != http.StatusNotFound || empty.limiter.inFlight() != 0 {
		t.Fatalf("404: status = %d, inFlight = %d", rec.Code, empty.limiter.inFlight())
	}
	rec = httptest.NewRecorder()
	h.Download(rec, httptest.NewRequest(http.MethodGet, "/api/v1/mobile/app-download?platform=ios", nil))
	if rec.Code != http.StatusBadRequest || h.limiter.inFlight() != 0 {
		t.Fatalf("400: status = %d, inFlight = %d", rec.Code, h.limiter.inFlight())
	}
}
