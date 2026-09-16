package middleware_test

// ARVEND V2 -- Sprint 4 (Procurement Foundation) GÜVENLİK/İZİN test
// matrisi -- GERÇEK bir PostgreSQL bağlantısına VE GERÇEK, TAM router'a
// (httpapi.NewRouter) karşı doğrular. project_contract_security_test.go
// İLE AYNI paylaşılan harness'i kullanır.
//
// Rol matrisi (migration 0037'nin kendi gerekçesiyle AYNI):
//
//	finance:          suppliers.read+manage, procurement.read+manage+approve (TAM)
//	project_manager:  suppliers.read (manage YOK), procurement.read+manage (approve YOK -- KRİTİK)
//	legacy_user:      suppliers.read (manage YOK), procurement.read+manage (approve YOK -- KRİTİK)
//	field:            HİÇBİRİ
//	owner/admin:      üyelikten muaf, TAM yetki

import (
	"context"
	"net/http"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestProcurementSecurityMatrix(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "procurement-matrix-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, org.Organization.ID)
	if err != nil {
		t.Fatalf("owner token üretilemedi: %v", err)
	}
	pmUser, pmToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "pc_pm", domain.OrgRoleProjectManager)
	finUser, finToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "pc_fin", domain.OrgRoleFinance)
	fieldUser, fieldToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "pc_field", domain.OrgRoleField)
	_, legacyToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "pc_legacy", domain.OrgRoleLegacyUser)

	pA := mustCreateProject(t, ctx, d, org.Organization.ID, "Satınalma Projesi A (üye)")
	pB := mustCreateProject(t, ctx, d, org.Organization.ID, "Satınalma Projesi B (üye değil)")
	for _, u := range []string{pmUser.ID, finUser.ID, fieldUser.ID} {
		if _, err := d.authzSvc.AddProjectUser(ctx, pA.ID, org.Organization.ID, service.ProjectUserInput{
			UserID: u, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
		}); err != nil {
			t.Fatalf("üyelik eklenemedi: %v", err)
		}
	}

	cc, err := d.costCodeSvc.Create(ctx, org.Organization.ID, service.CostCodeInput{Code: "SEC-CC", Name: "Güvenlik Testi"})
	if err != nil {
		t.Fatalf("maliyet kodu oluşturulamadı: %v", err)
	}

	// ---------- Tedarikçiler (organizasyon-seviyesi) ----------

	t.Run("1_finance_suppliers_read", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/organization/suppliers", finToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (finance suppliers.read)", rec.Code)
		}
	})

	t.Run("2_finance_suppliers_manage_allowed", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/organization/suppliers", finToken,
			`{"code":"SEC-FIN","legal_name":"Finans Tedarikçisi"}`)
		if rec.Code != http.StatusCreated {
			t.Errorf("status = %d, want 201 (finance suppliers.manage), body=%v", rec.Code, body)
		}
	})

	t.Run("3_legacy_suppliers_read_allowed", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/organization/suppliers", legacyToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (legacy suppliers.read)", rec.Code)
		}
	})

	t.Run("4_legacy_suppliers_manage_denied", func(t *testing.T) {
		// KRİTİK: cost_codes.manage'in legacy_user'a VERİLMEDİĞİ Sprint 2
		// kararıyla BİREBİR AYNI ilke -- katalog YÖNETİMİ farklı bir yetki
		// sınıfıdır.
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/organization/suppliers", legacyToken,
			`{"code":"SEC-LEG","legal_name":"X"}`)
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (legacy'nin suppliers.manage izni YOK), body=%v", rec.Code, body)
		}
	})

	t.Run("5_pm_suppliers_read_allowed_manage_denied", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/organization/suppliers", pmToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (pm suppliers.read)", rec.Code)
		}
		rec2, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/organization/suppliers", pmToken, `{"code":"SEC-PM","legal_name":"X"}`)
		if rec2.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (pm'nin suppliers.manage izni YOK), body=%v", rec2.Code, body)
		}
	})

	t.Run("6_field_suppliers_denied", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/organization/suppliers", fieldToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (field'ın suppliers.read izni YOK), body=%v", rec.Code, body)
		}
	})

	t.Run("7_owner_suppliers_full_access", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/organization/suppliers", ownerToken, `{"code":"SEC-OWN","legal_name":"Owner Ted"}`)
		if rec.Code != http.StatusCreated {
			t.Errorf("status = %d, want 201 (owner tam yetki), body=%v", rec.Code, body)
		}
	})

	t.Run("8_supplier_cross_tenant_get_denied", func(t *testing.T) {
		s, err := d.supplierSvc.Create(ctx, org.Organization.ID, service.SupplierInput{Code: "SEC-XT", LegalName: "X"})
		if err != nil {
			t.Fatalf("tedarikçi oluşturulamadı: %v", err)
		}
		orgOther := mustCreateReadyOrg(t, ctx, d, "procurement-matrix-org-other")
		t.Cleanup(func() { rbacCleanupOrg(t, d.pool, orgOther.Organization.ID) })
		otherOwnerToken, err := d.issuer.IssueAccessToken(orgOther.Owner.ID, domain.RoleAdmin, orgOther.Organization.ID)
		if err != nil {
			t.Fatalf("token üretilemedi: %v", err)
		}
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/organization/suppliers/"+s.ID, otherOwnerToken, "")
		if rec.Code != http.StatusNotFound {
			t.Errorf("status = %d, want 404 (çapraz kiracı tedarikçi erişimi)", rec.Code)
		}
	})

	// ---------- Procurement (proje-seviyesi) ----------

	prBody := `{"title":"Güvenlik Testi Talebi","items":[{"cost_code_id":"` + cc.ID + `","description":"K","quantity":1,"estimated_total":10}]}`

	t.Run("9_finance_procurement_read", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/purchase-requests", finToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (finance procurement.read)", rec.Code)
		}
	})

	t.Run("10_finance_procurement_manage_create_pr", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/purchase-requests", finToken, prBody)
		if rec.Code != http.StatusCreated {
			t.Errorf("status = %d, want 201 (finance procurement.manage), body=%v", rec.Code, body)
		}
	})

	t.Run("11_finance_procurement_approve_full_cycle", func(t *testing.T) {
		// AYRI bir proje -- state-mutating izin testi, diğer testlerden
		// BAĞIMSIZ olmalı (Sprint 2/3'teki AYNI izolasyon ilkesi).
		pApprove := mustCreateProject(t, ctx, d, org.Organization.ID, "Onay Akışı Projesi")
		if _, err := d.authzSvc.AddProjectUser(ctx, pApprove.ID, org.Organization.ID, service.ProjectUserInput{
			UserID: finUser.ID, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
		}); err != nil {
			t.Fatalf("üyelik eklenemedi: %v", err)
		}
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pApprove.ID+"/purchase-requests", finToken, prBody)
		if rec.Code != http.StatusCreated {
			t.Fatalf("PR oluşturulamadı: %d %v", rec.Code, body)
		}
		prID, _ := body["id"].(string)
		if rec2, b2 := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pApprove.ID+"/purchase-requests/"+prID+"/submit", finToken, ""); rec2.Code != http.StatusOK {
			t.Fatalf("gönderilemedi: %d %v", rec2.Code, b2)
		}
		rec3, body3 := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pApprove.ID+"/purchase-requests/"+prID+"/approve", finToken, "")
		if rec3.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (finance procurement.approve), body=%v", rec3.Code, body3)
		}
	})

	t.Run("12_pm_procurement_manage_allowed", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/purchase-requests", pmToken, prBody)
		if rec.Code != http.StatusCreated {
			t.Errorf("status = %d, want 201 (pm'nin procurement.manage izni VAR -- kullanıcı kararı), body=%v", rec.Code, body)
		}
	})

	t.Run("13_pm_procurement_approve_denied", func(t *testing.T) {
		// KRİTİK: PM taslak oluşturabilir/gönderebilir ama ONAYLAYAMAZ --
		// Contract'taki "manage alır, lifecycle almaz" desenin AYNISI.
		pPM := mustCreateProject(t, ctx, d, org.Organization.ID, "PM Onay Reddi Projesi")
		if _, err := d.authzSvc.AddProjectUser(ctx, pPM.ID, org.Organization.ID, service.ProjectUserInput{
			UserID: pmUser.ID, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
		}); err != nil {
			t.Fatalf("üyelik eklenemedi: %v", err)
		}
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pPM.ID+"/purchase-requests", pmToken, prBody)
		if rec.Code != http.StatusCreated {
			t.Fatalf("PR oluşturulamadı: %d %v", rec.Code, body)
		}
		prID, _ := body["id"].(string)
		if rec2, b2 := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pPM.ID+"/purchase-requests/"+prID+"/submit", pmToken, ""); rec2.Code != http.StatusOK {
			t.Fatalf("gönderilemedi: %d %v", rec2.Code, b2)
		}
		rec3, body3 := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pPM.ID+"/purchase-requests/"+prID+"/approve", pmToken, "")
		if rec3.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (pm'nin procurement.approve izni YOK), body=%v", rec3.Code, body3)
		}
	})

	t.Run("14_legacy_procurement_manage_allowed", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/purchase-requests", legacyToken, prBody)
		if rec.Code != http.StatusCreated {
			t.Errorf("status = %d, want 201 (legacy procurement.manage), body=%v", rec.Code, body)
		}
	})

	t.Run("15_legacy_procurement_approve_denied", func(t *testing.T) {
		// KRİTİK: legacy_user'a YENİ eylem sınıfı (approve) OTOMATİK
		// VERİLMEZ -- Contract'taki "asla otomatik lifecycle miras alınmaz"
		// kararının AYNISI.
		pLegacy := mustCreateProject(t, ctx, d, org.Organization.ID, "Legacy Onay Reddi Projesi")
		// legacy_user RoleBypassesProjectMembership -- üyeliğe GEREK yok.
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pLegacy.ID+"/purchase-requests", legacyToken, prBody)
		if rec.Code != http.StatusCreated {
			t.Fatalf("PR oluşturulamadı: %d %v", rec.Code, body)
		}
		prID, _ := body["id"].(string)
		if rec2, b2 := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pLegacy.ID+"/purchase-requests/"+prID+"/submit", legacyToken, ""); rec2.Code != http.StatusOK {
			t.Fatalf("gönderilemedi: %d %v", rec2.Code, b2)
		}
		rec3, body3 := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pLegacy.ID+"/purchase-requests/"+prID+"/approve", legacyToken, "")
		if rec3.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (legacy'nin procurement.approve izni YOK), body=%v", rec3.Code, body3)
		}
	})

	t.Run("16_field_procurement_denied", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/purchase-requests", fieldToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (field'ın procurement izni YOK), body=%v", rec.Code, body)
		}
	})

	t.Run("17_finance_non_member_denied_on_pB", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pB.ID+"/purchase-requests", finToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (finance pB üyesi DEĞİL), body=%v", rec.Code, body)
		}
	})

	t.Run("18_pr_cross_project_idor_denied", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/purchase-requests", finToken, prBody)
		if rec.Code != http.StatusCreated {
			t.Fatalf("PR oluşturulamadı: %d %v", rec.Code, body)
		}
		prID, _ := body["id"].(string)
		// pA'nın PR'ına, pB'nin URL'si üzerinden erişim denemesi.
		rec2, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pB.ID+"/purchase-requests/"+prID, ownerToken, "")
		if rec2.Code != http.StatusNotFound {
			t.Errorf("status = %d, want 404 (çapraz proje PR erişimi), owner dahi başka projenin PR'ını KENDİ projesi üzerinden GÖREMEMELİ", rec2.Code)
		}
	})

	t.Run("19_malformed_body_returns_400_not_500", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/purchase-requests", finToken, "{not-json")
		if rec.Code != http.StatusBadRequest {
			t.Errorf("status = %d, want 400", rec.Code)
		}
	})
}
