package middleware

import (
	"context"
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

const ctxAuthzContext ctxKey = iota + 100 // auth.go'daki iota bloğuyla ÇAKIŞMASIN diye ayrı taban.

// LoadAuthorization, RequireOnboarded'dan SONRA zincirlenmeli. Kullanıcının
// rol kodunu ve TÜM izin kodlarını İSTEK BAŞINA BİR KEZ (2 hafif sorgu)
// yükler ve request context'ine koyar -- ardından gelen RequirePermission/
// RequireProjectPermission bunu okur, TEKRAR sorgu ATMAZ (spec §12).
//
// super_admin İÇİN HİÇBİR ŞEY YAPMAZ (context'e AuthzContext KOYMAZ) --
// RequirePermission/RequireProjectPermission onu RoleFromContext ile ayrıca
// ve ÖNCELİKLE kontrol eder (RequireOnboarded'daki AYNI muafiyet deseni).
// Bu nedenle LoadAuthorization'ın kendisi super_admin için sorgu ATLAMAZ
// hatasına düşmez -- rol kontrolü middleware'in en başında yapılır.
func LoadAuthorization(authzSvc *service.AuthorizationService) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			role, ok := RoleFromContext(r.Context())
			if ok && role == domain.RoleSuperAdmin {
				next.ServeHTTP(w, r)
				return
			}
			userID, ok := UserIDFromContext(r.Context())
			if !ok {
				http.Error(w, `{"error":"oturum bulunamadı"}`, http.StatusUnauthorized)
				return
			}
			orgID, ok := OrganizationIDFromContext(r.Context())
			if !ok || orgID == "" {
				http.Error(w, `{"error":"oturum geçersiz veya süresi dolmuş"}`, http.StatusUnauthorized)
				return
			}
			authz, err := authzSvc.LoadAuthzContext(r.Context(), userID, orgID)
			if err != nil {
				http.Error(w, `{"error":"yetkilendirme bilgisi yüklenemedi"}`, http.StatusInternalServerError)
				return
			}
			ctx := context.WithValue(r.Context(), ctxAuthzContext, authz)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

func AuthzContextFromRequest(ctx context.Context) (*service.AuthzContext, bool) {
	v, ok := ctx.Value(ctxAuthzContext).(*service.AuthzContext)
	return v, ok
}

// RequirePermission, LoadAuthorization'dan SONRA zincirlenmeli.
// super_admin HER ZAMAN muaftır (platform rolü, tenant izin sistemine hiç
// girmez). Diğer kullanıcılar için AuthzContext'teki (ÖNCEDEN yüklenmiş,
// bu istekte TEKRAR sorgu atılmadan) izin kümesine bakılır -- tanımsız/
// eksik izin = 403 "permission_denied" (deny-by-default).
func RequirePermission(code string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			role, ok := RoleFromContext(r.Context())
			if ok && role == domain.RoleSuperAdmin {
				next.ServeHTTP(w, r)
				return
			}
			authz, ok := AuthzContextFromRequest(r.Context())
			if !ok || !authz.HasPermission(code) {
				writePermissionDenied(w)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// RequireProjectPermission, RequirePermission'ın proje-üyeliği-farkında
// varyantıdır -- URL'nin proje kimliği ("id" route param'ı, tüm proje
// alt-kaynak rotalarının ORTAK sözleşmesi, bkz. router.go) hem izin HEM
// üyelik açısından doğrulanır. owner/admin/legacy_user üyelik kontrolünden
// MUAFTIR (bkz. AuthzContext.BypassesProjectMembership); diğerleri
// yalnızca project_users'ta üye iseler geçer -- TEK ek sorgu (EXISTS).
func RequireProjectPermission(authzSvc *service.AuthorizationService, code string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			role, ok := RoleFromContext(r.Context())
			if ok && role == domain.RoleSuperAdmin {
				next.ServeHTTP(w, r)
				return
			}
			authz, ok := AuthzContextFromRequest(r.Context())
			if !ok || !authz.HasPermission(code) {
				writePermissionDenied(w)
				return
			}
			projectID := chi.URLParam(r, "id")
			canAccess, err := authzSvc.CanAccessProject(r.Context(), authz, projectID)
			if err != nil {
				if errors.Is(err, domain.ErrNotFound) {
					http.Error(w, `{"error":"kayıt bulunamadı"}`, http.StatusNotFound)
					return
				}
				http.Error(w, `{"error":"yetki kontrolü başarısız"}`, http.StatusInternalServerError)
				return
			}
			if !canAccess {
				http.Error(w, `{"error":"bu projeye erişim yetkiniz yok","code":"project_access_denied"}`, http.StatusForbidden)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func writePermissionDenied(w http.ResponseWriter) {
	http.Error(w, `{"error":"bu işlem için yetkiniz yok","code":"permission_denied"}`, http.StatusForbidden)
}
