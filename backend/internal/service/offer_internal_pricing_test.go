package service_test

// İç Taşeron Fiyatlama (migration 0040) için otomatik testler -- gerçek bir
// PostgreSQL bağlantısı gerektirir (bkz. tenant_isolation_test.go'daki
// paylaşılan yardımcılar, offer_revision_test.go İLE AYNI fixture deseni).

import (
	"context"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestOfferInternalPricing(t *testing.T) {
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

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "İç Fiyatlama Test Firma A", "ic-fiyatlama-test-firma-a")

	t.Run("1_markup_mode_computes_unit_price_server_side", func(t *testing.T) {
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgA.ID,
			CustomerName:   "Markup Test Müşteri",
			Items: []service.OfferItemInput{{
				ProductName: "Asma Tavan Montajı", Quantity: 1,
				// İstemci YANLIŞ/tutarsız bir unit_price gönderse bile
				// (1 TL) -- markup modunda bu YOK SAYILMALI, sunucu
				// 70000*(1+30/100)=91000 hesaplamalı.
				UnitPrice:               1,
				InternalSubcontractCost: ptrFloat(70000),
				PricingMode:             domain.OfferItemPricingModeMarkup,
				MarkupPercent:           ptrFloat(30),
			}},
			CanManageInternalPricing: true,
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		it := o.Items[0]
		if it.UnitPrice != 91000 {
			t.Fatalf("unit_price sunucuda 91000 olarak hesaplanmalı (istemcinin gönderdiği 1 YOK SAYILMALI), geldi: %v", it.UnitPrice)
		}
		if it.LineTotal != 91000 {
			t.Errorf("line_total 91000 olmalı, geldi: %v", it.LineTotal)
		}
		if it.InternalSubcontractCost == nil || *it.InternalSubcontractCost != 70000 {
			t.Errorf("InternalSubcontractCost 70000 olmalı, geldi: %v", it.InternalSubcontractCost)
		}
		if p := it.ExpectedProfit(); p == nil || *p != 21000 {
			t.Errorf("ExpectedProfit 21000 olmalı, geldi: %v", p)
		}
		if m := it.EffectiveMarkupPercent(); m == nil || *m != 30 {
			t.Errorf("EffectiveMarkupPercent 30 olmalı, geldi: %v", m)
		}
	})

	t.Run("2_manual_mode_preserves_entered_selling_price_exactly", func(t *testing.T) {
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgA.ID,
			CustomerName:   "Manuel Test Müşteri",
			Items: []service.OfferItemInput{{
				ProductName: "Özel İş", Quantity: 1,
				UnitPrice:               95000,
				InternalSubcontractCost: ptrFloat(70000),
				PricingMode:             domain.OfferItemPricingModeManual,
			}},
			CanManageInternalPricing: true,
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		it := o.Items[0]
		if it.UnitPrice != 95000 {
			t.Fatalf("manuel modda unit_price ASLA otomatik değiştirilmemeli, geldi: %v", it.UnitPrice)
		}
		if p := it.ExpectedProfit(); p == nil || *p != 25000 {
			t.Errorf("ExpectedProfit 25000 olmalı (95000-70000), geldi: %v", p)
		}
		// spec örneği: 35.714...% -- round2 ile 35.71.
		if m := it.EffectiveMarkupPercent(); m == nil || *m != 35.71 {
			t.Errorf("EffectiveMarkupPercent ~35.71 olmalı, geldi: %v", m)
		}
	})

	t.Run("3_without_permission_internal_fields_are_silently_stripped", func(t *testing.T) {
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgA.ID,
			CustomerName:   "İzinsiz Test Müşteri",
			Items: []service.OfferItemInput{{
				ProductName: "Kalem", Quantity: 1, UnitPrice: 5000,
				InternalSubcontractCost: ptrFloat(3000),
				PricingMode:             domain.OfferItemPricingModeManual,
			}},
			CanManageInternalPricing: false, // <- izin YOK
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		it := o.Items[0]
		if it.InternalSubcontractCost != nil {
			t.Fatalf("GÜVENLİK: izin yokken InternalSubcontractCost persist EDİLMEMELİ, geldi: %v", *it.InternalSubcontractCost)
		}
		if it.PricingMode != nil {
			t.Errorf("GÜVENLİK: izin yokken PricingMode persist EDİLMEMELİ, geldi: %v", *it.PricingMode)
		}
		if it.UnitPrice != 5000 {
			t.Errorf("satış fiyatının kendisi (unit_price) etkilenmemeli, geldi: %v", it.UnitPrice)
		}
	})

	t.Run("4_markup_mode_requires_markup_percent", func(t *testing.T) {
		_, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgA.ID,
			CustomerName:   "Hata Test",
			Items: []service.OfferItemInput{{
				ProductName: "Kalem", Quantity: 1, UnitPrice: 1000,
				InternalSubcontractCost: ptrFloat(700),
				PricingMode:             domain.OfferItemPricingModeMarkup,
				// MarkupPercent EKSİK.
			}},
			CanManageInternalPricing: true,
		})
		if err == nil {
			t.Fatal("markup modunda MarkupPercent eksikken hata BEKLENİYORDU")
		}
	})

	t.Run("5_negative_cost_rejected", func(t *testing.T) {
		_, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgA.ID,
			CustomerName:   "Hata Test 2",
			Items: []service.OfferItemInput{{
				ProductName: "Kalem", Quantity: 1, UnitPrice: 1000,
				InternalSubcontractCost: ptrFloat(-1),
				PricingMode:             domain.OfferItemPricingModeManual,
			}},
			CanManageInternalPricing: true,
		})
		if err == nil {
			t.Fatal("negatif iç maliyet REDDEDİLMELİYDİ")
		}
	})

	// spec örneği birebir: Revizyon 1 (cost 70000, sell 91000) ->
	// Revize Et -> Revizyon 2'de cost/sell değişir (75000/98000) -- Revizyon
	// 1'in donmuş kaydı BUNDAN ETKİLENMEMELİ (offer_revisions'ın "geçmişi
	// mutate etme" ilkesi, calc_snapshot İLE AYNI).
	t.Run("6_revise_clones_then_update_does_not_mutate_prior_revision", func(t *testing.T) {
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgA.ID,
			CustomerName:   "Revizyon İç Fiyatlama Test",
			Items: []service.OfferItemInput{{
				ProductName: "Asma Tavan", Quantity: 1,
				UnitPrice:               1,
				InternalSubcontractCost: ptrFloat(70000),
				PricingMode:             domain.OfferItemPricingModeMarkup,
				MarkupPercent:           ptrFloat(30),
			}},
			CanManageInternalPricing: true,
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		firstRevisionID := o.CurrentRevisionID
		if it := o.Items[0]; it.UnitPrice != 91000 {
			t.Fatalf("rev1 satış fiyatı 91000 olmalı, geldi: %v", it.UnitPrice)
		}

		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		revised, err := offerSvc.Revise(ctx, o.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("revize edilemedi: %v", err)
		}
		// Klonlanan yeni revizyon, KENDİSİ henüz değiştirilmeden önce AYNI
		// iç fiyatlama varsayımlarını taşımalı.
		if it := revised.Items[0]; it.InternalSubcontractCost == nil || *it.InternalSubcontractCost != 70000 {
			t.Fatalf("klonlanan revizyon AYNI iç maliyeti (70000) taşımalı, geldi: %v", it.InternalSubcontractCost)
		}

		updated, err := offerSvc.Update(ctx, o.ID, orgA.ID, service.UpdateOfferInput{
			CustomerName: "Revizyon İç Fiyatlama Test",
			Items: []service.OfferItemInput{{
				ProductName: "Asma Tavan", Quantity: 1,
				UnitPrice:               98000,
				InternalSubcontractCost: ptrFloat(75000),
				PricingMode:             domain.OfferItemPricingModeManual,
			}},
			CanManageInternalPricing: true,
		})
		if err != nil {
			t.Fatalf("yeni revizyon güncellenemedi: %v", err)
		}
		if it := updated.Items[0]; it.UnitPrice != 98000 || it.InternalSubcontractCost == nil || *it.InternalSubcontractCost != 75000 {
			t.Fatalf("rev2 satış=98000/maliyet=75000 olmalı, geldi satış=%v maliyet=%v", it.UnitPrice, it.InternalSubcontractCost)
		}

		// KRİTİK: Revizyon 1'in donmuş kaydı HÂLÂ 70000/91000 olmalı --
		// Update() İKİNCİ revizyonu (offer.CurrentRevisionID) değiştirdi,
		// BİRİNCİYİ ASLA mutate etmedi.
		firstRev, err := offerSvc.GetRevision(ctx, firstRevisionID, orgA.ID)
		if err != nil {
			t.Fatalf("ilk revizyon okunamadı: %v", err)
		}
		it := firstRev.Items[0]
		if it.InternalSubcontractCost == nil || *it.InternalSubcontractCost != 70000 {
			t.Fatalf("GÜVENLİK/BÜTÜNLÜK: rev1'in iç maliyeti HÂLÂ 70000 olmalı (mutate EDİLMEMELİ), geldi: %v", it.InternalSubcontractCost)
		}
		if it.UnitPrice != 91000 {
			t.Fatalf("rev1'in satış fiyatı HÂLÂ 91000 olmalı, geldi: %v", it.UnitPrice)
		}
	})
}
