package httpapi

// Uzaktan güncelleme -- router kablolaması (veritabanı gerektirmez):
// sürüm sorgusu oturumsuz çalışır, APK indirme oturumsuz 401, platform
// hesabıyla (super_admin, firma bağlamı yok) 403 döner. Firma kullanıcısıyla
// uçtan uca indirme gerçek PostgreSQL ister: middleware/
// app_release_security_test.go.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/handler"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func newAppReleaseTestRouter(t *testing.T) (http.Handler, *auth.JWTIssuer) {
	t.Helper()
	dir := t.TempDir()
	apk := []byte("sahte apk içeriği -- yalnızca router testi için")
	sum := sha256.Sum256(apk)
	android := filepath.Join(dir, "android")
	if err := os.MkdirAll(android, 0o755); err != nil {
		t.Fatal(err)
	}
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
	issuer := auth.NewJWTIssuer("router-app-release-test", 15*time.Minute)
	return NewRouter(Deps{
		JWT:         issuer,
		AppReleases: handler.NewAppReleaseHandler(service.NewAppReleaseService(dir)),
	}), issuer
}

func TestAppVersionRoute_PublicWithoutSession(t *testing.T) {
	router, _ := newAppReleaseTestRouter(t)

	for _, cookie := range []*http.Cookie{nil, {Name: "access_token", Value: "gecersiz"}} {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/mobile/app-version?platform=android", nil)
		if cookie != nil {
			req.AddCookie(cookie)
		}
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("cookie=%v: status = %d, want 200 (giriş ekranından da sorulur)", cookie, rec.Code)
		}
		var body map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil || body["build"] != float64(3) {
			t.Fatalf("cookie=%v: gövde = %s", cookie, rec.Body.String())
		}
	}

	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/mobile/app-version?platform=ios", nil))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("platform=ios: status = %d, want 400", rec.Code)
	}
}

func TestAppDownloadRoute_RequiresTenantSession(t *testing.T) {
	router, issuer := newAppReleaseTestRouter(t)

	superToken, err := issuer.IssueAccessToken("00000000-0000-0000-0000-00000000aaaa", domain.RoleSuperAdmin, "")
	if err != nil {
		t.Fatal(err)
	}
	// org claim'i boş gelen kiracı rolü de (bozuk/eski token) reddedilir.
	orglessToken, err := issuer.IssueAccessToken("00000000-0000-0000-0000-00000000bbbb", domain.RoleAdmin, "")
	if err != nil {
		t.Fatal(err)
	}
	foreignToken, err := auth.NewJWTIssuer("baska-bir-anahtar", time.Minute).
		IssueAccessToken("00000000-0000-0000-0000-00000000cccc", domain.RoleAdmin, "00000000-0000-0000-0000-00000000dddd")
	if err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name  string
		token string
		want  int
	}{
		{"oturum yok", "", http.StatusUnauthorized},
		{"geçersiz token", "gecersiz", http.StatusUnauthorized},
		{"başka anahtarla imzalı token", foreignToken, http.StatusUnauthorized},
		{"super_admin", superToken, http.StatusForbidden},
		{"firma bağlamı yok", orglessToken, http.StatusForbidden},
	}
	for _, tc := range cases {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/mobile/app-download?platform=android", nil)
		if tc.token != "" {
			req.AddCookie(&http.Cookie{Name: "access_token", Value: tc.token})
		}
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)
		if rec.Code != tc.want {
			t.Errorf("%s: status = %d, want %d", tc.name, rec.Code, tc.want)
		}
		if ct := rec.Header().Get("Content-Type"); ct == "application/vnd.android.package-archive" || rec.Header().Get("ETag") != "" {
			t.Errorf("%s: reddedilen istekte APK başlıkları var", tc.name)
		}
		if len(rec.Body.Bytes()) > 200 {
			t.Errorf("%s: reddedilen istekte %d baytlık gövde (APK sızmış olabilir)", tc.name, rec.Body.Len())
		}
	}
}
