package middleware

import (
	"context"
	"net/http"
)

// Taşeron Paneli (migration 0075, docs/taseron-paneli.md). Taşeron hesabı
// oturum kapısında (applyUserGate) varsayılan olarak reddedilir; yalnızca
// AllowPortalUsers'ın işaretlediği uçlara geçer.

const (
	ctxPortalAllowed ctxKey = iota + 200 // require_permission.go 100 tabanını kullanıyor.
	ctxSupplierID
)

const errPortalOnlyBody = `{"error":"taşeron hesabı bu bölüme erişemez","code":"portal_only"}`

// AllowPortalUsers, taşeron hesabının da girebileceği uçları işaretler.
// Oturum kapısından (RequireOnboarded / RequireActiveUser) ÖNCE
// zincirlenmeli. Firma kullanıcıları için hiçbir şey değiştirmez.
func AllowPortalUsers() func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxPortalAllowed, true)))
		})
	}
}

func portalAllowed(r *http.Request) bool {
	v, _ := r.Context().Value(ctxPortalAllowed).(bool)
	return v
}

// SupplierIDFromContext: oturumdaki taşeron hesabının bağlı olduğu kart.
// Oturum kapısı doldurur; firma kullanıcısında boştur.
func SupplierIDFromContext(ctx context.Context) (string, bool) {
	v, ok := ctx.Value(ctxSupplierID).(string)
	return v, ok && v != ""
}

// RequirePortalUser: /portal uçları yalnızca taşeron hesabına açıktır.
// Oturum kapısından SONRA zincirlenmeli (kart bağı orada okunur).
func RequirePortalUser() func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if _, ok := SupplierIDFromContext(r.Context()); !ok {
				http.Error(w, `{"error":"bu bölüm yalnızca taşeron hesapları içindir"}`, http.StatusForbidden)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
