package middleware

import (
	"context"
	"net/http"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// errUserInactiveBody: 401 -- istemciler (web fetchWithSession, mobil
// ApiClient) 401'de refresh dener; refresh pasif kullanıcıya 403
// "kullanıcı pasif durumda" döner (mobilin tanıdığı sabit mesaj) ve iki
// istemci de oturumu kapatıp giriş ekranına döner.
const errUserInactiveBody = `{"error":"hesabınız pasif durumda, lütfen yeniden giriş yapın","code":"user_inactive"}`

// applyUserGate, veritabanından YENİ okunan kullanıcı durumunu isteğe
// uygular: pasif/silinmiş kullanıcı 401 alır, token'daki organizasyon
// veritabanındakiyle uyuşmazsa 401, aksi hâlde context'teki kaba rol
// VERİTABANINDAKİ rolle değiştirilir -- ardından gelen RequireRole
// (requireAdmin) token'ın 15 dakikalık ömrü boyunca eski rolü değil güncel
// rolü görür. ok=false ise yanıt yazılmıştır.
func applyUserGate(w http.ResponseWriter, r *http.Request, isActive, deleted bool, role string, orgID pgtype.UUID) (*http.Request, bool) {
	if !isActive || deleted {
		http.Error(w, errUserInactiveBody, http.StatusUnauthorized)
		return r, false
	}
	claimOrg, _ := OrganizationIDFromContext(r.Context())
	dbOrg := ""
	if orgID.Valid {
		dbOrg = orgID.String()
	}
	if claimOrg != dbOrg {
		http.Error(w, `{"error":"oturum geçersiz veya süresi dolmuş"}`, http.StatusUnauthorized)
		return r, false
	}
	ctx := context.WithValue(r.Context(), ctxRole, domain.Role(role))
	return r.WithContext(ctx), true
}

// RequireActiveUser, RequireAuth'tan SONRA, requireOnboarded ALMAYAN
// rotalarda (onboarding, firma ayarları, ilk şifre belirleme, cihaz kaydı,
// öneri) zincirlenir: RequireOnboarded'ın yaptığı "kullanıcı hâlâ aktif mi,
// rolü ne" kontrolünün aynısı (bkz. applyUserGate). requireAdmin'den ÖNCE
// gelmelidir. Business rotaları bunu ayrıca almaz -- RequireOnboarded aynı
// kontrolü zaten okuduğu satırla yapar (istek başına tek sorgu).
func RequireActiveUser(q *sqlc.Queries) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
			st, err := q.GetUserGateStatus(r.Context(), uid)
			if err != nil {
				http.Error(w, `{"error":"oturum geçersiz veya süresi dolmuş"}`, http.StatusUnauthorized)
				return
			}
			r, ok = applyUserGate(w, r, st.IsActive, st.UserDeleted, st.Role, st.OrganizationID)
			if !ok {
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
