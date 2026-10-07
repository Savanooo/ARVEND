package middleware_test

// Deneme süresi (ürün kararı 2026-10-07): /auth/me firmanın deneme
// durumunu (bitiş, kalan gün, doldu mu) döner ama süre dolması erişimi
// KESMEZ -- otomatik engel yok. Paylaşılan harness:
// require_permission_test.go.

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

func TestTrialStatusOnAuthMe(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "trial-status-org")
	orgID := org.Organization.ID
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, orgID) })

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatalf("owner token üretilemedi: %v", err)
	}
	_, finToken := mustCreateRoleUser(t, ctx, d, orgID, "ts_fin", domain.OrgRoleFinance)

	rec, me := rbacDo(t, d.router, http.MethodGet, "/api/v1/auth/me", ownerToken, "")
	if rec.Code != http.StatusOK || me["organization_status"] != "active" || me["trial_days_left"] != nil || me["trial_expired"] != nil {
		t.Fatalf("aktif firmada deneme alanı olmamalı: status=%d me=%v", rec.Code, me)
	}

	// ---------- Deneme süresi ----------

	t.Run("trial_status_exposed_and_never_blocks", func(t *testing.T) {
		setTrial := func(t *testing.T, endsAt time.Time) {
			t.Helper()
			if _, err := d.pool.Exec(ctx, "UPDATE organizations SET status = 'trial', trial_ends_at = $2 WHERE id = $1", orgID, endsAt); err != nil {
				t.Fatalf("deneme süresi ayarlanamadı: %v", err)
			}
		}
		t.Cleanup(func() {
			_, _ = d.pool.Exec(ctx, "UPDATE organizations SET status = 'active', trial_ends_at = NULL WHERE id = $1", orgID)
		})

		setTrial(t, time.Now().Add(3*24*time.Hour))
		rec, me := rbacDo(t, d.router, http.MethodGet, "/api/v1/auth/me", ownerToken, "")
		if rec.Code != http.StatusOK || me["organization_status"] != "trial" || me["trial_expired"] != false {
			t.Fatalf("status=%d me=%v", rec.Code, me)
		}
		if days, _ := me["trial_days_left"].(float64); days != 3 {
			t.Errorf("trial_days_left = %v, beklenen 3", me["trial_days_left"])
		}
		if me["trial_ends_on"] == nil || me["trial_ends_at"] == nil {
			t.Errorf("bitiş tarihi dönmeli: %v", me)
		}

		setTrial(t, time.Now().Add(-48*time.Hour))
		rec, me = rbacDo(t, d.router, http.MethodGet, "/api/v1/auth/me", finToken, "")
		if rec.Code != http.StatusOK || me["trial_expired"] != true {
			t.Fatalf("süresi dolmuş deneme: status=%d me=%v", rec.Code, me)
		}
		// Ürün kararı: otomatik engel YOK.
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects", ownerToken, ""); rec.Code != http.StatusOK {
			t.Errorf("süresi dolan deneme erişimi kesmemeli: status=%d", rec.Code)
		}
	})
}
