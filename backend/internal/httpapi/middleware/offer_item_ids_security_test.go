package middleware_test

// PUT /offers/{id}: iç fiyatlama yetkisi (offers.internal_pricing.manage)
// olmayan düzenleyicinin kaydında sunucu, mevcut kalemlerin iç maliyetini
// kalem id'siyle taşır. Mobil 1.5.14 id gönderir; mevcut kalemlerin hepsini
// silip yalnızca yeni satır kaydettiğinde bunu `item_ids_sent: true` ile
// söyler (aksi halde id göndermeyen eski uygulamayla karışırdı). Bayat id'ler
// (form açıkken başka biri kaydetti) reddedilir. Gerçek router + gerçek DB.

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestOfferUpdateItemIDsForEditorWithoutInternalPricing(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "offer-item-ids-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	orgID := org.Organization.ID

	// Satış personeli: teklif düzenler ama iç maliyeti göremez/değiştiremez.
	sales, salesToken := mustCreateRoleUser(t, ctx, d, orgID, "oii_sales", domain.OrgRoleProjectManager)
	detail, err := d.authzSvc.GetUserPermissionDetail(ctx, sales.ID, orgID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.authzSvc.SetUserPermissions(ctx, sales.ID, orgID, org.Owner.ID,
		append(detail.RolePermissions, domain.PermOffersRead, domain.PermOffersUpdate)); err != nil {
		t.Fatalf("izin ayarlanamadı: %v", err)
	}

	cost := 3000.0
	newDraft := func(t *testing.T) *domain.Offer {
		t.Helper()
		o, err := d.offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID, CustomerName: "İç Maliyet Müşteri",
			Items: []service.OfferItemInput{
				{ProductName: "Çatı", Quantity: 1, UnitPrice: 5000, InternalSubcontractCost: &cost, PricingMode: domain.OfferItemPricingModeManual},
				{ProductName: "Boya", Quantity: 1, UnitPrice: 100},
			},
			CanManageInternalPricing: true,
		})
		if err != nil {
			t.Fatalf("taslak oluşturulamadı: %v", err)
		}
		return o
	}
	costOf := func(t *testing.T, o *domain.Offer, name string) *float64 {
		t.Helper()
		got, err := d.offerSvc.Get(ctx, o.ID, orgID)
		if err != nil {
			t.Fatal(err)
		}
		for _, it := range got.Items {
			if it.ProductName == name {
				return it.InternalSubcontractCost
			}
		}
		return nil
	}
	put := func(t *testing.T, o *domain.Offer, body string, want int) map[string]any {
		t.Helper()
		rec, resp := rbacDo(t, d.router, http.MethodPut, "/api/v1/offers/"+o.ID, salesToken, body)
		if rec.Code != want {
			t.Fatalf("PUT = %d, want %d; body=%s", rec.Code, want, rec.Body.String())
		}
		return resp
	}

	t.Run("ids_keep_internal_cost", func(t *testing.T) {
		o := newDraft(t)
		body := `{"customer_name":"İç Maliyet Müşteri","items":[` +
			`{"id":"` + o.Items[0].ID + `","product_name":"Çatı","quantity":2,"unit_price":5000},` +
			`{"product_name":"Yeni","quantity":1,"unit_price":10}]}`
		put(t, o, body, http.StatusOK)
		if c := costOf(t, o, "Çatı"); c == nil || *c != cost {
			t.Errorf("Çatı'nın iç maliyeti korunmalı: %v", c)
		}
	})

	t.Run("old_client_without_ids_is_refused", func(t *testing.T) {
		o := newDraft(t)
		put(t, o, `{"customer_name":"İç Maliyet Müşteri","items":[{"product_name":"Çatı","quantity":2,"unit_price":5000}]}`, http.StatusConflict)
		if c := costOf(t, o, "Çatı"); c == nil || *c != cost {
			t.Errorf("reddedilen kayıt iç maliyeti silmemeli: %v", c)
		}
	})

	t.Run("all_rows_new_with_item_ids_sent_saves", func(t *testing.T) {
		o := newDraft(t)
		resp := put(t, o, `{"customer_name":"İç Maliyet Müşteri","item_ids_sent":true,`+
			`"items":[{"product_name":"Metraj Satırı","quantity":3,"unit_price":50}]}`, http.StatusOK)
		items, _ := resp["items"].([]any)
		if len(items) != 1 {
			t.Fatalf("yalnızca yeni satır kalmalı: %v", resp["items"])
		}
		if _, leaked := items[0].(map[string]any)["internal_pricing"]; leaked {
			t.Errorf("yetkisiz düzenleyiciye iç fiyatlama dönmemeli: %v", items[0])
		}
	})

	t.Run("stale_ids_are_refused_with_reason", func(t *testing.T) {
		o := newDraft(t)
		stale := o.Items[0].ID
		// Başka biri kaydetti: kalemler yeni id'lerle yeniden yazıldı.
		put(t, o, `{"customer_name":"İç Maliyet Müşteri","items":[`+
			`{"id":"`+o.Items[0].ID+`","product_name":"Çatı","quantity":1,"unit_price":5000},`+
			`{"id":"`+o.Items[1].ID+`","product_name":"Boya","quantity":1,"unit_price":100}]}`, http.StatusOK)
		rec, _ := rbacDo(t, d.router, http.MethodPut, "/api/v1/offers/"+o.ID, salesToken,
			`{"customer_name":"İç Maliyet Müşteri","items":[{"id":"`+stale+`","product_name":"Çatı","quantity":7,"unit_price":5000}]}`)
		if rec.Code != http.StatusConflict || !strings.Contains(rec.Body.String(), "başka biri tarafından kaydedildi") {
			t.Fatalf("bayat id = %d %s, want 409 'başka biri tarafından kaydedildi'", rec.Code, rec.Body.String())
		}
		if c := costOf(t, o, "Çatı"); c == nil || *c != cost {
			t.Errorf("reddedilen kayıt iç maliyeti silmemeli: %v", c)
		}
	})
}
