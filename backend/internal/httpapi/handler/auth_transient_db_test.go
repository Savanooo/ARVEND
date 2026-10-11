package handler

// /auth/refresh ve /auth/me, veritabanı o an okunamadığında oturumu
// BİTİRMEMELİ (hesap-yetki-b3): eskiden Refresh, token döndürüldükten sonra
// kullanıcı satırı okunamayınca "geçersiz token" deyip çerezleri siliyordu;
// Me de her hatada 401 dönüyor, web kullanıcıyı /giris'e atıyordu.

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

var pgAdminShutdown = &pgconn.PgError{Code: "57P01", Message: "terminating connection due to administrator command"}

// authFakeDB: RotateRefreshToken başarılı (token döndürüldü), geri kalan her
// sorgu userErr ile düşer.
type authFakeDB struct{ userErr error }

func (d authFakeDB) Exec(context.Context, string, ...interface{}) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, d.userErr
}

func (d authFakeDB) Query(context.Context, string, ...interface{}) (pgx.Rows, error) {
	return nil, d.userErr
}

func (d authFakeDB) QueryRow(_ context.Context, sql string, _ ...interface{}) pgx.Row {
	if strings.Contains(sql, "-- name: RotateRefreshToken ") {
		return fakeRow{}
	}
	return fakeRow{err: d.userErr}
}

type fakeRow struct{ err error }

func (r fakeRow) Scan(...any) error { return r.err }

func newTestAuthHandler(db sqlc.DBTX) (*AuthHandler, *auth.JWTIssuer) {
	issuer := auth.NewJWTIssuer("transient-db-secret", time.Minute)
	svc := service.NewAuthService(sqlc.New(db), issuer, time.Hour)
	return NewAuthHandler(svc, nil, time.Minute, time.Hour, "", false), issuer
}

func TestAuthRefresh_TransientDBErrorKeepsCookies(t *testing.T) {
	refresh := func(userErr error) *httptest.ResponseRecorder {
		h, _ := newTestAuthHandler(authFakeDB{userErr: userErr})
		req := httptest.NewRequest(http.MethodPost, "/auth/refresh", nil)
		req.AddCookie(&http.Cookie{Name: "refresh_token", Value: "eski-refresh-token"})
		rec := httptest.NewRecorder()
		h.Refresh(rec, req)
		return rec
	}

	rec := refresh(pgAdminShutdown)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("geçici hata: durum %d, beklenen 503 (gövde: %s)", rec.Code, rec.Body.String())
	}
	if c := rec.Result().Cookies(); len(c) != 0 {
		t.Fatalf("geçici hatada çerezler silinmemeli, Set-Cookie: %v", c)
	}

	rec = refresh(pgx.ErrNoRows)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("kullanıcı yok: durum %d, beklenen 401", rec.Code)
	}
	if len(rec.Result().Cookies()) == 0 {
		t.Fatal("kullanıcı yoksa oturum biter: çerezler silinmeli")
	}
}

func TestAuthMe_TransientDBErrorIs503(t *testing.T) {
	me := func(userErr error) *httptest.ResponseRecorder {
		h, issuer := newTestAuthHandler(authFakeDB{userErr: userErr})
		// Firmasız token: RequireAuth veritabanına sormadan geçer, hata
		// yalnızca Me'nin kendi sorgusundan gelir.
		token, err := issuer.IssueAccessToken("0b4f7b9e-2c1a-4f0e-9d3b-1a2b3c4d5e6f", domain.RoleAdmin, "")
		if err != nil {
			t.Fatal(err)
		}
		req := httptest.NewRequest(http.MethodGet, "/auth/me", nil)
		req.AddCookie(&http.Cookie{Name: "access_token", Value: token})
		rec := httptest.NewRecorder()
		middleware.RequireAuth(issuer, sqlc.New(authFakeDB{userErr: userErr}))(http.HandlerFunc(h.Me)).ServeHTTP(rec, req)
		return rec
	}

	if rec := me(pgAdminShutdown); rec.Code != http.StatusServiceUnavailable ||
		!strings.Contains(rec.Body.String(), "temporarily_unavailable") {
		t.Fatalf("geçici hata: durum %d gövde %s, beklenen 503 temporarily_unavailable", rec.Code, rec.Body.String())
	}
	if rec := me(pgx.ErrNoRows); rec.Code != http.StatusUnauthorized {
		t.Fatalf("kullanıcı yok: durum %d, beklenen 401", rec.Code)
	}
}
