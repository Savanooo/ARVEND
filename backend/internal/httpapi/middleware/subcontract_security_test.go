package middleware_test

// ARVEND V2 -- Sprint 5 (Taşeron Yönetimi) GÜVENLİK/İZİN test matrisi --
// GERÇEK bir PostgreSQL bağlantısına VE GERÇEK, TAM router'a
// (httpapi.NewRouter) karşı doğrular. procurement_security_test.go İLE
// AYNI paylaşılan harness'i kullanır.
//
// Rol matrisi (migration 0038'in kendi gerekçesiyle AYNI):
//
//	finance:          subcontracts.read+manage+approve, subcontract_claims.read+manage+certify (TAM)
//	project_manager:  subcontracts.read+manage (approve YOK -- KRİTİK), subcontract_claims.read+manage (certify YOK -- KRİTİK)
//	legacy_user:      AYNI (approve/certify YOK -- KRİTİK)
//	field:            HİÇBİRİ
//	owner/admin:      üyelikten muaf, TAM yetki

import (
	"context"
	"net/http"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestSubcontractSecurityMatrix(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "subcontract-matrix-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, org.Organization.ID)
	if err != nil {
		t.Fatalf("owner token üretilemedi: %v", err)
	}
	pmUser, pmToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "sc_pm", domain.OrgRoleProjectManager)
	finUser, finToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "sc_fin", domain.OrgRoleFinance)
	fieldUser, fieldToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "sc_field", domain.OrgRoleField)
	_, legacyToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "sc_legacy", domain.OrgRoleLegacyUser)

	pA := mustCreateProject(t, ctx, d, org.Organization.ID, "Taşeron Projesi A (üye)")
	pB := mustCreateProject(t, ctx, d, org.Organization.ID, "Taşeron Projesi B (üye değil)")
	for _, u := range []string{pmUser.ID, finUser.ID, fieldUser.ID} {
		if _, err := d.authzSvc.AddProjectUser(ctx, pA.ID, org.Organization.ID, service.ProjectUserInput{
			UserID: u, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
		}); err != nil {
			t.Fatalf("üyelik eklenemedi: %v", err)
		}
	}

	cc, err := d.costCodeSvc.Create(ctx, org.Organization.ID, service.CostCodeInput{Code: "SEC-SC-CC", Name: "Güvenlik Testi"})
	if err != nil {
		t.Fatalf("maliyet kodu oluşturulamadı: %v", err)
	}
	supplierA, err := d.supplierSvc.Create(ctx, org.Organization.ID, service.SupplierInput{Code: "SEC-SC-S", LegalName: "Güvenlik Taşeronu"})
	if err != nil {
		t.Fatalf("tedarikçi oluşturulamadı: %v", err)
	}

	scBody := `{"supplier_id":"` + supplierA.ID + `","title":"Güvenlik Testi Sözleşmesi","items":[{"cost_code_id":"` + cc.ID + `","description":"K","original_amount":10000}]}`

	// ---------- Yetki matrisi ----------

	t.Run("1_finance_subcontracts_read", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/subcontracts", finToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (finance subcontracts.read)", rec.Code)
		}
	})

	t.Run("2_finance_subcontracts_manage_allowed", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts", finToken, scBody)
		if rec.Code != http.StatusCreated {
			t.Errorf("status = %d, want 201 (finance subcontracts.manage), body=%v", rec.Code, body)
		}
	})

	t.Run("3_finance_subcontracts_approve_allowed", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts", finToken, scBody)
		if rec.Code != http.StatusCreated {
			t.Fatalf("oluşturulamadı: %d %v", rec.Code, body)
		}
		scID, _ := body["id"].(string)
		rec2, body2 := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts/"+scID+"/activate", finToken, "")
		if rec2.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (finance subcontracts.approve), body=%v", rec2.Code, body2)
		}
	})

	t.Run("4_pm_subcontracts_manage_allowed_approve_denied", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts", pmToken, scBody)
		if rec.Code != http.StatusCreated {
			t.Fatalf("PM taslak oluşturabilmeli: %d %v", rec.Code, body)
		}
		scID, _ := body["id"].(string)
		// KRİTİK: PM manage alır (taslak oluşturabilir) ama approve ALMAZ
		// (Contract'taki "manage ≠ lifecycle" ilkesinin AYNISI).
		rec2, body2 := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts/"+scID+"/activate", pmToken, "")
		if rec2.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (PM'nin subcontracts.approve izni YOK), body=%v", rec2.Code, body2)
		}
	})

	t.Run("5_legacy_subcontracts_manage_allowed_approve_denied", func(t *testing.T) {
		// KRİTİK: legacy_user'a YENİ eylem sınıfı (approve) OTOMATİK
		// VERİLMEZ -- Contract/Procurement'taki BİREBİR AYNI karar.
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts", legacyToken, scBody)
		if rec.Code != http.StatusCreated {
			t.Fatalf("legacy taslak oluşturabilmeli: %d %v", rec.Code, body)
		}
		scID, _ := body["id"].(string)
		rec2, body2 := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts/"+scID+"/activate", legacyToken, "")
		if rec2.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (legacy'nin subcontracts.approve izni YOK), body=%v", rec2.Code, body2)
		}
	})

	t.Run("6_field_subcontracts_denied", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/subcontracts", fieldToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (field'ın subcontracts izni YOK), body=%v", rec.Code, body)
		}
	})

	t.Run("7_finance_non_member_denied_on_pB", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pB.ID+"/subcontracts", finToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (finance pB üyesi DEĞİL), body=%v", rec.Code, body)
		}
	})

	t.Run("8_owner_bypasses_membership", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pB.ID+"/subcontracts", ownerToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (owner üyelikten muaf), body=%v", rec.Code, body)
		}
	})

	// ---------- Progress Claim (Hakediş) izinleri ----------

	t.Run("9_pm_claims_manage_allowed_certify_denied", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts", finToken, scBody)
		if rec.Code != http.StatusCreated {
			t.Fatalf("oluşturulamadı: %d %v", rec.Code, body)
		}
		scID, _ := body["id"].(string)
		if rec2, b2 := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts/"+scID+"/activate", finToken, ""); rec2.Code != http.StatusOK {
			t.Fatalf("aktifleştirilemedi: %d %v", rec2.Code, b2)
		}
		itemsRec, itemsBody := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/subcontracts/"+scID, finToken, "")
		if itemsRec.Code != http.StatusOK {
			t.Fatalf("detay alınamadı: %d %v", itemsRec.Code, itemsBody)
		}
		items, _ := itemsBody["items"].([]any)
		if len(items) == 0 {
			t.Fatalf("SOV kalemi bulunamadı: %v", itemsBody)
		}
		itemID, _ := items[0].(map[string]any)["id"].(string)

		claimBody := `{"period_end":"2026-01-31","items":[{"subcontract_item_id":"` + itemID + `","current_progress_amount":1000}]}`
		claimRec, claimBodyResp := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts/"+scID+"/progress-claims", pmToken, claimBody)
		if claimRec.Code != http.StatusCreated {
			t.Fatalf("PM hakediş taslağı oluşturabilmeli: %d %v", claimRec.Code, claimBodyResp)
		}
		claimID, _ := claimBodyResp["id"].(string)
		if rec2, b2 := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontract-progress-claims/"+claimID+"/submit", pmToken, ""); rec2.Code != http.StatusOK {
			t.Fatalf("gönderilemedi: %d %v", rec2.Code, b2)
		}
		// KRİTİK: PM/legacy hakedişi SERTİFİKA EDEMEZ.
		rec3, body3 := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontract-progress-claims/"+claimID+"/certify", pmToken, "")
		if rec3.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (PM'nin subcontract_claims.certify izni YOK), body=%v", rec3.Code, body3)
		}
		// finance sertifika EDEBİLİR.
		rec4, body4 := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontract-progress-claims/"+claimID+"/certify", finToken, "")
		if rec4.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (finance subcontract_claims.certify), body=%v", rec4.Code, body4)
		}
	})

	t.Run("10_field_claims_denied", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/subcontracts/00000000-0000-0000-0000-000000000000/progress-claims", fieldToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (field'ın subcontract_claims izni YOK), body=%v", rec.Code, body)
		}
	})

	// ---------- IDOR (spec §24, §36) ----------

	t.Run("11_subcontract_cross_project_idor_denied", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts", finToken, scBody)
		if rec.Code != http.StatusCreated {
			t.Fatalf("oluşturulamadı: %d %v", rec.Code, body)
		}
		scID, _ := body["id"].(string)
		rec2, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pB.ID+"/subcontracts/"+scID, ownerToken, "")
		if rec2.Code != http.StatusNotFound {
			t.Errorf("status = %d, want 404 (çapraz proje subcontract erişimi), owner dahi başka projenin sözleşmesini KENDİ projesi üzerinden GÖREMEMELİ", rec2.Code)
		}
	})

	t.Run("12_change_order_cross_project_idor_denied", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts", finToken, scBody)
		if rec.Code != http.StatusCreated {
			t.Fatalf("oluşturulamadı: %d %v", rec.Code, body)
		}
		scID, _ := body["id"].(string)
		if rec2, b2 := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts/"+scID+"/activate", finToken, ""); rec2.Code != http.StatusOK {
			t.Fatalf("aktifleştirilemedi: %d %v", rec2.Code, b2)
		}
		coBody := `{"title":"IDOR Testi","change_type":"addition","items":[{"cost_code_id":"` + cc.ID + `","description":"K","amount":500}]}`
		coRec, coBodyResp := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts/"+scID+"/change-orders", finToken, coBody)
		if coRec.Code != http.StatusCreated {
			t.Fatalf("değişiklik oluşturulamadı: %d %v", coRec.Code, coBodyResp)
		}
		coID, _ := coBodyResp["id"].(string)
		rec3, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pB.ID+"/subcontract-change-orders/"+coID, ownerToken, "")
		if rec3.Code != http.StatusNotFound {
			t.Errorf("status = %d, want 404 (çapraz proje değişiklik erişimi)", rec3.Code)
		}
	})

	t.Run("13_claim_cross_project_idor_denied", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts", finToken, scBody)
		if rec.Code != http.StatusCreated {
			t.Fatalf("oluşturulamadı: %d %v", rec.Code, body)
		}
		scID, _ := body["id"].(string)
		if rec2, b2 := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts/"+scID+"/activate", finToken, ""); rec2.Code != http.StatusOK {
			t.Fatalf("aktifleştirilemedi: %d %v", rec2.Code, b2)
		}
		itemsRec, itemsBody := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/subcontracts/"+scID, finToken, "")
		if itemsRec.Code != http.StatusOK {
			t.Fatalf("detay alınamadı: %d %v", itemsRec.Code, itemsBody)
		}
		items, _ := itemsBody["items"].([]any)
		itemID, _ := items[0].(map[string]any)["id"].(string)
		claimBody := `{"period_end":"2026-01-31","items":[{"subcontract_item_id":"` + itemID + `","current_progress_amount":500}]}`
		claimRec, claimBodyResp := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts/"+scID+"/progress-claims", finToken, claimBody)
		if claimRec.Code != http.StatusCreated {
			t.Fatalf("hakediş oluşturulamadı: %d %v", claimRec.Code, claimBodyResp)
		}
		claimID, _ := claimBodyResp["id"].(string)
		rec2, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pB.ID+"/subcontract-progress-claims/"+claimID, ownerToken, "")
		if rec2.Code != http.StatusNotFound {
			t.Errorf("status = %d, want 404 (çapraz proje hakediş erişimi)", rec2.Code)
		}
	})

	t.Run("14_malformed_body_returns_400_not_500", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/subcontracts", finToken, "{not-json")
		if rec.Code != http.StatusBadRequest {
			t.Errorf("status = %d, want 400", rec.Code)
		}
	})
}
