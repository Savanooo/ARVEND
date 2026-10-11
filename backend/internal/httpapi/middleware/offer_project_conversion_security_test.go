package middleware_test

// POST /projects/from-offer/{offerId} idempotenttir: teklif zaten bir
// projeye dönüştürülmüşse mevcut proje döner. Yanıt projenin kendisi (iç
// notlar, finans izniyle sözleşme bedeli) olduğu için bu dönüş
// GET /offers/{id}/project ile aynı kapıdan geçer: projects.read VE proje
// erişimi. Eskiden projects.create izni olan herkes üyesi olmadığı projeyi
// bu uçtan okuyabiliyordu. Gerçek router + gerçek DB.

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestCreateFromOfferIdempotentReturnChecksProjectAccess(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "offer-convert-access-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	orgID := org.Organization.ID

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatalf("owner token üretilemedi: %v", err)
	}
	outsider, outsiderToken := mustCreateRoleUser(t, ctx, d, orgID, "oca_outsider", domain.OrgRoleField)
	member, memberToken := mustCreateRoleUser(t, ctx, d, orgID, "oca_member", domain.OrgRoleField)
	// Saha rolüne kişiye özel proje açma + teklif okuma: üyelik kuralına
	// tabi (sahip/yönetici gibi tüm projeleri görmez).
	for _, u := range []string{outsider.ID, member.ID} {
		detail, err := d.authzSvc.GetUserPermissionDetail(ctx, u, orgID)
		if err != nil {
			t.Fatal(err)
		}
		perms := append(detail.RolePermissions, domain.PermProjectsCreate, domain.PermProjectsRead, domain.PermOffersRead)
		if _, err := d.authzSvc.SetUserPermissions(ctx, u, orgID, org.Owner.ID, perms); err != nil {
			t.Fatalf("izin ayarlanamadı: %v", err)
		}
	}

	p := mustCreateProject(t, ctx, d, orgID, "Dönüştürülmüş Proje")
	if _, err := d.pool.Exec(ctx, "UPDATE projects SET internal_notes = 'GIZLI-NOT-42' WHERE id = $1", p.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := d.authzSvc.AddProjectUser(ctx, p.ID, orgID, service.ProjectUserInput{
		UserID: member.ID, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
	}); err != nil {
		t.Fatalf("üyelik eklenemedi: %v", err)
	}
	convert := "/api/v1/projects/from-offer/" + p.SourceOfferID

	t.Run("outsider_gets_409_without_project_data", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, convert, outsiderToken, `{"name":"Tekrar"}`)
		if rec.Code != http.StatusConflict {
			t.Fatalf("status = %d, want 409; body=%s", rec.Code, rec.Body.String())
		}
		if body["code"] != "offer_already_converted" {
			t.Errorf("code = %v, want offer_already_converted", body["code"])
		}
		for _, leak := range []string{p.ID, p.ProjectNo, "GIZLI-NOT-42"} {
			if strings.Contains(rec.Body.String(), leak) {
				t.Errorf("erişimi olmayana proje bilgisi sızdı (%s): %s", leak, rec.Body.String())
			}
		}
		// Mobilin "dönüştürülmüş ama göremiyorsun" kararı bu koda bakar.
		rec, body = rbacDo(t, d.router, http.MethodGet, "/api/v1/offers/"+p.SourceOfferID+"/project", outsiderToken, "")
		if rec.Code != http.StatusForbidden || body["code"] != "project_access_denied" {
			t.Errorf("GET /offers/{id}/project = %d %v, want 403 project_access_denied", rec.Code, body["code"])
		}
	})

	t.Run("member_gets_existing_project_200", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, convert, memberToken, `{"name":"Tekrar"}`)
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
		}
		if body["id"] != p.ID {
			t.Errorf("mevcut proje dönmeli: %v", body["id"])
		}
	})

	t.Run("owner_gets_existing_project_200", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, convert, ownerToken, `{}`)
		if rec.Code != http.StatusOK || body["id"] != p.ID {
			t.Fatalf("status = %d id=%v, want 200 %s", rec.Code, body["id"], p.ID)
		}
	})

	t.Run("new_conversion_is_201", func(t *testing.T) {
		offerID := mustAcceptedOfferForFinanceTest(t, ctx, d, orgID)
		rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/from-offer/"+offerID, outsiderToken, `{"name":"Yeni Proje"}`)
		if rec.Code != http.StatusCreated {
			t.Fatalf("status = %d, want 201; body=%s", rec.Code, rec.Body.String())
		}
		if body["id"] == nil || body["id"] == p.ID {
			t.Errorf("yeni proje dönmeli: %v", body["id"])
		}
	})
}
