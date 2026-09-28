package handler

import (
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// AppReleaseHandler, uzaktan güncellemenin (Store öncesi Android) iki ucu:
//
//	GET /mobile/app-version?platform=android  -- PUBLIC, giriş ekranından
//	    da sorulur. Yalnızca sürüm/build/özet/boyut/notlar döner; diskteki
//	    başka hiçbir alan (yol, dosya adı) istemciye taşınmaz.
//	GET /mobile/app-download?platform=android -- requireAuth+requireTenant:
//	    APK binary'si yalnızca oturum açmış bir firma kullanıcısına iner
//	    (ek izin yok; her firma kullanıcısı güncelleyebilmeli).
//
// Güvenlik modelinin tamamı için bkz. service/app_release_service.go.
type AppReleaseHandler struct {
	svc *service.AppReleaseService
	// userKey, eşzamanlı indirme sınırının anahtarı: requireAuth'un
	// bağlama koyduğu kullanıcı kimliği (testlerde değiştirilir).
	userKey     func(*http.Request) string
	limiter     *downloadLimiter
	idleTimeout time.Duration
	maxDuration time.Duration
}

func NewAppReleaseHandler(svc *service.AppReleaseService) *AppReleaseHandler {
	return &AppReleaseHandler{
		svc:         svc,
		userKey:     appDownloadUserKey,
		limiter:     newDownloadLimiter(appDownloadMaxPerUser, appDownloadMaxTotal),
		idleTimeout: appDownloadIdleTimeout,
		maxDuration: appDownloadMaxDuration,
	}
}

// İndirme ucunun kaynak sınırları. Yanıt bilinçli olarak önbelleğe
// alınamaz (private, no-store), yani her indirme ~60 MB'ı sunucunun kendi
// hattından çeker; yazma süresi de genel WriteTimeout'tan uzundur. Bu
// yüzden:
//   - Sunucunun genel WriteTimeout'u (5 dk) ~60 MB'lık APK'yı yavaş bir
//     mobil hatta yarıda keserdi; bu yanıtta süre İLERLEMEYE bağlanır: her
//     başarılı yazmadan sonra appDownloadIdleTimeout kadar ertelenir, toplamda
//     appDownloadMaxDuration'ı geçemez. Okumayı bırakan (ya da sıfır TCP
//     penceresi ilan eden) bir istemci, bağlantıyı/dosya tanıtıcısını bir
//     saat değil en fazla birkaç dakika tutar.
//   - Aynı anda kullanıcı başına appDownloadMaxPerUser, toplamda
//     appDownloadMaxTotal indirme akar; fazlası 429 + Retry-After alır. Tek
//     bir hesap (düşük yetkili bir Saha kullanıcısı ya da çalınmış bir
//     oturum) paralel isteklerle sunucunun çıkış hattını dolduramaz.
//
// Sunucu Range/If-Range'i destekler (http.ServeContent); bugünkü istemci
// ise kesintide indirmeye baştan başlar (lib/core/update/update_service.dart).
const (
	appDownloadIdleTimeout = 2 * time.Minute
	appDownloadMaxDuration = time.Hour
	// 3: istemci başlıklarda ETag'i reddedip hemen yeniden isteyebilir,
	// kullanıcı "Tekrar Dene"ye basabilir -- eski bağlantı sunucuda henüz
	// kapanmamışken kısa bir çakışma meşrudur.
	appDownloadMaxPerUser = 3
	appDownloadMaxTotal   = 20
	appDownloadRetryAfter = "30"
)

func appDownloadUserKey(r *http.Request) string {
	id, _ := middleware.UserIDFromContext(r.Context())
	return id
}

// downloadLimiter, eşzamanlı APK indirmelerini kullanıcı başına ve toplamda
// sınırlar. Bekletmez: sınır doluysa istek hemen reddedilir.
type downloadLimiter struct {
	maxPerUser int
	maxTotal   int

	mu      sync.Mutex
	total   int
	perUser map[string]int
}

func newDownloadLimiter(maxPerUser, maxTotal int) *downloadLimiter {
	return &downloadLimiter{maxPerUser: maxPerUser, maxTotal: maxTotal, perUser: map[string]int{}}
}

func (l *downloadLimiter) acquire(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.total >= l.maxTotal || l.perUser[key] >= l.maxPerUser {
		return false
	}
	l.total++
	l.perUser[key]++
	return true
}

func (l *downloadLimiter) release(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.total--
	if n := l.perUser[key] - 1; n > 0 {
		l.perUser[key] = n
	} else {
		delete(l.perUser, key)
	}
}

func (l *downloadLimiter) inFlight() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.total
}

// progressDeadlineWriter, yazma son tarihini ilerlemeye bağlar: her
// başarılı Write'tan sonra son tarih now+idle'a ertelenir, ama hardStop'u
// asla geçmez. Ertelemek her yazmada değil, en fazla idle/4'te bir yapılır
// (gerçek son tarih son ilerlemeden en az idle*3/4 sonradır).
//
// Bilinçli olarak io.ReaderFrom SAĞLAMAZ: ServeContent'in io.Copy'si böylece
// dosyayı tek bir sendfile çağrısıyla değil 32 KB'lık Write'larla gönderir
// ve her parça ilerleme sayılır. Unwrap, ResponseController'ın asıl
// bağlantıya ulaşması içindir.
type progressDeadlineWriter struct {
	http.ResponseWriter
	setDeadline func(time.Time) error
	now         func() time.Time
	idle        time.Duration
	hardStop    time.Time
	armedAt     time.Time
}

