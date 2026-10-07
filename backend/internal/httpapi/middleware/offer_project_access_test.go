package middleware_test

import (
	"context"
	"net/http"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// TestOfferProjectLookupRequiresProjectAccess: GET /offers/{id}/project
// projenin kendisini (sözleşme bedeli, iç notlar) döner. Eskiden yalnızca
// offers.read isteniyordu -- kişiye özel offers.read verilmiş bir proje
// müdürü, üyesi olmadığı projelerin bu bilgilerini okuyabiliyordu. Artık
// /projects/{id} ile aynı kapı: projects.read + proje erişimi.
func TestOfferProjectLookupRequiresProjectAccess(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "offer-project-access-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	orgID := org.Organization.ID

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatalf("owner token üretilemedi: %v", err)
	}
	pmUser, pmToken := mustCreateRoleUser(t, ctx, d, orgID, "opa_pm", domain.OrgRoleProjectManager)
	fieldUser, fieldToken := mustCreateRoleUser(t, ctx, d, orgID, "opa_field", domain.OrgRoleField)

	member := mustCreateProject(t, ctx, d, orgID, "Üye Olunan Proje")
	other := mustCreateProject(t, ctx, d, orgID, "Üye Olunmayan Proje")
	if _, err := d.authzSvc.AddProjectUser(ctx, member.ID, orgID, service.ProjectUserInput{
		UserID: pmUser.ID, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
	}); err != nil {
		t.Fatalf("üyelik eklenemedi: %v", err)
	}

	// pm'e kişiye özel offers.read; field'a offers.read verip projects.read
	// geri alınır.
	grant := func(userID string, add []string, remove string) {
		t.Helper()
		detail, err := d.authzSvc.GetUserPermissionDetail(ctx, userID, orgID)
		if err != nil {
			t.Fatal(err)
		}
		var perms []string
		for _, c := range detail.RolePermissions {
			if c != remove {
				perms = append(perms, c)
			}
		}
		if _, err := d.authzSvc.SetUserPermissions(ctx, userID, orgID, org.Owner.ID, append(perms, add...)); err != nil {
			t.Fatalf("izin ayarlanamadı: %v", err)
		}
	}
	grant(pmUser.ID, []string{domain.PermOffersRead}, "")
	grant(fieldUser.ID, []string{domain.PermOffersRead}, domain.PermProjectsRead)

	path := func(p *domain.Project) string { return "/api/v1/offers/" + p.SourceOfferID + "/project" }

	cases := []struct {
		name  string
		token string
		proj  *domain.Project
		want  int
	}{
		{"owner_bypasses_membership", ownerToken, other, http.StatusOK},
		{"pm_member_project", pmToken, member, http.StatusOK},
		{"pm_not_member_denied", pmToken, other, http.StatusForbidden},
		{"no_projects_read_denied", fieldToken, member, http.StatusForbidden},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rec, body := rbacDo(t, d.router, http.MethodGet, path(c.proj), c.token, "")
			if rec.Code != c.want {
				t.Fatalf("status = %d, want %d, body=%v", rec.Code, c.want, body)
			}
			if c.want == http.StatusForbidden {
				if _, leaked := body["contract_amount"]; leaked {
					t.Errorf("reddedilen yanıt proje verisi taşımamalı: %v", body)
				}
			} else if body["id"] != c.proj.ID {
				t.Errorf("yanlış proje döndü: %v", body)
			}
		})
	}
}
