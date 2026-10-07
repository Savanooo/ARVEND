package middleware_test

// Ek işte müşteri kararını personelin kaydetmesi (ürün kararı 2026-10-07,
// migration 0063) -- GERÇEK router + PostgreSQL üzerinde: record-decision
// projects.change_orders.approve ister (finance.manage YETMEZ); etki
// paylaşım linkiyle aynıdır (güncel proje bedeli), kim/not kaydedilir.
// Paylaşılan harness: require_permission_test.go.

import (
	"context"
	"net/http"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestChangeOrderDecisionSecurityMatrix(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "co-decision-matrix-org")
	orgID := org.Organization.ID
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, orgID) })

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatalf("owner token üretilemedi: %v", err)
	}
	finUser, finToken := mustCreateRoleUser(t, ctx, d, orgID, "cd_fin", domain.OrgRoleFinance)
	pmUser, pmToken := mustCreateRoleUser(t, ctx, d, orgID, "cd_pm", domain.OrgRoleProjectManager)
	adminUser, adminToken := mustCreateRoleUser(t, ctx, d, orgID, "cd_admin", domain.OrgRoleAdmin)

	p := mustCreateProject(t, ctx, d, orgID, "Ek İş Karar Matrisi Projesi")
	for _, u := range []string{finUser.ID, pmUser.ID} {
		if _, err := d.authzSvc.AddProjectUser(ctx, p.ID, orgID, service.ProjectUserInput{
			UserID: u, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
		}); err != nil {
			t.Fatalf("üyelik eklenemedi: %v", err)
		}
	}
	base := "/api/v1/projects/" + p.ID

	// ---------- Ek iş: müşteri kararını personel kaydeder ----------

	createSentCO := func(t *testing.T, send bool) string {
		t.Helper()
		rec, body := rbacDo(t, d.router, http.MethodPost, base+"/change-orders", ownerToken,
			`{"change_type":"addition","title":"Telefon onaylı ek iş","vat_rate":0,"items":[{"description":"Kalem","quantity":1,"unit":"adet","unit_price":2500}]}`)
		if rec.Code != http.StatusCreated {
			t.Fatalf("ek iş oluşturulamadı: %d %v", rec.Code, body)
		}
		id := body["id"].(string)
		if send {
			if rec, body := rbacDo(t, d.router, http.MethodPost, base+"/change-orders/"+id+"/send", ownerToken, ""); rec.Code != http.StatusOK {
				t.Fatalf("ek iş gönderilemedi: %d %v", rec.Code, body)
			}
		}
		return id
	}
	contractValue := func(t *testing.T) float64 {
		t.Helper()
		rec, body := rbacDo(t, d.router, http.MethodGet, base+"/financial-summary", ownerToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("finans özeti alınamadı: %d", rec.Code)
		}
		v, _ := body["current_contract_value"].(float64)
		return v
	}
	sentCO := createSentCO(t, true)
	decide := func(token, coID, json string) (*http.Response, map[string]any) {
		rec, body := rbacDo(t, d.router, http.MethodPost, base+"/change-orders/"+coID+"/record-decision", token, json)
		return rec.Result(), body
	}

	t.Run("co_1_finance_manage_is_not_enough", func(t *testing.T) {
		res, body := decide(finToken, sentCO, `{"decision":"approved"}`)
		if res.StatusCode != http.StatusForbidden || body["code"] != "permission_denied" {
			t.Errorf("status=%d code=%v, beklenen 403 (finans change_orders.approve taşımaz)", res.StatusCode, body["code"])
		}
	})

	t.Run("co_2_project_manager_denied", func(t *testing.T) {
		res, _ := decide(pmToken, sentCO, `{"decision":"approved"}`)
		if res.StatusCode != http.StatusForbidden {
			t.Errorf("status=%d, beklenen 403", res.StatusCode)
		}
	})

	t.Run("co_3_admin_records_customer_approval", func(t *testing.T) {
		before := contractValue(t)
		res, body := decide(adminToken, sentCO, `{"decision":"approved","note":"  telefonla onay  "}`)
		if res.StatusCode != http.StatusOK {
			t.Fatalf("status=%d body=%v, beklenen 200", res.StatusCode, body)
		}
		if body["status"] != domain.ChangeOrderApproved || body["decision_recorded_by"] != adminUser.ID ||
			body["decision_note"] != "telefonla onay" || body["decision_recorded_by_name"] != "cd_admin" {
			t.Errorf("karar kaydı eksik: %v", body)
		}
		if after := contractValue(t); after != before+2500 {
			t.Errorf("güncel proje bedeli %v -> %v, beklenen +2500 (link onayıyla aynı etki)", before, after)
		}
		rec, detail := rbacDo(t, d.router, http.MethodGet, base+"/change-orders/"+sentCO, finToken, "")
		if rec.Code != http.StatusOK || detail["decision_recorded_by_name"] != "cd_admin" {
			t.Errorf("detay kimin işaretlediğini göstermeli: %d %v", rec.Code, detail)
		}
	})

	t.Run("co_4_second_decision_conflicts", func(t *testing.T) {
		res, body := decide(ownerToken, sentCO, `{"decision":"rejected"}`)
		if res.StatusCode != http.StatusConflict {
			t.Errorf("status=%d body=%v, beklenen 409 (karar zaten verildi)", res.StatusCode, body)
		}
	})

	t.Run("co_5_draft_cannot_be_decided", func(t *testing.T) {
		draft := createSentCO(t, false)
		res, _ := decide(ownerToken, draft, `{"decision":"approved"}`)
		if res.StatusCode != http.StatusConflict {
			t.Errorf("status=%d, beklenen 409 (yalnızca gönderilmiş ek iş)", res.StatusCode)
		}
	})

	t.Run("co_6_invalid_decision_rejected", func(t *testing.T) {
		co := createSentCO(t, true)
		res, _ := decide(ownerToken, co, `{"decision":"maybe"}`)
		if res.StatusCode != http.StatusBadRequest {
			t.Errorf("status=%d, beklenen 400", res.StatusCode)
		}
	})
}
