// Package middleware, kimlik doğrulama ve rol kontrolü ara katmanlarını
// içerir.
package middleware

import (
	"context"
	"errors"
	"log"
	"net/http"

	"github.com/jackc/pgx/v5"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

type ctxKey int

const (
	ctxUserID ctxKey = iota
	ctxRole
	ctxOrganizationID
)

// RequireAuth, "access_token" cookie'sindeki JWT'yi doğrular; geçerliyse
// kullanıcı kimliği ve rolünü context'e ekler. İmza/süre kontrolünün ötesinde,
// organization_id'si dolu olan (Super Admin olmayan) her istekte firmanın
// status'unü de kontrol eder -- bu, AuthService.Login/Refresh'teki aynı
// kontrolden FARKLI bir güvenlik sınırıdır: bir firma askıya alındığında,
// halihazırda geçerli (süresi dolmamış) bir access token'la gelen mid-session
// istekleri de reddetmek için (spec: "existing active sessions ile suspended
// tenant'ın erişmeye devam etmesine izin verme"). Kullanıcının kendi
// durumu (is_active, silinme, GÜNCEL kaba rol) burada DEĞİL, users satırını
// zaten okuyan RequireOnboarded'da ve onu almayan tenant rotalarında
// RequireActiveUser'da kontrol edilir (bkz. applyUserGate) -- pasifleştirilen
// ya da rolü düşürülen biri token'ın 15 dakikalık ömrünü beklemeden düşer.
// Context'e konan rol token'dakidir; o iki middleware onu veritabanındaki
// rolle değiştirir.
func RequireAuth(issuer *auth.JWTIssuer, q *sqlc.Queries) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			cookie, err := r.Cookie("access_token")
			if err != nil {
				http.Error(w, `{"error":"oturum bulunamadı"}`, http.StatusUnauthorized)
				return
			}
			claims, err := issuer.ParseAccessToken(cookie.Value)
			if err != nil {
				http.Error(w, `{"error":"oturum geçersiz veya süresi dolmuş"}`, http.StatusUnauthorized)
				return
			}
			if claims.OrganizationID != "" {
				orgUUID, err := repository.StringToUUID(claims.OrganizationID)
				if err != nil {
					http.Error(w, `{"error":"oturum geçersiz veya süresi dolmuş"}`, http.StatusUnauthorized)
					return
				}
				state, err := q.GetOrganizationStatus(r.Context(), orgUUID)
				if isTransientDBError(err) {
					// Firmanın durumu OKUNAMADI -- askıya alındığı anlamına
					// gelmez. 403 "askıya alınmış" dönülseydi istemciler
					// oturumu kapatıp "firmanızın erişimi kapalı" ekranını
					// açardı (veritabanı kısa bir an koptuğunda bütün ekip).
					writeTemporarilyUnavailable(w, "firma durumu okunamadı", err)
					return
				}
				// Silme, status'ten BAĞIMSIZ bir erişim engelidir (bkz.
				// migration 0043 başlık notu) -- AllowsAccess() true olsa
				// bile deleted_at doluysa istek reddedilir.
				if err != nil || !domain.OrgStatus(state.Status).AllowsAccess() || state.DeletedAt.Valid {
					http.Error(w, `{"error":"firma askıya alınmış veya erişilemiyor"}`, http.StatusForbidden)
					return
				}
			}
			ctx := context.WithValue(r.Context(), ctxUserID, claims.UserID)
			ctx = context.WithValue(ctx, ctxRole, claims.Role)
			ctx = context.WithValue(ctx, ctxOrganizationID, claims.OrganizationID)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

func UserIDFromContext(ctx context.Context) (string, bool) {
	v, ok := ctx.Value(ctxUserID).(string)
	return v, ok
}

func RoleFromContext(ctx context.Context) (domain.Role, bool) {
	v, ok := ctx.Value(ctxRole).(domain.Role)
	return v, ok
}

func OrganizationIDFromContext(ctx context.Context) (string, bool) {
	v, ok := ctx.Value(ctxOrganizationID).(string)
	return v, ok
}

// isTransientDBError: sorgu sonuç vermek yerine HATA verdi (bağlantı koptu,
// zaman aşımı, Postgres yeniden başlıyor). pgx.ErrNoRows bir sonuçtur
// (kayıt yok) ve kendi kesin cevabını alır; nil de geçici değildir.
func isTransientDBError(err error) bool {
	return err != nil && !errors.Is(err, pgx.ErrNoRows)
}

// writeTemporarilyUnavailable: geçici veritabanı hatasında 503 -- oturum
// düşürülmez (bkz. httpjson.TemporarilyUnavailable). İstemci bağlantıyı
// kendisi kestiyse (context.Canceled) log kirletilmez.
func writeTemporarilyUnavailable(w http.ResponseWriter, what string, err error) {
	if !errors.Is(err, context.Canceled) {
		log.Printf("UYARI: oturum denetimi: %s: %v -- 503 dönüldü", what, err)
	}
	httpjson.TemporarilyUnavailable(w)
}
