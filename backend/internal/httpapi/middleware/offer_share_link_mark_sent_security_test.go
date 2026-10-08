package middleware_test

import (
	"context"
	"net/http"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// TestShareLinkMarkSentRequiresStatusPermission: POST /offers/{id}/share-links
// offers.update ister (link oluşturmak "paylaşma"dır). mark_sent:true ise
// teklifin durumunu da değiştirir -- PUT /offers/{id}/status ile aynı izin
// (offers.approve) şart; yoksa durum değiştirme yetkisi olmayan biri bu
// uçtan teklifi "gönderildi" yapabilirdi. Reddedilen istek link de
// oluşturmaz. mark_sent gönderilmeyen istek (eski uygulama, web) bugünkü
// gibi taslakta önizleme linki alır.
func TestShareLinkMarkSentRequiresStatusPermission(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "share-mark-sent-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	other := mustCreateReadyOrg(t, ctx, d, "share-mark-sent-other")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, other.Organization.ID) })
	orgID := org.Organization.ID

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatalf("owner token üretilemedi: %v", err)
	}
	otherOwnerToken, err := d.issuer.IssueAccessToken(other.Owner.ID, domain.RoleAdmin, other.Organization.ID)
	if err != nil {
		t.Fatalf("diğer firma token'ı üretilemedi: %v", err)
	}
	// Satış personeli: teklifi düzenleyip paylaşabilir ama durumunu
	// değiştiremez (offers.approve yok).
	sales, salesToken := mustCreateRoleUser(t, ctx, d, orgID, "smk_sales", domain.OrgRoleProjectManager)
	detail, err := d.authzSvc.GetUserPermissionDetail(ctx, sales.ID, orgID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.authzSvc.SetUserPermissions(ctx, sales.ID, orgID, org.Owner.ID,
		append(detail.RolePermissions, domain.PermOffersRead, domain.PermOffersUpdate)); err != nil {
		t.Fatalf("izin ayarlanamadı: %v", err)
	}
	_, fieldToken := mustCreateRoleUser(t, ctx, d, orgID, "smk_field", domain.OrgRoleField)

	newDraft := func(t *testing.T) *domain.Offer {
		t.Helper()
		o, err := d.offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID, CustomerName: "Link Test Müşteri",
			Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 5000}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		return o
	}
	path := func(o *domain.Offer) string { return "/api/v1/offers/" + o.ID + "/share-links" }
	state := func(t *testing.T, o *domain.Offer) (status string, links int) {
		t.Helper()
		got, err := d.offerSvc.Get(ctx, o.ID, orgID)
		if err != nil {
			t.Fatal(err)
		}
		ls, err := d.offerSvc.ListShareLinks(ctx, o.ID, orgID)
		if err != nil {
			t.Fatal(err)
		}
		return got.Status, len(ls)
	}

	t.Run("without_approve_mark_sent_refused_and_no_link", func(t *testing.T) {
		o := newDraft(t)
		rec, body := rbacDo(t, d.router, http.MethodPost, path(o), salesToken, `{"mark_sent":true}`)
		if rec.Code != http.StatusForbidden || body["code"] != "permission_denied" {
			t.Fatalf("status = %d, body=%v; beklenen 403 permission_denied", rec.Code, body)
		}
		if status, links := state(t, o); status != domain.OfferStatusTaslak || links != 0 {
			t.Errorf("reddedilen istek iz bıraktı: durum=%s link=%d", status, links)
		}
	})

	t.Run("without_approve_preview_link_still_allowed", func(t *testing.T) {
		o := newDraft(t)
		rec, body := rbacDo(t, d.router, http.MethodPost, path(o), salesToken, `{}`)
		if rec.Code != http.StatusCreated {
			t.Fatalf("status = %d, body=%v; beklenen 201", rec.Code, body)
		}
		if status, links := state(t, o); status != domain.OfferStatusTaslak || links != 1 {
			t.Errorf("önizleme linki: durum=%s link=%d; beklenen taslak/1", status, links)
		}
	})

	t.Run("with_approve_mark_sent_sends_and_links", func(t *testing.T) {
		o := newDraft(t)
		rec, body := rbacDo(t, d.router, http.MethodPost, path(o), ownerToken, `{"mark_sent":true,"expires_in":"30d"}`)
		if rec.Code != http.StatusCreated {
			t.Fatalf("status = %d, body=%v; beklenen 201", rec.Code, body)
		}
		if status, links := state(t, o); status != domain.OfferStatusGonderildi || links != 1 {
			t.Errorf("durum=%s link=%d; beklenen gönderildi/1", status, links)
		}
		token, _ := body["token"].(string)
		view, err := d.offerSvc.GetPublicView(ctx, token, "", "")
		if err != nil {
			t.Fatalf("müşteri sayfası açılamadı: %v", err)
		}
		if !view.CanRespond {
			t.Error("gönderilen linkte can_respond true olmalı")
		}
		if body["revision_id"] != o.CurrentRevisionID || body["expires_at"] == nil {
			t.Errorf("link yanıtı beklenen revizyon/süreyi taşımıyor: %v", body)
		}
	})

	t.Run("without_update_refused", func(t *testing.T) {
		o := newDraft(t)
		rec, body := rbacDo(t, d.router, http.MethodPost, path(o), fieldToken, `{"mark_sent":true}`)
		if rec.Code != http.StatusForbidden {
			t.Fatalf("status = %d, body=%v; beklenen 403", rec.Code, body)
		}
		if status, links := state(t, o); status != domain.OfferStatusTaslak || links != 0 {
			t.Errorf("reddedilen istek iz bıraktı: durum=%s link=%d", status, links)
		}
	})

	t.Run("other_tenant_not_found", func(t *testing.T) {
		o := newDraft(t)
		rec, body := rbacDo(t, d.router, http.MethodPost, path(o), otherOwnerToken, `{"mark_sent":true}`)
		if rec.Code != http.StatusNotFound {
			t.Fatalf("status = %d, body=%v; beklenen 404", rec.Code, body)
		}
		if status, links := state(t, o); status != domain.OfferStatusTaslak || links != 0 {
			t.Errorf("başka firmanın isteği iz bıraktı: durum=%s link=%d", status, links)
		}
	})
}
