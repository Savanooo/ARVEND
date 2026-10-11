package middleware_test

// POST /offers/{id}/toggle-passive (offers.approve): mobilin
// "Arşivle"/"Arşivden Çıkar" düğmesi `{"is_passive": bool}` gönderir --
// teklif zaten o durumdaysa değişmez. Gövdesiz istek eski davranıştır
// (tersine çevirir). Gerçek router + gerçek DB.

import (
	"context"
	"net/http"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestOfferTogglePassiveExplicitTarget(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "offer-passive-http-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	orgID := org.Organization.ID
	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatalf("owner token üretilemedi: %v", err)
	}

	o, err := d.offerSvc.Create(ctx, service.CreateOfferInput{
		OrganizationID: orgID, CustomerName: "Arşiv Müşteri",
		Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 100}},
	})
	if err != nil {
		t.Fatal(err)
	}
	path := "/api/v1/offers/" + o.ID + "/toggle-passive"
	isPassive := func(t *testing.T) bool {
		t.Helper()
		got, err := d.offerSvc.Get(ctx, o.ID, orgID)
		if err != nil {
			t.Fatal(err)
		}
		return got.IsPassive
	}
	post := func(t *testing.T, body string, want int) {
		t.Helper()
		rec, _ := rbacDo(t, d.router, http.MethodPost, path, ownerToken, body)
		if rec.Code != want {
			t.Fatalf("POST %s %q = %d, want %d; body=%s", path, body, rec.Code, want, rec.Body.String())
		}
	}

	post(t, `{"is_passive":true}`, http.StatusOK)
	if !isPassive(t) {
		t.Fatal("arşive alınmalı")
	}
	post(t, `{"is_passive":true}`, http.StatusOK)
	if !isPassive(t) {
		t.Error("ikinci 'Arşivle' arşivden çıkarmamalı")
	}
	post(t, `{"is_passive":false}`, http.StatusOK)
	if isPassive(t) {
		t.Error("arşivden çıkarılmalı")
	}
	post(t, "", http.StatusOK)
	if !isPassive(t) {
		t.Error("gövdesiz istek tersine çevirmeli (eski davranış)")
	}
	post(t, `{"passive":true}`, http.StatusBadRequest)

	// Arşivleme durum değiştirmektir: offers.update yetmez.
	_, fieldToken := mustCreateRoleUser(t, ctx, d, orgID, "opa_field", domain.OrgRoleField)
	rec, _ := rbacDo(t, d.router, http.MethodPost, path, fieldToken, `{"is_passive":false}`)
	if rec.Code != http.StatusForbidden {
		t.Errorf("offers.approve olmadan = %d, want 403", rec.Code)
	}
}
