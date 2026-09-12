package middleware

import (
	"net/http"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

// RequireRole, RequireAuth'tan SONRA zincirlenmeli. Buradaki kontrol asıl
// güvenlik sınırıdır -- frontend'deki route guard'ları yalnız UX içindir.
func RequireRole(role domain.Role) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			got, ok := RoleFromContext(r.Context())
			if !ok || got != role {
				http.Error(w, `{"error":"bu işlem için yetkiniz yok"}`, http.StatusForbidden)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
