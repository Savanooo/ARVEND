package service_test

import (
	"context"
	"errors"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// TestOfferInternalPricingCarryOver: iç fiyatlama yetkisi olmayan bir
// personelin taslak düzenlemesi, mevcut kalemlerin iç maliyetlerini
// SİLMEMELİ (Update kalemleri silip yeniden yazar; eskiden yetkisiz
// düzenleyicinin isteğinde iç alanlar olmadığı için hepsi kayboluyordu).
func TestOfferInternalPricingCarryOver(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	settingsSvc := service.NewSettingsService(q, testSecretBox(t))
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	org := mustCreateOrg(t, ctx, orgSvc, pool, "İç Maliyet Taşıma Test", "ic-maliyet-tasima-test")

	// Yetkili kullanıcının oluşturduğu taslak: A (manual, maliyet 3000),
	// M (markup %20, maliyet 100 -> 120), B (iç fiyatlama yok).
	newDraft := func(t *testing.T) *domain.Offer {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID,
			CustomerName:   "Müşteri",
			Items: []service.OfferItemInput{
				{ProductName: "A", Quantity: 1, UnitPrice: 5000, InternalSubcontractCost: ptrFloat(3000), PricingMode: domain.OfferItemPricingModeManual},
				{ProductName: "M", Quantity: 1, UnitPrice: 1, InternalSubcontractCost: ptrFloat(100), PricingMode: domain.OfferItemPricingModeMarkup, MarkupPercent: ptrFloat(20)},
				{ProductName: "B", Quantity: 1, UnitPrice: 10},
			},
			CanManageInternalPricing: true,
		})
		if err != nil {
			t.Fatalf("taslak oluşturulamadı: %v", err)
		}
		return o
	}
	idOf := func(o *domain.Offer, name string) *string {
		for _, it := range o.Items {
			if it.ProductName == name {
				id := it.ID
				return &id
			}
		}
		t.Fatalf("%s kalemi yok", name)
		return nil
	}
	byName := func(o *domain.Offer) map[string]domain.OfferItem {
		m := map[string]domain.OfferItem{}
		for _, it := range o.Items {
			m[it.ProductName] = it
		}
		return m
	}

	t.Run("matched_items_keep_internal_cost", func(t *testing.T) {
		o := newDraft(t)
		updated, err := offerSvc.Update(ctx, o.ID, org.ID, service.UpdateOfferInput{
			CustomerName: "Müşteri",
			Items: []service.OfferItemInput{
				{ID: idOf(o, "A"), ProductName: "A", Quantity: 2, UnitPrice: 5000},
				{ID: idOf(o, "M"), ProductName: "M", Quantity: 3, UnitPrice: 120},
				// Yetkisiz istemcinin uydurduğu iç alanlar yok sayılmalı.
				{ID: idOf(o, "B"), ProductName: "B", Quantity: 1, UnitPrice: 15, InternalSubcontractCost: ptrFloat(1), PricingMode: domain.OfferItemPricingModeManual},
				{ProductName: "Yeni", Quantity: 1, UnitPrice: 7, InternalSubcontractCost: ptrFloat(1), PricingMode: domain.OfferItemPricingModeManual},
			},
			CanManageInternalPricing: false,
		})
		if err != nil {
			t.Fatalf("yetkisiz düzenleme reddedildi: %v", err)
		}
		got := byName(updated)
		if a := got["A"]; a.InternalSubcontractCost == nil || *a.InternalSubcontractCost != 3000 || a.PricingMode == nil || *a.PricingMode != domain.OfferItemPricingModeManual || a.Quantity != 2 {
			t.Errorf("A iç maliyeti korunmalı: %+v", a)
		}
		if m := got["M"]; m.InternalSubcontractCost == nil || *m.InternalSubcontractCost != 100 || m.PricingMode == nil || *m.PricingMode != domain.OfferItemPricingModeMarkup || m.UnitPrice != 120 || m.LineTotal != 360 {
			t.Errorf("M markup olarak korunmalı: %+v", m)
		}
		if b := got["B"]; b.InternalSubcontractCost != nil || b.UnitPrice != 15 {
			t.Errorf("B'ye istemcinin iç maliyeti yazılmamalı: %+v", b)
		}
		if n := got["Yeni"]; n.InternalSubcontractCost != nil {
			t.Errorf("yeni kaleme istemcinin iç maliyeti yazılmamalı: %+v", n)
		}
	})

	t.Run("changed_markup_price_becomes_manual", func(t *testing.T) {
		o := newDraft(t)
		updated, err := offerSvc.Update(ctx, o.ID, org.ID, service.UpdateOfferInput{
			CustomerName: "Müşteri",
			Items: []service.OfferItemInput{
				{ID: idOf(o, "A"), ProductName: "A", Quantity: 1, UnitPrice: 5000},
				{ID: idOf(o, "M"), ProductName: "M", Quantity: 1, UnitPrice: 130},
			},
		})
		if err != nil {
			t.Fatalf("düzenleme reddedildi: %v", err)
		}
		m := byName(updated)["M"]
		if m.UnitPrice != 130 || m.PricingMode == nil || *m.PricingMode != domain.OfferItemPricingModeManual || m.InternalSubcontractCost == nil || *m.InternalSubcontractCost != 100 || m.MarkupPercent != nil {
			t.Errorf("düzenleyicinin girdiği fiyat korunmalı, kalem manual'a dönmeli, maliyet kalmalı: %+v", m)
		}
		// Silinen B kalemi gerçekten silinmiş olmalı (istek id taşıyor).
		if _, ok := byName(updated)["B"]; ok {
			t.Errorf("B kalemi silinmeliydi")
		}
	})

	t.Run("unmatched_request_is_rejected_not_wiped", func(t *testing.T) {
		o := newDraft(t)
		_, err := offerSvc.Update(ctx, o.ID, org.ID, service.UpdateOfferInput{
			CustomerName: "Müşteri",
			Items:        []service.OfferItemInput{{ProductName: "A", Quantity: 1, UnitPrice: 5000}},
		})
		if !errors.Is(err, service.ErrOfferInternalPricingUnmatched) {
			t.Fatalf("id'siz yetkisiz düzenleme reddedilmeliydi, err=%v", err)
		}
		after, err := offerSvc.Get(ctx, o.ID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		if a := byName(after)["A"]; a.InternalSubcontractCost == nil || *a.InternalSubcontractCost != 3000 || len(after.Items) != 3 {
			t.Errorf("reddedilen düzenleme hiçbir şeyi değiştirmemeli: %+v", after.Items)
		}
	})

	t.Run("manager_can_still_clear_internal_cost", func(t *testing.T) {
		o := newDraft(t)
		updated, err := offerSvc.Update(ctx, o.ID, org.ID, service.UpdateOfferInput{
			CustomerName:             "Müşteri",
			Items:                    []service.OfferItemInput{{ProductName: "A", Quantity: 1, UnitPrice: 5000}},
			CanManageInternalPricing: true,
		})
		if err != nil {
			t.Fatalf("yetkili düzenleme reddedildi: %v", err)
		}
		if a := byName(updated)["A"]; a.InternalSubcontractCost != nil {
			t.Errorf("yetkili kullanıcı iç maliyeti bilerek kaldırabilmeli: %+v", a)
		}
	})

	t.Run("draft_without_internal_cost_needs_no_ids", func(t *testing.T) {
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerName: "Müşteri",
			Items: []service.OfferItemInput{{ProductName: "B", Quantity: 1, UnitPrice: 10}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.Update(ctx, o.ID, org.ID, service.UpdateOfferInput{
			CustomerName: "Müşteri",
			Items:        []service.OfferItemInput{{ProductName: "B", Quantity: 2, UnitPrice: 10}},
		}); err != nil {
			t.Errorf("iç maliyetsiz taslak id'siz düzenlenebilmeli: %v", err)
		}
	})
}
