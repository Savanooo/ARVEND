package middleware_test

// Masraf onayı (migration 0060) -- izin kapısı GERÇEK router'a karşı:
//
//	legacy_user / project_manager: masraf girer (finance.manage) ama ONAYLAYAMAZ
//	finance:                       üyesi olduğu projede onaylar/reddeder
//	owner/admin:                   her projede (üyelikten muaf)

import (
	"context"
	"net/http"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestExpenseApprovalSecurity(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "expense-approval-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, org.Organization.ID)
	if err != nil {
		t.Fatalf("owner token üretilemedi: %v", err)
	}
	finUser, finToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "ea_fin", domain.OrgRoleFinance)
	_, legacyToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "ea_legacy", domain.OrgRoleLegacyUser)
	pmUser, pmToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "ea_pm", domain.OrgRoleProjectManager)

	pA := mustCreateProject(t, ctx, d, org.Organization.ID, "Masraf Onay A (üye)")
	pB := mustCreateProject(t, ctx, d, org.Organization.ID, "Masraf Onay B (üye değil)")
	for _, u := range []string{finUser.ID, pmUser.ID} {
		if _, err := d.authzSvc.AddProjectUser(ctx, pA.ID, org.Organization.ID, service.ProjectUserInput{
			UserID: u, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
		}); err != nil {
			t.Fatalf("üyelik eklenemedi: %v", err)
		}
	}

	// newExpense: Eski Sistem kullanıcısı HTTP üzerinden masraf girer (giren
	// kişinin tipik rolü); yanıt onay bekleyen kaydı döner.
	newExpense := func(t *testing.T, projectID string) string {
		t.Helper()
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+projectID+"/expenses", legacyToken,
			`{"category":"material","description":"Çimento","amount":1250.5,"currency":"TRY","expense_date":"2026-10-07"}`)
		if rec.Code != http.StatusCreated {
			t.Fatalf("masraf girilemedi: %d %v", rec.Code, body)
		}
		if body["approval_status"] != domain.ExpenseApprovalPending {
			t.Fatalf("yeni masraf onay beklemeli: %v", body)
		}
		return body["id"].(string)
	}
	path := func(projectID, expenseID, action string) string {
		return "/api/v1/projects/" + projectID + "/expenses/" + expenseID + "/" + action
	}

	t.Run("1_entering_roles_cannot_approve", func(t *testing.T) {
		id := newExpense(t, pA.ID)
		for name, tok := range map[string]string{"legacy": legacyToken, "pm": pmToken} {
			rec, body := rbacDo(t, d.router, http.MethodPost, path(pA.ID, id, "approve"), tok, "")
			if rec.Code != http.StatusForbidden || body["code"] != "permission_denied" {
				t.Errorf("%s onaylayabildi: %d %v", name, rec.Code, body)
			}
			rec, _ = rbacDo(t, d.router, http.MethodPost, path(pA.ID, id, "reject"), tok, `{"reason":"x"}`)
			if rec.Code != http.StatusForbidden {
				t.Errorf("%s reddedebildi: %d", name, rec.Code)
			}
		}
	})

	t.Run("2_finance_member_approves_and_summary_counts_it", func(t *testing.T) {
		id := newExpense(t, pA.ID)
		rec, body := rbacDo(t, d.router, http.MethodPost, path(pA.ID, id, "approve"), finToken, "")
		if rec.Code != http.StatusOK || body["approval_status"] != domain.ExpenseApprovalApproved || body["decided_at"] == nil {
			t.Fatalf("finans onaylayamadı: %d %v", rec.Code, body)
		}
		rec, body = rbacDo(t, d.router, http.MethodPost, path(pA.ID, id, "approve"), ownerToken, "")
		if rec.Code != http.StatusConflict {
			t.Errorf("ikinci onay 409 olmalı: %d %v", rec.Code, body)
		}
		_, sum := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/financial-summary", ownerToken, "")
		if sum["total_expenses"] != 1250.5 {
			t.Errorf("yalnızca onaylı masraf sayılmalı (önceki test onay bekliyor): %v", sum["total_expenses"])
		}
	})

	t.Run("3_finance_outside_project_denied", func(t *testing.T) {
		id := newExpense(t, pB.ID)
		rec, body := rbacDo(t, d.router, http.MethodPost, path(pB.ID, id, "approve"), finToken, "")
		if rec.Code != http.StatusForbidden || body["code"] != "project_access_denied" {
			t.Errorf("üye olmadığı projede onay: %d %v", rec.Code, body)
		}
	})

	t.Run("4_reject_requires_reason", func(t *testing.T) {
		id := newExpense(t, pA.ID)
		rec, _ := rbacDo(t, d.router, http.MethodPost, path(pA.ID, id, "reject"), ownerToken, `{"reason":""}`)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("gerekçesiz ret 400 olmalı: %d", rec.Code)
		}
		rec, body := rbacDo(t, d.router, http.MethodPost, path(pA.ID, id, "reject"), ownerToken, `{"reason":"Fiş yok"}`)
		if rec.Code != http.StatusOK || body["approval_status"] != domain.ExpenseApprovalRejected || body["decision_note"] != "Fiş yok" {
			t.Errorf("ret: %d %v", rec.Code, body)
		}
	})

	t.Run("5_unknown_expense_is_404", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodPost, path(pA.ID, "00000000-0000-0000-0000-000000000000", "approve"), ownerToken, "")
		if rec.Code != http.StatusNotFound {
			t.Errorf("olmayan masraf: %d", rec.Code)
		}
	})
}
