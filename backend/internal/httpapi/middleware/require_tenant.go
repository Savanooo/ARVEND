package middleware

import (
	"net/http"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

// RequireTenant, RequireAuth'tan SONRA zincirlenmeli. Organizasyon bağlamı
// olmayan oturumları -- super_admin (organization_id her zaman NULL, bkz.
// users_super_admin_has_no_org CHECK'i) ve org claim'i boş gelen her
// token'ı -- firma kapsamlı (tenant) rotalardan keser. Platform hesabı
// tenant izin sistemine ASLA köprülenmez ve bir organizasyon bağlamı
// ÇIKARSANMAZ/UYDURULMAZ: super_admin'in tek erişim yüzeyi /platform/*'dır.
func RequireTenant() func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if rejectPlatformAccount(w, r) {
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// rejectPlatformAccount, isteğin sahibi bir tenant hesabı DEĞİLSE 403 yazar
// ve true döner. RequireTenant'ın yanı sıra RequireOnboarded/LoadAuthorization/
// RequirePermission/RequireProjectPermission de bunu çağırır -- her katman
// BAĞIMSIZ olarak reddeder (savunma derinliği: bir rota grubuna requireTenant
// eklenmesi unutulsa bile super_admin tenant verisine ulaşamaz). Auth
// context'i hiç yoksa da reddeder (deny-by-default).
func rejectPlatformAccount(w http.ResponseWriter, r *http.Request) bool {
	role, _ := RoleFromContext(r.Context())
	orgID, _ := OrganizationIDFromContext(r.Context())
	if role == domain.RoleSuperAdmin || orgID == "" {
		http.Error(w, `{"error":"bu uç yalnızca bir firmaya bağlı hesaplar içindir","code":"tenant_context_required"}`, http.StatusForbidden)
		return true
	}
	return false
}
