package middleware_test

// GET /api/v1/mobile/app-download -- GERÇEK router + GERÇEK PostgreSQL.
// Güvenlik modelinin 1. katmanı: APK yalnızca oturum açmış bir FİRMA
// kullanıcısına iner. Ek izin yok (Saha rolü de indirebilmeli), ama
// askıya alınmış firmanın hâlâ geçerli token'ı reddedilir (RequireAuth'un
// her istekteki firma durumu kontrolü). Router'ı main.go'daki middleware
// zinciriyle (chi Logger sarmalayıcısı dahil) kurar; yalnızca bu uçların
// kullandığı bağımlılıklar verilir.

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/handler"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestAppDownloadSecurity(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "app-release-sec-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	orgID := org.Organization.ID

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatal(err)
	}
	_, fieldToken := mustCreateRoleUser(t, ctx, d, orgID, "app_release_saha", "field")

	dir := t.TempDir()
	apk := bytes.Repeat([]byte("ARVEND-APK-"), 50_000)
	sum := sha256.Sum256(apk)
	android := filepath.Join(dir, "android")
	if err := os.MkdirAll(android, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(android, "arvend-7.apk"), apk, 0o644); err != nil {
		t.Fatal(err)
	}
	manifest, _ := json.Marshal(map[string]any{
		"build": 7, "version": "1.3.0", "sha256": hex.EncodeToString(sum[:]), "size": len(apk),
		"notes": "test", "min_build": 0, "file": "arvend-7.apk", "published_at": "2026-09-28T10:00:00Z",
	})
	if err := os.WriteFile(filepath.Join(android, "latest.json"), manifest, 0o644); err != nil {
		t.Fatal(err)
	}
	router := httpapi.NewRouter(httpapi.Deps{
		JWT:         d.issuer,
		Queries:     d.q,
		AppReleases: handler.NewAppReleaseHandler(service.NewAppReleaseService(dir)),
	})

	download := func(token, rangeHdr string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/mobile/app-download?platform=android", nil)
		if token != "" {
			req.AddCookie(&http.Cookie{Name: "access_token", Value: token})
		}
		if rangeHdr != "" {
			req.Header.Set("Range", rangeHdr)
		}
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)
		return rec
	}

	for name, token := range map[string]string{"owner": ownerToken, "saha (ek izin yok)": fieldToken} {
		rec := download(token, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: status = %d, want 200 (%s)", name, rec.Code, rec.Body.String())
		}
		if !bytes.Equal(rec.Body.Bytes(), apk) {
			t.Fatalf("%s: akıtılan baytlar farklı (%d bayt, want %d)", name, rec.Body.Len(), len(apk))
		}
		if et := rec.Header().Get("ETag"); et != `"`+hex.EncodeToString(sum[:])+`"` {
			t.Fatalf("%s: ETag = %q", name, et)
		}
	}

	rec := download(fieldToken, "bytes=100-")
	if rec.Code != http.StatusPartialContent || !bytes.Equal(rec.Body.Bytes(), apk[100:]) {
		t.Fatalf("Range: status = %d, %d bayt; want 206 ve dosyanın 100. baytından sonrası", rec.Code, rec.Body.Len())
	}
	if cr, want := rec.Header().Get("Content-Range"), fmt.Sprintf("bytes 100-%d/%d", len(apk)-1, len(apk)); cr != want {
		t.Fatalf("Content-Range = %q, want %q", cr, want)
	}

	if rec := download("", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("oturumsuz: status = %d, want 401", rec.Code)
	}

	// Askıya alınan firmanın süresi dolmamış token'ı da indiremez.
	if _, err := d.pool.Exec(ctx, "UPDATE organizations SET status = $2 WHERE id = $1", orgID, string(domain.OrgStatusSuspended)); err != nil {
		t.Fatal(err)
	}
	for name, token := range map[string]string{"owner": ownerToken, "saha": fieldToken} {
		rec := download(token, "")
		if rec.Code != http.StatusForbidden {
			t.Fatalf("askıdaki firma %s: status = %d, want 403", name, rec.Code)
		}
		if rec.Body.Len() > 200 {
			t.Fatalf("askıdaki firma %s: reddedilen yanıtta %d bayt", name, rec.Body.Len())
		}
	}

	// Sürüm sorgusu firma durumundan bağımsız, oturumsuz çalışır.
	req := httptest.NewRequest(http.MethodGet, "/api/v1/mobile/app-version?platform=android", nil)
	rec = httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil || rec.Code != http.StatusOK || body["build"] != float64(7) {
		t.Fatalf("app-version: status = %d, gövde = %s", rec.Code, rec.Body.String())
	}
}
