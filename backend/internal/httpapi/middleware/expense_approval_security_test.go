package middleware_test

// Masraf girme ve onayı -- izin kapıları GERÇEK router'a karşı (migration
// 0060 + 0066, ürün sahibi kararı 2026-10-07: "masrafı herkes girsin ama
// beklesin; onayı sadece yönetici, en üst kişi yapsın"):
//
//	herkes (projects.expenses.create): üyesi olduğu projede masraf girer,
//	    yalnızca temel alanlarla; kendi bekleyen/reddedilen masrafını
//	    düzeltir/geri çeker; GET /expenses/mine ile yalnızca kendi
//	    masraflarını görür (finans listesi/özeti 403)
//	finance.manage (Finans, Eski Sistem): her masrafta bugünkü haklar
//	onay (projects.expenses.approve): yalnızca Sahip + Yönetici; kendi
//	    masrafına karar 409 -- Sahip hariç

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestExpenseApprovalSecurity(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "expense-approval-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	orgB := mustCreateReadyOrg(t, ctx, d, "expense-approval-org-b")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, orgB.Organization.ID) })
	orgID := org.Organization.ID

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatalf("owner token üretilemedi: %v", err)
	}
	ownerBToken, err := d.issuer.IssueAccessToken(orgB.Owner.ID, domain.RoleAdmin, orgB.Organization.ID)
	if err != nil {
		t.Fatalf("B owner token üretilemedi: %v", err)
	}
	adminUser, adminToken := mustCreateRoleUser(t, ctx, d, orgID, "ea_admin", domain.OrgRoleAdmin)
	_, admin2Token := mustCreateRoleUser(t, ctx, d, orgID, "ea_admin2", domain.OrgRoleAdmin)
	finUser, finToken := mustCreateRoleUser(t, ctx, d, orgID, "ea_fin", domain.OrgRoleFinance)
	_, legacyToken := mustCreateRoleUser(t, ctx, d, orgID, "ea_legacy", domain.OrgRoleLegacyUser)
	pmUser, pmToken := mustCreateRoleUser(t, ctx, d, orgID, "ea_pm", domain.OrgRoleProjectManager)
	fieldUser, fieldToken := mustCreateRoleUser(t, ctx, d, orgID, "ea_field", domain.OrgRoleField)
	field2User, field2Token := mustCreateRoleUser(t, ctx, d, orgID, "ea_field2", domain.OrgRoleField)
	_, fieldBToken := mustCreateRoleUser(t, ctx, d, orgB.Organization.ID, "ea_field_b", domain.OrgRoleField)

	pA := mustCreateProject(t, ctx, d, orgID, "Masraf A (üye)")
	pB := mustCreateProject(t, ctx, d, orgID, "Masraf B (üye değil)")
	for _, u := range []string{finUser.ID, pmUser.ID, fieldUser.ID, field2User.ID} {
		if _, err := d.authzSvc.AddProjectUser(ctx, pA.ID, orgID, service.ProjectUserInput{
			UserID: u, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
		}); err != nil {
			t.Fatalf("üyelik eklenemedi: %v", err)
		}
	}

	const basicBody = `{"category":"material","description":"Çimento","amount":1250.5,"currency":"TRY","expense_date":"2026-10-07","vat_rate":20,"supplier_name":"Usta","invoice_no":"F-9","notes":"not"}`
	expensesPath := func(projectID string) string { return "/api/v1/projects/" + projectID + "/expenses" }
	path := func(projectID, expenseID, action string) string {
		p := expensesPath(projectID) + "/" + expenseID
		if action != "" {
			p += "/" + action
		}
		return p
	}
	newExpense := func(t *testing.T, projectID, token string) string {
		t.Helper()
		rec, body := rbacDo(t, d.router, http.MethodPost, expensesPath(projectID), token, basicBody)
		if rec.Code != http.StatusCreated {
			t.Fatalf("masraf girilemedi: %d %v", rec.Code, body)
		}
		if body["approval_status"] != domain.ExpenseApprovalPending {
			t.Fatalf("yeni masraf onay beklemeli: %v", body)
		}
		return body["id"].(string)
	}
	mine := func(t *testing.T, token, query string) []map[string]any {
		t.Helper()
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/expenses/mine"+query, token, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("Masraflarım: %d %v", rec.Code, body)
		}
		list, _ := body["expenses"].([]any)
		out := make([]map[string]any, 0, len(list))
		for _, row := range list {
			out = append(out, row.(map[string]any))
		}
		return out
	}

	t.Run("01_field_user_enters_expense_without_finance_permission", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, expensesPath(pA.ID), fieldToken, basicBody)
		if rec.Code != http.StatusCreated || body["approval_status"] != domain.ExpenseApprovalPending ||
			body["created_by"] != fieldUser.ID || body["project_id"] != pA.ID || body["vat_rate"] != 20.0 {
			t.Fatalf("Saha masraf girebilmeli: %d %v", rec.Code, body)
		}
		// Üyesi olmadığı projede giremez.
		rec, body = rbacDo(t, d.router, http.MethodPost, expensesPath(pB.ID), fieldToken, basicBody)
		if rec.Code != http.StatusForbidden || body["code"] != "project_access_denied" {
			t.Errorf("üye olmadığı projede masraf: %d %v", rec.Code, body)
		}
	})

	t.Run("02_field_user_cannot_send_finance_links", func(t *testing.T) {
		for _, field := range []string{"change_order_id", "cost_code_id", "budget_line_id"} {
			b := strings.Replace(basicBody, `"notes":"not"`, `"notes":"not","`+field+`":"00000000-0000-0000-0000-000000000001"`, 1)
			rec, body := rbacDo(t, d.router, http.MethodPost, expensesPath(pA.ID), fieldToken, b)
			msg, _ := body["error"].(string)
			if rec.Code != http.StatusForbidden || !strings.Contains(msg, "finans yönetme") {
				t.Errorf("%s gönderilebildi: %d %v", field, rec.Code, body)
			}
		}
		// Boş bağ alanları (web formunun gönderdiği biçim) sorun değil.
		b := strings.Replace(basicBody, `"notes":"not"`, `"notes":"not","change_order_id":"","cost_code_id":"","budget_line_id":""`, 1)
		if rec, body := rbacDo(t, d.router, http.MethodPost, expensesPath(pA.ID), fieldToken, b); rec.Code != http.StatusCreated {
			t.Errorf("boş bağlarla giriş: %d %v", rec.Code, body)
		}
	})

	t.Run("03_field_user_sees_only_own_expenses", func(t *testing.T) {
		own := newExpense(t, pA.ID, fieldToken)
		other := newExpense(t, pA.ID, field2Token)
		finExp := newExpense(t, pA.ID, finToken)
		for _, p := range []string{expensesPath(pA.ID), "/api/v1/projects/" + pA.ID + "/financial-summary"} {
			if rec, _ := rbacDo(t, d.router, http.MethodGet, p, fieldToken, ""); rec.Code != http.StatusForbidden {
				t.Errorf("Saha %s okuyabildi: %d", p, rec.Code)
			}
		}
		rows := mine(t, fieldToken, "")
		seen := map[string]bool{}
		for _, r := range rows {
			if r["created_by"] != fieldUser.ID {
				t.Fatalf("başkasının masrafı göründü: %v", r)
			}
			seen[r["id"].(string)] = true
			if r["project_name"] != pA.Name || r["project_status"] == nil {
				t.Errorf("satır projesini taşımalı: %v", r)
			}
		}
		if !seen[own] || seen[other] || seen[finExp] {
			t.Errorf("yalnızca kendi masrafları: own=%v other=%v fin=%v", seen[own], seen[other], seen[finExp])
		}
		if f := mine(t, fieldToken, "?project_id="+pB.ID); len(f) != 0 {
			t.Errorf("proje süzgeci: %d", len(f))
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/expenses/mine?project_id=x", fieldToken, ""); rec.Code != http.StatusBadRequest {
			t.Errorf("geçersiz proje kimliği 400 olmalı: %d", rec.Code)
		}
		// Yanıtta toplam/özet yok.
		_, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/expenses/mine", fieldToken, "")
		for k := range body {
			if k != "expenses" && k != "limit" {
				t.Errorf("Masraflarım beklenmeyen alan taşıyor: %s", k)
			}
		}
	})

	t.Run("04_field_user_edits_and_withdraws_only_own_unapproved", func(t *testing.T) {
		own := newExpense(t, pA.ID, fieldToken)
		edit := strings.Replace(basicBody, `"amount":1250.5`, `"amount":1100`, 1)
		rec, body := rbacDo(t, d.router, http.MethodPut, path(pA.ID, own, ""), fieldToken, edit)
		if rec.Code != http.StatusOK || body["amount"] != 1100.0 || body["approval_status"] != domain.ExpenseApprovalPending {
			t.Fatalf("kendi bekleyen masrafını düzeltebilmeli: %d %v", rec.Code, body)
		}
		// Reddedilen: düzeltilince yeniden onaya.
		if rec, body := rbacDo(t, d.router, http.MethodPost, path(pA.ID, own, "reject"), adminToken, `{"reason":"Fiş yok"}`); rec.Code != http.StatusOK {
			t.Fatalf("ret: %d %v", rec.Code, body)
		}
		rec, body = rbacDo(t, d.router, http.MethodPut, path(pA.ID, own, ""), fieldToken, edit)
		if rec.Code != http.StatusOK || body["approval_status"] != domain.ExpenseApprovalPending || body["decision_note"] != "" {
			t.Fatalf("reddedilen düzeltilince onaya dönmeli: %d %v", rec.Code, body)
		}
		// Başkasının masrafı: 409 + mesaj.
		other := newExpense(t, pA.ID, field2Token)
		for _, req := range []struct{ method, path, body string }{
			{http.MethodPut, path(pA.ID, other, ""), edit},
			{http.MethodPost, path(pA.ID, other, "void"), `{"reason":"x"}`},
		} {
			rec, body := rbacDo(t, d.router, req.method, req.path, fieldToken, req.body)
			if rec.Code != http.StatusConflict || !strings.Contains(body["error"].(string), "kendi girdiğiniz") {
				t.Errorf("başkasının masrafı (%s %s): %d %v", req.method, req.path, rec.Code, body)
			}
		}
		// Onaylanmış kendi masrafı: 409.
		approved := newExpense(t, pA.ID, fieldToken)
		if rec, body := rbacDo(t, d.router, http.MethodPost, path(pA.ID, approved, "approve"), adminToken, ""); rec.Code != http.StatusOK {
			t.Fatalf("onay: %d %v", rec.Code, body)
		}
		if rec, body := rbacDo(t, d.router, http.MethodPut, path(pA.ID, approved, ""), fieldToken, edit); rec.Code != http.StatusConflict {
			t.Errorf("onaylı masraf düzeltilebildi: %d %v", rec.Code, body)
		}
		if rec, body := rbacDo(t, d.router, http.MethodPost, path(pA.ID, approved, "void"), fieldToken, `{}`); rec.Code != http.StatusConflict {
			t.Errorf("onaylı masraf geri çekilebildi: %d %v", rec.Code, body)
		}
		// Geri çekme: iz giren kişide.
		rec, body = rbacDo(t, d.router, http.MethodPost, path(pA.ID, own, "void"), fieldToken, `{"reason":"yanlış proje"}`)
		if rec.Code != http.StatusOK || body["voided_at"] == nil || body["voided_by"] != fieldUser.ID {
			t.Errorf("kendi masrafını geri çekebilmeli: %d %v", rec.Code, body)
		}
		// Finans yetkilisi (Eski Sistem) başkasının onaylı masrafını düzeltir.
		if rec, body := rbacDo(t, d.router, http.MethodPut, path(pA.ID, approved, ""), legacyToken, edit); rec.Code != http.StatusOK {
			t.Errorf("finance.manage her masrafı düzeltebilmeli: %d %v", rec.Code, body)
		}
	})

	t.Run("05_finance_role_can_no_longer_approve", func(t *testing.T) {
		id := newExpense(t, pA.ID, fieldToken)
		for name, tok := range map[string]string{"finance": finToken, "legacy": legacyToken, "pm": pmToken, "field": fieldToken} {
			rec, body := rbacDo(t, d.router, http.MethodPost, path(pA.ID, id, "approve"), tok, "")
			if rec.Code != http.StatusForbidden || body["code"] != "permission_denied" {
				t.Errorf("%s onaylayabildi: %d %v", name, rec.Code, body)
			}
			if rec, _ := rbacDo(t, d.router, http.MethodPost, path(pA.ID, id, "reject"), tok, `{"reason":"x"}`); rec.Code != http.StatusForbidden {
				t.Errorf("%s reddedebildi: %d", name, rec.Code)
			}
		}
	})

	t.Run("06_admin_cannot_decide_own_owner_can", func(t *testing.T) {
		id := newExpense(t, pA.ID, adminToken)
		for _, action := range []string{"approve", "reject"} {
			rec, body := rbacDo(t, d.router, http.MethodPost, path(pA.ID, id, action), adminToken, `{"reason":"x"}`)
			msg, _ := body["error"].(string)
			if rec.Code != http.StatusConflict || !strings.Contains(msg, "kendi girdiğiniz masrafı") {
				t.Errorf("Yönetici kendi masrafı (%s): %d %v", action, rec.Code, body)
			}
		}
		rec, body := rbacDo(t, d.router, http.MethodPost, path(pA.ID, id, "approve"), admin2Token, "")
		if rec.Code != http.StatusOK || body["approval_status"] != domain.ExpenseApprovalApproved || body["decided_by"] == adminUser.ID {
			t.Fatalf("diğer Yönetici onaylayabilmeli: %d %v", rec.Code, body)
		}
		_, sum := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/financial-summary", ownerToken, "")
		if sum["total_expenses"] == 0.0 {
			t.Errorf("onaylanan masraf toplama girmeli: %v", sum["total_expenses"])
		}
		ownerExp := newExpense(t, pB.ID, ownerToken)
		if rec, body := rbacDo(t, d.router, http.MethodPost, path(pB.ID, ownerExp, "approve"), ownerToken, ""); rec.Code != http.StatusOK {
			t.Errorf("Sahip kendi masrafını onaylayabilmeli: %d %v", rec.Code, body)
		}
	})

	t.Run("07_reject_requires_reason_and_unknown_is_404", func(t *testing.T) {
		id := newExpense(t, pA.ID, fieldToken)
		if rec, _ := rbacDo(t, d.router, http.MethodPost, path(pA.ID, id, "reject"), ownerToken, `{"reason":""}`); rec.Code != http.StatusBadRequest {
			t.Errorf("gerekçesiz ret 400 olmalı: %d", rec.Code)
		}
		rec, body := rbacDo(t, d.router, http.MethodPost, path(pA.ID, id, "reject"), ownerToken, `{"reason":"Fiş yok"}`)
		if rec.Code != http.StatusOK || body["approval_status"] != domain.ExpenseApprovalRejected || body["decision_note"] != "Fiş yok" {
			t.Errorf("ret: %d %v", rec.Code, body)
		}
		const unknown = "00000000-0000-0000-0000-000000000000"
		if rec, _ := rbacDo(t, d.router, http.MethodPost, path(pA.ID, unknown, "approve"), ownerToken, ""); rec.Code != http.StatusNotFound {
			t.Errorf("olmayan masraf onayı: %d", rec.Code)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodPut, path(pA.ID, unknown, ""), fieldToken, basicBody); rec.Code != http.StatusNotFound {
			t.Errorf("olmayan masrafı düzeltme: %d", rec.Code)
		}
	})

	t.Run("08_tenant_isolation", func(t *testing.T) {
		id := newExpense(t, pA.ID, fieldToken)
		// Başka firmanın sahibi A'nın projesine/masrafına dokunamaz.
		for _, req := range []struct{ method, path, body string }{
			{http.MethodPut, path(pA.ID, id, ""), basicBody},
			{http.MethodPost, path(pA.ID, id, "void"), `{}`},
			{http.MethodPost, path(pA.ID, id, "approve"), ""},
			{http.MethodPost, expensesPath(pA.ID), basicBody},
		} {
			if rec, body := rbacDo(t, d.router, req.method, req.path, ownerBToken, req.body); rec.Code != http.StatusNotFound {
				t.Errorf("B sahibi %s %s: %d %v", req.method, req.path, rec.Code, body)
			}
		}
		// B'nin sahadaki kullanıcısının listesinde A'nın masrafı yok.
		for _, r := range mine(t, fieldBToken, "") {
			t.Errorf("B kullanıcısı başka firmanın masrafını gördü: %v", r)
		}
		if f := mine(t, fieldBToken, "?project_id="+pA.ID); len(f) != 0 {
			t.Errorf("B kullanıcısı A projesiyle süzünce satır geldi: %d", len(f))
		}
	})
}