func newProgressDeadlineWriter(w http.ResponseWriter, setDeadline func(time.Time) error, now func() time.Time, idle, max time.Duration) *progressDeadlineWriter {
	start := now()
	p := &progressDeadlineWriter{ResponseWriter: w, setDeadline: setDeadline, now: now, idle: idle, hardStop: start.Add(max)}
	p.arm(start)
	return p
}

func (p *progressDeadlineWriter) Write(b []byte) (int, error) {
	n, err := p.ResponseWriter.Write(b)
	if n > 0 {
		if t := p.now(); t.Sub(p.armedAt) >= p.idle/4 {
			p.arm(t)
		}
	}
	return n, err
}

func (p *progressDeadlineWriter) arm(t time.Time) {
	deadline := t.Add(p.idle)
	if deadline.After(p.hardStop) {
		deadline = p.hardStop
	}
	// Desteklenmeyen yazıcıda (httptest.ResponseRecorder) sessizce geçer;
	// o zaman sunucunun genel WriteTimeout'u geçerli kalır.
	_ = p.setDeadline(deadline)
	p.armedAt = t
}

func (p *progressDeadlineWriter) Unwrap() http.ResponseWriter { return p.ResponseWriter }

type appVersionResponse struct {
	Platform    string `json:"platform"`
	Build       int    `json:"build"`
	Version     string `json:"version"`
	SHA256      string `json:"sha256"`
	Size        int64  `json:"size"`
	Notes       string `json:"notes"`
	MinBuild    int    `json:"min_build"`
	PublishedAt string `json:"published_at"`
}

// noAppVersionResponse: geçerli yayın yokken yalnızca build=0 -- istemci
// hiçbir zaman güncelleme önermez.
type noAppVersionResponse struct {
	Platform string `json:"platform"`
	Build    int    `json:"build"`
}

func (h *AppReleaseHandler) Version(w http.ResponseWriter, r *http.Request) {
	// Sürüm yanıtı hiçbir ara katmanda (Cloudflare, Caddy, cihaz)
	// önbelleğe alınmamalı: yeni yayın bir sonraki sorguda görünmeli.
	w.Header().Set("Cache-Control", "no-store")
	platform := r.URL.Query().Get("platform")
	rel, err := h.svc.Latest(platform)
	switch {
	case errors.Is(err, service.ErrUnknownAppPlatform):
		httpjson.Error(w, http.StatusBadRequest, "bilinmeyen platform")
		return
	case err != nil:
		httpjson.Write(w, http.StatusOK, noAppVersionResponse{Platform: platform, Build: 0})
		return
	}
	httpjson.Write(w, http.StatusOK, appVersionResponse{
		Platform:    rel.Platform,
		Build:       rel.Build,
		Version:     rel.Version,
		SHA256:      rel.SHA256,
		Size:        rel.Size,
		Notes:       rel.Notes,
		MinBuild:    rel.MinBuild,
		PublishedAt: rel.PublishedAt.Format(time.RFC3339),
	})
}

// Download, güncel APK'yı akıtır. http.ServeContent: sunucu Range/If-Range'i
// destekler (ETag = özet; arada yeni sürüm çıktıysa baytlar karışmaz, dosya
// baştan gelir), dosya belleğe alınmaz, doğrudan diskten akar.
func (h *AppReleaseHandler) Download(w http.ResponseWriter, r *http.Request) {
	rel, f, err := h.svc.Open(r.URL.Query().Get("platform"))
	switch {
	case errors.Is(err, service.ErrUnknownAppPlatform):
		httpjson.Error(w, http.StatusBadRequest, "bilinmeyen platform")
		return
	case err != nil:
		httpjson.Error(w, http.StatusNotFound, "yayınlanmış bir uygulama sürümü yok")
		return
	}
	defer f.Close()

	key := h.userKey(r)
	if !h.limiter.acquire(key) {
		w.Header().Set("Retry-After", appDownloadRetryAfter)
		httpjson.Error(w, http.StatusTooManyRequests, "şu anda çok fazla güncelleme indiriliyor, biraz sonra tekrar deneyin")
		return
	}
	defer h.limiter.release(key)

	// chi'nin Logger sarmalayıcısı Unwrap sağladığı için ResponseController
	// asıl bağlantıya ulaşır.
	w = newProgressDeadlineWriter(w, http.NewResponseController(w).SetWriteDeadline, time.Now, h.idleTimeout, h.maxDuration)

	hdr := w.Header()
	hdr.Set("Content-Type", "application/vnd.android.package-archive")
	hdr.Set("X-Content-Type-Options", "nosniff")
	// rel.Version x.y.z desenine uyar -- başlığa enjekte edilecek karakter
	// taşıyamaz.
	hdr.Set("Content-Disposition", fmt.Sprintf(`attachment; filename="ARVEND-%s.apk"`, rel.Version))
	hdr.Set("ETag", `"`+rel.SHA256+`"`)
	// Oturuma bağlı binary: hiçbir paylaşılan önbellek (Cloudflare kenarı
	// dahil) saklayıp oturumsuz birine sunmamalı. Bu yüzden URL de ".apk"
	// ile BİTMEZ -- Cloudflare .apk uzantısını varsayılan olarak önbelleğe
	// alır.
	hdr.Set("Cache-Control", "private, no-store")
	http.ServeContent(w, r, rel.File, rel.ModTime, f)
}
