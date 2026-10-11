package middleware_test

// Geçici veritabanı hatası (Postgres yeniden başlıyor, bağlantı koptu)
// oturumu düşüren 401/403 sınıflarına girmemeli: eskiden firma durumu
// okunamayınca 403 "firma askıya alınmış" dönüyor, mobil bunu hesap engeli
// sayıp bütün ekibi oturumdan atıyordu (hesap-yetki-b3). Gerçek veritabanı
// gerekmez: sorgular sahte bir DBTX'ten cevap alır.

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	appmw "github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// adminShutdown: Postgres yeniden başlarken açık bağlantılara gönderdiği hata.
var adminShutdown = &pgconn.PgError{Code: "57P01", Message: "terminating connection due to administrator command"}

// scriptedDB, sorguyu sqlc adına göre ("-- name: X") cevaplar; listede
// olmayan her sorgu varsayılan hatayı alır.
type scriptedDB struct {
	rows       map[string]pgx.Row
	defaultErr error
}

func (d scriptedDB) row(sql string) pgx.Row {
	for name, row := range d.rows {
		if strings.Contains(sql, "-- name: "+name+" ") {
			return row
		}
	}
	return errRow{d.defaultErr}
}

func (d scriptedDB) Exec(context.Context, string, ...interface{}) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, d.defaultErr
}

func (d scriptedDB) Query(context.Context, string, ...interface{}) (pgx.Rows, error) {
	return nil, d.defaultErr
}

func (d scriptedDB) QueryRow(_ context.Context, sql string, _ ...interface{}) pgx.Row {
	return d.row(sql)
}

type errRow struct{ err error }

func (r errRow) Scan(...any) error { return r.err }

// activeOrgRow: GetOrganizationStatus -> status "active", silinmemiş.
type activeOrgRow struct{}

func (activeOrgRow) Scan(dest ...any) error {
	*dest[0].(*string) = string(domain.OrgStatusActive)
	return nil
}

const (
	testUserID = "0b4f7b9e-2c1a-4f0e-9d3b-1a2b3c4d5e6f"
	testOrgID  = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
)

func serve(t *testing.T, h http.Handler, token string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.AddCookie(&http.Cookie{Name: "access_token", Value: token})
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func expectTemporarilyUnavailable(t *testing.T, rec *httptest.ResponseRecorder) {
	t.Helper()
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("durum %d, beklenen 503 (gövde: %s)", rec.Code, rec.Body.String())
	}
	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("gövde JSON değil: %v (%s)", err, rec.Body.String())
	}
	if body["code"] != "temporarily_unavailable" {
		t.Errorf("code %q, beklenen temporarily_unavailable", body["code"])
	}
	// Mobil bu iki sabit mesajı hesap engeli sayar -- 503'te asla görünmemeli.
	if strings.Contains(body["error"], "askıya alınmış") || strings.Contains(body["error"], "oturum geçersiz") {
		t.Errorf("503 gövdesi oturum/firma engeli gibi okunuyor: %q", body["error"])
	}
	if rec.Header().Get("Retry-After") == "" {
		t.Error("Retry-After başlığı yok")
	}
}

func okHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
}

func TestRequireAuth_TransientDBErrorIs503NotSuspended(t *testing.T) {
	issuer := auth.NewJWTIssuer("transient-db-secret", time.Minute)
	token, err := issuer.IssueAccessToken(testUserID, domain.RoleAdmin, testOrgID)
	if err != nil {
		t.Fatal(err)
	}

	t.Run("firma durumu okunamadı -> 503", func(t *testing.T) {
		q := sqlc.New(scriptedDB{defaultErr: adminShutdown})
		expectTemporarilyUnavailable(t, serve(t, appmw.RequireAuth(issuer, q)(okHandler()), token))
	})

	t.Run("firma kaydı yok -> 403 (kesin cevap, oturum biter)", func(t *testing.T) {
		q := sqlc.New(scriptedDB{defaultErr: pgx.ErrNoRows})
		rec := serve(t, appmw.RequireAuth(issuer, q)(okHandler()), token)
		if rec.Code != http.StatusForbidden || !strings.Contains(rec.Body.String(), "firma askıya alınmış veya erişilemiyor") {
			t.Fatalf("durum %d gövde %s, beklenen 403 askıya alınmış", rec.Code, rec.Body.String())
		}
	})
}

func TestUserGates_TransientDBErrorIs503NotUnauthorized(t *testing.T) {
	issuer := auth.NewJWTIssuer("transient-db-secret", time.Minute)
	token, err := issuer.IssueAccessToken(testUserID, domain.RoleAdmin, testOrgID)
	if err != nil {
		t.Fatal(err)
	}
	gates := map[string]func(*sqlc.Queries) func(http.Handler) http.Handler{
		"RequireActiveUser": appmw.RequireActiveUser,
		"RequireOnboarded":  appmw.RequireOnboarded,
	}
	for name, gate := range gates {
		t.Run(name+": kullanıcı satırı okunamadı -> 503", func(t *testing.T) {
			// Firma durumu okunur (aktif), kullanıcı satırı okunamaz.
			q := sqlc.New(scriptedDB{rows: map[string]pgx.Row{"GetOrganizationStatus": activeOrgRow{}}, defaultErr: adminShutdown})
			expectTemporarilyUnavailable(t, serve(t, appmw.RequireAuth(issuer, q)(gate(q)(okHandler())), token))
		})
		t.Run(name+": kullanıcı satırı yok -> 401", func(t *testing.T) {
			q := sqlc.New(scriptedDB{rows: map[string]pgx.Row{"GetOrganizationStatus": activeOrgRow{}}, defaultErr: pgx.ErrNoRows})
			rec := serve(t, appmw.RequireAuth(issuer, q)(gate(q)(okHandler())), token)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("durum %d, beklenen 401 (gövde: %s)", rec.Code, rec.Body.String())
			}
		})
	}
}
