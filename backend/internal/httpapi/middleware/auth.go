// Package middleware, kimlik doğrulama ve rol kontrolü ara katmanlarını
// içerir.
package middleware

import (
	"context"
	"net/http"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

type ctxKey int

const (
	ctxUserID ctxKey = iota
	ctxRole
	ctxOrganizationID
)

// RequireAuth, "access_token" cookie'sindeki JWT'yi doğrular; geçerliyse
// kullanıcı kimliği ve rolünü context'e ekler. Yalnızca imza/süre kontrolü
// yapar -- kullanıcı deaktive edilmişse bu, en geç bir sonraki refresh
// denemesinde (AuthService.Refresh, is_active kontrolü yapar) düşer; 15
// dakikalık access token ömrü bu gecikmeyi kabul edilebilir kılıyor.
func RequireAuth(issuer *auth.JWTIssuer) func(http.Handler) http.Handler {
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
