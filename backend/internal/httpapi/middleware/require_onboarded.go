package middleware

import (
	"net/http"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// RequireOnboarded, RequireAuth'tan SONRA zincirlenmeli. "Business" uçlarını
// (offers/projects/customers/products/calculations/employees/attendance/
// settings/users-yönetimi) iki koşuldan biri karşılanmadıysa keser:
//  1. must_change_password=true -- Super Admin'in verdiği geçici şifre
//     henüz değiştirilmedi.
//  2. organizations.onboarding_completed=false -- ilk-giriş sihirbazı
//     henüz tamamlanmadı.
//
// Bu, frontend/mobil'in redirect zincirinin AYNISI ama backend'de tekrar
// uygulanmış hali -- "yalnızca client-side redirect güvenliğine güvenme"
// kısıtı gereği: bir istemci bu redirect'leri atlayıp doğrudan API'ye
// istek atarsa (ör. curl ile), bu middleware olmadan hiçbir şey onu
// durdurmazdı (RequireAuth yalnızca kimlik doğrular + askıya alınmışlığı
// kontrol eder, onboarding/şifre durumuna bakmaz).
//
// SÜPER ADMIN MUAFTIR (organizasyonu yok, onboarding kavramı ona
// uygulanmaz) -- rol kontrolüyle DB sorgusuna bile gitmeden erişim
// verilir. requireOnboarded, router.go'da YALNIZCA business route
// gruplarına eklenir; auth/me, logout, refresh, set-initial-password,
// onboarding/*, organization/settings/* ve platform/* (zaten yalnızca
// super_admin'e açık) BİLİNÇLİ OLARAK bu middleware'i almaz -- aksi halde
// kullanıcı kendi kilidini açacağı uçlara da erişemezdi.
func RequireOnboarded(q *sqlc.Queries) func(http.Handler) http.Handler {
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
			uid, err := repository.StringToUUID(userID)
			if err != nil {
				http.Error(w, `{"error":"oturum geçersiz veya süresi dolmuş"}`, http.StatusUnauthorized)
				return
			}
			status, err := q.GetOnboardingGateStatus(r.Context(), uid)
			if err != nil {
				http.Error(w, `{"error":"oturum geçersiz veya süresi dolmuş"}`, http.StatusUnauthorized)
				return
			}
			if status.MustChangePassword {
				http.Error(w, `{"error":"devam etmeden önce şifrenizi değiştirmeniz gerekiyor"}`, http.StatusForbidden)
				return
			}
			if !status.OnboardingCompleted {
				http.Error(w, `{"error":"devam etmeden önce firma kurulumunu tamamlamanız gerekiyor"}`, http.StatusForbidden)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
