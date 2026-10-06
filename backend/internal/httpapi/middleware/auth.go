// Package middleware, kimlik doğrulama ve rol kontrolü ara katmanlarını
// içerir.
package middleware

import (
	"context"
	"net/http"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
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
