package middleware_test

// Bütçe revizyonu onayı (ürün kararı 2026-10-07, migration 0062) -- GERÇEK
// router + PostgreSQL üzerinde: onay/red projects.budget.approve ister
// (Proje Yöneticisi alamaz); kişi kendi revizyonuna karar veremez (Sahip
// hariç) -> 409 + Türkçe mesaj; revize bütçeyi negatife düşüren onay 409.
// Paylaşılan harness: require_permission_test.go.

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestBudgetApprovalSecurityMatrix(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "budget-approval-matrix-org")
	orgID := org.Organization.ID
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, orgID) })

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatalf("owner token üretilemedi: %v", err)
	}
	finUser, finToken := mustCreateRoleUser(t, ctx, d, orgID, "ba_fin", domain.OrgRoleFinance)
	fin2User, fin2Token := mustCreateRoleUser(t, ctx, d, orgID, "ba_fin2", domain.OrgRoleFinance)
	pmUser, pmToken := mustCreateRoleUser(t, ctx, d, orgID, "ba_pm", domain.OrgRoleProjectManager)

	p := mustCreateProject(t, ctx, d, orgID, "Bütçe Onay Matrisi Projesi")
	for _, u := range []string{finUser.ID, fin2User.ID, pmUser.ID} {
		if _, err := d.authzSvc.AddProjectUser(ctx, p.ID, orgID, service.ProjectUserInput{
			UserID: u, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
		}); err != nil {
			t.Fatalf("üyelik eklenemedi: %v", err)
		}
	}
	base := "/api/v1/projects/" + p.ID

	// ---------- Bütçe revizyonu ----------

	rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/organization/cost-codes", ownerToken,
		`{"code":"BA-MLZ","name":"Onay Kodu","category":"Malzeme"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("maliyet kodu oluşturulamadı: %d %v", rec.Code, body)
	}
	costCodeID := body["id"].(string)
	rec, body = rbacDo(t, d.router, http.MethodPost, base+"/budget/lines", ownerToken,
		`{"cost_code_id":"`+costCodeID+`","description":"Onay kalemi","original_amount":10000}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("bütçe kalemi eklenemedi: %d %v", rec.Code, body)
	}
	lineID := body["id"].(string)
	if rec, body := rbacDo(t, d.router, http.MethodPost, base+"/budget/baseline", ownerToken, ""); rec.Code != http.StatusOK {
		t.Fatalf("baseline alınamadı: %d %v", rec.Code, body)
	}
	createAdj := func(t *testing.T, token string, amount string) string {
		t.Helper()
		rec, body := rbacDo(t, d.router, http.MethodPost, base+"/budget/adjustments", token,
			`{"budget_line_id":"`+lineID+`","amount":`+amount+`,"reason":"Matris"}`)
		if rec.Code != http.StatusCreated {
			t.Fatalf("revizyon oluşturulamadı: %d %v", rec.Code, body)
		}
		return body["id"].(string)
	}
	finAdj := createAdj(t, finToken, "1000")

	t.Run("budget_1_created_by_is_exposed", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, base+"/budget/adjustments", fin2Token, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("liste alınamadı: %d", rec.Code)
		}
		list, _ := body["adjustments"].([]any)
		if len(list) == 0 || list[0].(map[string]any)["created_by"] != finUser.ID {
			t.Errorf("created_by istemciye dönmeli (kendi revizyonunda düğmeler gizlensin): %v", list)
		}
	})

	t.Run("budget_2_project_manager_cannot_approve", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, base+"/budget/adjustments/"+finAdj+"/approve", pmToken, "")
		if rec.Code != http.StatusForbidden || body["code"] != "permission_denied" {
			t.Errorf("status=%d code=%v, beklenen 403 permission_denied (pm'de budget.approve yok)", rec.Code, body["code"])
		}
	})

	t.Run("budget_3_finance_cannot_decide_own", func(t *testing.T) {
		for _, action := range []string{"approve", "reject"} {
			rec, body := rbacDo(t, d.router, http.MethodPost, base+"/budget/adjustments/"+finAdj+"/"+action, finToken, "")
			msg, _ := body["error"].(string)
			if rec.Code != http.StatusConflict || !strings.Contains(msg, "kendi oluşturduğunuz") {
				t.Errorf("%s: status=%d error=%q, beklenen 409 + Türkçe sebep", action, rec.Code, msg)
			}
		}
	})

	t.Run("budget_4_other_finance_user_approves", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, base+"/budget/adjustments/"+finAdj+"/approve", fin2Token, "")
		if rec.Code != http.StatusOK || body["status"] != domain.AdjustmentStatusApproved || body["approved_by"] != fin2User.ID {
			t.Errorf("status=%d body=%v, beklenen 200 approved (approved_by=fin2)", rec.Code, body)
		}
	})

	t.Run("budget_5_owner_approves_own", func(t *testing.T) {
		own := createAdj(t, ownerToken, "500")
		rec, body := rbacDo(t, d.router, http.MethodPost, base+"/budget/adjustments/"+own+"/approve", ownerToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status=%d body=%v, Sahip kendi revizyonunu onaylayabilmeli", rec.Code, body)
		}
	})

	t.Run("budget_6_negative_revised_budget_refused", func(t *testing.T) {
		// 10000 + 1000 + 500 = 11500; -11500.01 negatife düşürür.
		adj := createAdj(t, finToken, "-11500.01")
		rec, body := rbacDo(t, d.router, http.MethodPost, base+"/budget/adjustments/"+adj+"/approve", fin2Token, "")
		msg, _ := body["error"].(string)
		if rec.Code != http.StatusConflict || !strings.Contains(msg, "negatife") {
			t.Errorf("status=%d error=%q, beklenen 409 negatif bütçe", rec.Code, msg)
		}
	})
}
