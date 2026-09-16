package middleware_test

// ARVEND V2 -- Sprint 2 (WBS + Cost Codes + Project Budget + Cost Control)
// GÜVENLİK/İZİN test matrisi -- GERÇEK bir PostgreSQL bağlantısına VE
// GERÇEK, TAM router'a (httpapi.NewRouter) karşı doğrular. Sprint 1'in
// require_permission_test.go'daki AYNI paylaşılan harness'i (rbacTestDeps/
// setupRBACTestRouter/mustCreateReadyOrg/mustCreateProject/mustCreateRoleUser/
// rbacDo/rbacCleanupOrg) kullanır -- ayrı bir kopya kurmaz.

import (
	"context"
	"net/http"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestCostControlSecurityMatrix(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "cost-control-matrix-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, org.Organization.ID)
	if err != nil {
		t.Fatalf("owner token üretilemedi: %v", err)
	}
	pmUser, pmToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "cc_pm", domain.OrgRoleProjectManager)
	finUser, finToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "cc_fin", domain.OrgRoleFinance)
	fieldUser, fieldToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "cc_field", domain.OrgRoleField)

	pA := mustCreateProject(t, ctx, d, org.Organization.ID, "Maliyet Kontrolü Projesi A (üye)")
	pB := mustCreateProject(t, ctx, d, org.Organization.ID, "Maliyet Kontrolü Projesi B (üye değil)")

	// pm/finance/field YALNIZCA pA'ya üye -- pB'ye ASLA eklenmedi (Sprint
	// 1 ile AYNI üyelik-farkında erişim yüzeyi, bkz. require_permission_
	// test.go'daki AYNI desen).
	for _, u := range []string{pmUser.ID, finUser.ID, fieldUser.ID} {
		if _, err := d.authzSvc.AddProjectUser(ctx, pA.ID, org.Organization.ID, service.ProjectUserInput{
			UserID: u, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
		}); err != nil {
			t.Fatalf("üyelik eklenemedi: %v", err)
		}
	}

	// pA'nın bütçesi (offer dönüşümünde OTOMATİK oluştu, bkz. service/
	// cost_control_test.go test 8) baseline alınır ve BİR kalem eklenir --
	// hem "manage" izni testleri hem cross-project IDOR testi için gerçek
	// bir budget_line_id gerekiyor. Bu adımlar OWNER token'ıyla (tüm
	// izinlere sahip) yapılır -- test odağı bu KURULUM değil, aşağıdaki
	// erişim kontrolleridir.
	createCostCode := func(t *testing.T, code string) string {
		t.Helper()
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/organization/cost-codes", ownerToken,
			`{"code":"`+code+`","name":"Test Kod","category":"Malzeme"}`)
		if rec.Code != http.StatusCreated {
			t.Fatalf("maliyet kodu oluşturulamadı: status=%d body=%v", rec.Code, body)
		}
		return body["id"].(string)
	}
	costCodeID := createCostCode(t, "SEC-MLZ-A")

	createBudgetLine := func(t *testing.T, projectID, token, costCodeID string) (int, map[string]any) {
		t.Helper()
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+projectID+"/budget/lines", token,
			`{"cost_code_id":"`+costCodeID+`","description":"Güvenlik testi kalemi","original_amount":100000}`)
		return rec.Code, body
	}
	lineStatus, lineBody := createBudgetLine(t, pA.ID, ownerToken, costCodeID)
	if lineStatus != http.StatusCreated {
		t.Fatalf("kurulum: pA'ya bütçe kalemi eklenemedi: status=%d body=%v", lineStatus, lineBody)
	}
	lineID := lineBody["id"].(string)

	// pB'nin (offer dönüşümünde otomatik oluşan) bütçesi de baseline
	// alınır -- aksi halde aşağıdaki IDOR testleri "bütçe henüz baseline
	// alınmadı" (409) hatasına takılır ve asıl test edilmek istenen "Proje
	// B, Proje A'nın kalemine ASLA erişemez" (404) sınırına HİÇ ULAŞMAZ.
	if rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pB.ID+"/budget/baseline", ownerToken, ""); rec.Code != http.StatusOK {
		t.Fatalf("kurulum: pB baseline alınamadı: status=%d body=%v", rec.Code, body)
	}

	// ---------- Finance: okuma + yönetim İZİNLİ (pA üyesi) ----------

	t.Run("1_finance_allowed_cost_control_read", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/cost-control", finToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (finance, pA üyesi, cost_control.read izni var)", rec.Code)
		}
	})

	t.Run("2_finance_allowed_budget_manage", func(t *testing.T) {
		status, body := createBudgetLine(t, pA.ID, finToken, costCodeID)
		if status != http.StatusCreated {
			t.Errorf("status = %d, want 201 (finance, budget.manage izni var), body=%v", status, body)
		}
	})

	t.Run("3_finance_allowed_manual_commitment_create", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/commitments", finToken,
			`{"cost_code_id":"`+costCodeID+`","budget_line_id":"`+lineID+`","description":"Manuel Taahhüt","committed_amount":5000,"committed_at":"2026-01-15"}`)
		if rec.Code != http.StatusCreated {
			t.Errorf("status = %d, want 201 (finance, cost_control.manage izni var), body=%v", rec.Code, body)
		}
	})

	// ---------- Field: finans/maliyet görünürlüğü YOK (spec §7) ----------

	t.Run("4_field_denied_budget_read", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/budget", fieldToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (field'ın budget.read izni yok)", rec.Code)
		}
		if body["code"] != "permission_denied" {
			t.Errorf("code = %v, want permission_denied", body["code"])
		}
	})

	t.Run("5_field_denied_cost_control_summary", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/cost-control", fieldToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (field'ın cost_control.read izni yok)", rec.Code)
		}
	})

	t.Run("6_field_denied_organization_cost_codes", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/organization/cost-codes", fieldToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (field'ın organization.cost_codes.read izni yok)", rec.Code)
		}
	})

	// ---------- Project Manager: READ-ONLY (business decision, spec §11) ----------

	t.Run("7_project_manager_read_allowed", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/budget", pmToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (pm'nin budget.read izni var)", rec.Code)
		}
	})

	t.Run("8_project_manager_manage_denied", func(t *testing.T) {
		status, body := createBudgetLine(t, pA.ID, pmToken, costCodeID)
		if status != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (pm'nin budget.manage izni YOK -- iş kararı, spec §11), body=%v", status, body)
		}
	})

	t.Run("9_project_manager_baseline_denied", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/budget/baseline", pmToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (pm baseline alamamalı, budget.manage gerektirir)", rec.Code)
		}
	})

	// ---------- Üyelik farkındalığı: aynı role, farklı proje ----------

	t.Run("10_finance_non_member_denied_on_pB", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pB.ID+"/cost-control", finToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (finance, pB üyesi DEĞİL)", rec.Code)
		}
		if body["code"] != "project_access_denied" {
			t.Errorf("code = %v, want project_access_denied", body["code"])
		}
	})

	t.Run("11_owner_bypasses_membership_on_pB", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pB.ID+"/cost-control", ownerToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (owner, üyelikten MUAF)", rec.Code)
		}
	})

	// ---------- Cross-project IDOR: spec §16'nın somut senaryosu ----------
	// "Project A auth + Project B budget_line UUID -> DENIED"

	t.Run("12_cross_project_budget_line_adjustment_denied", func(t *testing.T) {
		// finance, pA'ya ÜYE (yukarıda eklendi) ama pB'ye DEĞİL -- pB'nin
		// URL'si üzerinden pA'nın (lineID) bütçe kalemine bir REVİZYON
		// oluşturma denemesi hem proje-üyeliği hem IDOR sınırını test eder.
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pB.ID+"/budget/adjustments", finToken,
			`{"budget_line_id":"`+lineID+`","amount":1000,"reason":"IDOR denemesi"}`)
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (finance pB üyesi değil -- membership katmanı ZATEN engeller), body=%v", rec.Code, body)
		}
	})

	t.Run("13_cross_project_budget_line_adjustment_denied_even_for_owner", func(t *testing.T) {
		// Owner TÜM projelere erişebilir (üyelikten muaf) -- ama pB'nin
		// URL'si üzerinden pA'nın bütçe kalemine erişim YİNE DE reddedilmeli
		// (bkz. resolveBudgetLineRef: organization_id+project_id sorgu
		// seviyesinde filtrelenir, membership bypass'ı bunu ETKİLEMEZ).
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pB.ID+"/budget/adjustments", ownerToken,
			`{"budget_line_id":"`+lineID+`","amount":1000,"reason":"IDOR denemesi (owner)"}`)
		if rec.Code != http.StatusNotFound {
			t.Errorf("status = %d, want 404 (pB'nin KENDİ bütçe kalemi yok, pA'nınki asla kabul edilmemeli), body=%v", rec.Code, body)
		}
	})

	t.Run("14_cross_project_commitment_budget_line_denied_for_owner", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pB.ID+"/commitments", ownerToken,
			`{"cost_code_id":"`+costCodeID+`","budget_line_id":"`+lineID+`","description":"IDOR","committed_amount":100,"committed_at":"2026-01-15"}`)
		if rec.Code != http.StatusNotFound {
			t.Errorf("status = %d, want 404 (Proje B, Proje A'nın bütçe kalemine ASLA bağlanamamalı), body=%v", rec.Code, body)
		}
	})

	t.Run("15_cross_project_expense_budget_line_denied_for_owner", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pB.ID+"/expenses", ownerToken,
			`{"category":"material","description":"IDOR masraf","amount":100,"expense_date":"2026-01-15","budget_line_id":"`+lineID+`"}`)
		if rec.Code != http.StatusNotFound && rec.Code != http.StatusBadRequest {
			t.Errorf("status = %d, want 404/400 (Proje B'nin masrafı, Proje A'nın bütçe kalemine ASLA bağlanamamalı), body=%v", rec.Code, body)
		}
	})

	t.Run("16_cross_tenant_wbs_parent_denied", func(t *testing.T) {
		// pB'de, pA'nın bütçe kaleminin wbs_node_id'sini (burada yok, ama
		// AYNI sınıf) değil -- doğrudan pA'da oluşturulmuş bir WBS kökünü
		// pB'nin YENİ bir WBS düğümüne parent olarak vermeyi dener.
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/wbs", ownerToken, `{"code":"900","name":"IDOR Kök"}`)
		if rec.Code != http.StatusCreated {
			t.Fatalf("kurulum: pA'da WBS kökü oluşturulamadı: status=%d body=%v", rec.Code, body)
		}
		rootID, _ := body["id"].(string)
		rec2, body2 := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pB.ID+"/wbs", ownerToken,
			`{"parent_id":"`+rootID+`","code":"901","name":"IDOR Çocuk"}`)
		if rec2.Code != http.StatusBadRequest {
			t.Errorf("status = %d, want 400 (pB'nin YENİ düğümü, pA'nın WBS kökünü parent alamamalı), body=%v", rec2.Code, body2)
		}
	})

	// ---------- Sanity: geçersiz JSON gövdesi 500 üretmemeli ----------

	t.Run("17_malformed_body_returns_400_not_500", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/budget/lines", ownerToken, "{not-json")
		if rec.Code != http.StatusBadRequest {
			t.Errorf("status = %d, want 400", rec.Code)
		}
	})
}
