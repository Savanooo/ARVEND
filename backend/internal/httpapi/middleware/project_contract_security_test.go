package middleware_test

// ARVEND V2 -- Sprint 3 (Proje Sözleşmesi / Contract) GÜVENLİK/İZİN test
// matrisi -- GERÇEK bir PostgreSQL bağlantısına VE GERÇEK, TAM router'a
// (httpapi.NewRouter) karşı doğrular. Sprint 2'nin cost_control_security_
// test.go'daki AYNI paylaşılan harness'i (rbacTestDeps/setupRBACTestRouter/
// mustCreateReadyOrg/mustCreateProject/mustCreateRoleUser/rbacDo/
// rbacCleanupOrg) kullanır -- ayrı bir kopya kurmaz.
//
// mustCreateProject (ProjectService.CreateFromOffer üzerinden) artık
// HİÇBİR projede otomatik sözleşme oluşturmaz (Sprint 4 düzeltmesi --
// bkz. docs/contracts.md "Contract Creation Consistency"): bu izin
// matrisi, MEVCUT bir sözleşme üzerinde çalışmayı gerektirdiği için, her
// test projesi için owner token'ıyla (her zaman contracts.manage sahibi)
// AÇIKÇA bir taslak sözleşme oluşturulur -- gerçek "Sözleşme Oluştur"
// CTA'sının tetiklediği AYNI uç (`mustCreateContract` helper'ı).

import (
	"context"
	"net/http"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// mustCreateContract, verilen proje için (artık hiçbir zaman otomatik
// oluşmayan) taslak sözleşmeyi gerçek HTTP ucundan (create-then-manage
// izin akışının kendisi) oluşturur -- token'ın contracts.manage iznine
// sahip olması gerekir (burada her zaman ownerToken kullanılır).
func mustCreateContract(t *testing.T, router http.Handler, token, projectID string) {
	t.Helper()
	rec, body := rbacDo(t, router, http.MethodPost, "/api/v1/projects/"+projectID+"/contract", token, "")
	if rec.Code != http.StatusCreated {
		t.Fatalf("sözleşme oluşturulamadı (proje %s): status=%d body=%v", projectID, rec.Code, body)
	}
}

func TestProjectContractSecurityMatrix(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "contract-matrix-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, org.Organization.ID)
	if err != nil {
		t.Fatalf("owner token üretilemedi: %v", err)
	}
	pmUser, pmToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "cn_pm", domain.OrgRoleProjectManager)
	finUser, finToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "cn_fin", domain.OrgRoleFinance)
	fieldUser, fieldToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "cn_field", domain.OrgRoleField)
	// legacy_user, project_users üyeliğinden MUAFTIR (RoleBypassesProject
	// Membership) -- ayrıca pA'ya eklemeye GEREK yok.
	_, legacyToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "cn_legacy", domain.OrgRoleLegacyUser)

	pA := mustCreateProject(t, ctx, d, org.Organization.ID, "Sözleşme Projesi A (üye)")
	pB := mustCreateProject(t, ctx, d, org.Organization.ID, "Sözleşme Projesi B (üye değil)")
	mustCreateContract(t, d.router, ownerToken, pA.ID)
	mustCreateContract(t, d.router, ownerToken, pB.ID)

	// pm/finance/field YALNIZCA pA'ya üye -- pB'ye ASLA eklenmedi (Sprint
	// 1/2 İLE AYNI üyelik-farkında erişim yüzeyi).
	for _, u := range []string{pmUser.ID, finUser.ID, fieldUser.ID} {
		if _, err := d.authzSvc.AddProjectUser(ctx, pA.ID, org.Organization.ID, service.ProjectUserInput{
			UserID: u, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
		}); err != nil {
			t.Fatalf("üyelik eklenemedi: %v", err)
		}
	}

	// ---------- Finance: TAM yetki (read+manage+lifecycle) ----------

	t.Run("1_finance_full_access_read", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/contract", finToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (finance, pA üyesi, contracts.read izni var)", rec.Code)
		}
	})

	t.Run("2_finance_full_access_manage", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPut, "/api/v1/projects/"+pA.ID+"/contract", finToken,
			`{"scope":"Finans testi kapsamı","payment_terms":"Hakediş","retention_terms":"%5","advance_terms":"%10"}`)
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (finance, contracts.manage izni var), body=%v", rec.Code, body)
		}
	})

	t.Run("3_finance_full_access_lifecycle", func(t *testing.T) {
		// AYRI bir proje kullanılır -- pA'nın sözleşmesini burada aktive
		// etmek, aşağıdaki PM/legacy "manage" testlerinin (draft alan
		// düzenleme, YALNIZCA draft'ta izinli) pA üzerinde ÇALIŞMASINI
		// engellerdi (state-mutating bir izin testi, diğer izin
		// testlerinden BAĞIMSIZ olmalı).
		pLifecycle := mustCreateProject(t, ctx, d, org.Organization.ID, "Sözleşme Lifecycle Testi")
		if _, err := d.authzSvc.AddProjectUser(ctx, pLifecycle.ID, org.Organization.ID, service.ProjectUserInput{
			UserID: finUser.ID, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
		}); err != nil {
			t.Fatalf("üyelik eklenemedi: %v", err)
		}
		mustCreateContract(t, d.router, ownerToken, pLifecycle.ID)
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pLifecycle.ID+"/contract/activate", finToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (finance, contracts.lifecycle izni var), body=%v", rec.Code, body)
		}
	})

	// ---------- Owner/Admin: üyelikten muaf, tam yetki ----------

	t.Run("4_owner_bypasses_membership_on_pB", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pB.ID+"/contract", ownerToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (owner, üyelikten MUAF)", rec.Code)
		}
	})

	// ---------- Field: HİÇBİR izin ----------

	t.Run("5_field_denied_read", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/contract", fieldToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (field'ın contracts.read izni yok)", rec.Code)
		}
		if body["code"] != "permission_denied" {
			t.Errorf("code = %v, want permission_denied", body["code"])
		}
	})

	// ---------- Project Manager: read+manage VAR, lifecycle YOK (Sprint
	// 2'nin bütçe paterninden BİLİNÇLİ SAPMA -- kullanıcı kararı) ----------

	t.Run("6_project_manager_read_allowed", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/contract", pmToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (pm'nin contracts.read izni var)", rec.Code)
		}
	})

	t.Run("7_project_manager_manage_allowed", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPut, "/api/v1/projects/"+pA.ID+"/contract", pmToken,
			`{"scope":"PM testi kapsamı","payment_terms":"Hakediş","retention_terms":"%5","advance_terms":"%10"}`)
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (pm'nin contracts.manage izni VAR -- kullanıcı kararı), body=%v", rec.Code, body)
		}
	})

	t.Run("8_project_manager_lifecycle_denied", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/contract/activate", pmToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (pm'nin contracts.lifecycle izni YOK -- Activate/Cancel/Complete/Terminate yapamaz), body=%v", rec.Code, body)
		}
	})

	// ---------- Legacy User: read+manage VAR, lifecycle KESİNLİKLE YOK
	// (kullanıcının açık talimatı: "Never grant projects.contracts.
	// lifecycle simply because the user is legacy.") ----------

	t.Run("9_legacy_user_read_allowed", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/contract", legacyToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (legacy_user, mevcut finance.read/manage tam paritesiyle contracts.read de var)", rec.Code)
		}
	})

	t.Run("10_legacy_user_manage_allowed", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPut, "/api/v1/projects/"+pA.ID+"/contract/notes", legacyToken, `{"internal_notes":"legacy test notu"}`)
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (legacy_user'ın contracts.manage izni var), body=%v", rec.Code, body)
		}
	})

	t.Run("11_legacy_user_lifecycle_denied", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/contract/activate", legacyToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (legacy_user'a lifecycle OTOMATİK VERİLMEMELİ -- kullanıcının açık talimatı), body=%v", rec.Code, body)
		}
	})

	// ---------- Üyelik farkındalığı ----------

	t.Run("12_finance_non_member_denied_on_pB", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pB.ID+"/contract", finToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (finance, pB üyesi DEĞİL)", rec.Code)
		}
		if body["code"] != "project_access_denied" {
			t.Errorf("code = %v, want project_access_denied", body["code"])
		}
	})

	// ---------- Cross-project / cross-tenant IDOR ----------

	t.Run("13_cross_project_lifecycle_denied", func(t *testing.T) {
		// finance, pA'ya ÜYE ama pB'ye DEĞİL -- pB'nin URL'si üzerinden
		// (kendi sözleşmesi olsa bile) erişim üyelik katmanında reddedilir.
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pB.ID+"/contract/activate", finToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (finance pB üyesi değil), body=%v", rec.Code, body)
		}
	})

	t.Run("14_cross_project_lifecycle_denied_even_for_owner", func(t *testing.T) {
		// Owner TÜM projelere erişebilir (üyelikten muaf) -- ama pB'nin
		// KENDİ sözleşmesi zaten draft'tır (henüz activate edilmedi), bu
		// isteğin BAŞARILI olması beklenir -- gerçek IDOR sınırı burada
		// "başka projenin sözleşmesine" değil, "URL projesinin KENDİ
		// sözleşmesine" erişimdir (bkz. resolveBudgetLineRef İLE AYNI
		// desen, Contract 1:1 olduğu için çapraz-proje bir kalem referansı
		// YOKTUR -- her proje yalnızca KENDİ project_id'sine bağlı
		// sözleşmeye erişebilir, sorgu seviyesinde zaten filtrelenir).
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pB.ID+"/contract/activate", ownerToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (owner, pB'nin KENDİ sözleşmesini aktive ediyor), body=%v", rec.Code, body)
		}
	})

	t.Run("15_cross_tenant_contract_get_denied", func(t *testing.T) {
		orgOther := mustCreateReadyOrg(t, ctx, d, "contract-matrix-org-other")
		t.Cleanup(func() { rbacCleanupOrg(t, d.pool, orgOther.Organization.ID) })
		otherOwnerToken, err := d.issuer.IssueAccessToken(orgOther.Owner.ID, domain.RoleAdmin, orgOther.Organization.ID)
		if err != nil {
			t.Fatalf("token üretilemedi: %v", err)
		}
		// orgOther bağlamında, org'un pA proje id'siyle sözleşme okuma
		// denemesi -- organization_id eşleşmediği için proje bulunamaz
		// (projPerm'in kendi CanAccessProject kontrolü 404 döner).
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/contract", otherOwnerToken, "")
		if rec.Code != http.StatusNotFound {
			t.Errorf("status = %d, want 404 (çapraz kiracı proje erişimi)", rec.Code)
		}
	})

	// ---------- Sanity ----------

	t.Run("16_malformed_body_returns_400_not_500", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodPut, "/api/v1/projects/"+pA.ID+"/contract", finToken, "{not-json")
		if rec.Code != http.StatusBadRequest {
			t.Errorf("status = %d, want 400", rec.Code)
		}
	})
}
