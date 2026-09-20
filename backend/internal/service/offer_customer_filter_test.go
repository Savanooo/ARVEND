package service_test

// Müşteri modülü (mobil) — GET /offers?customer_id= filtresi. Gerçek bir
// PostgreSQL bağlantısı gerektirir (bkz. tenant_isolation_test.go'daki
// testDBURL/mustCreateOrg yardımcıları, aynı pakette paylaşılır).
//
// offers tablosunun kendisinde customer_id YOK (0018 migration'da
// kaldırıldı) -- canlı değer yalnızca current_revision üzerinden
// erişilebilir (bkz. backend Phase 1 doğrulaması). Bu testler ListOffers'a
// eklenen nullable customer_id filtresinin projects.sql'deki AYNI
// desenle (ListProjects) tutarlı davrandığını doğrular: filtre yokken
// tüm teklifler döner, filtre varken yalnızca o müşteriye bağlı teklifler
// döner, ve organizasyon izolasyonu korunur.

import (
	"context"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestOfferListCustomerFilter(t *testing.T) {
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
	customerSvc := service.NewCustomerService(q)

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Müşteri Filtre Test Firma", "musteri-filtre-test-firma")
	otherOrg := mustCreateOrg(t, ctx, orgSvc, pool, "Müşteri Filtre Test Firma B", "musteri-filtre-test-firma-b")

	customerA, err := customerSvc.Create(ctx, org.ID, service.CustomerInput{Name: "Müşteri A"})
	if err != nil {
		t.Fatalf("müşteri A oluşturulamadı: %v", err)
	}
	customerB, err := customerSvc.Create(ctx, org.ID, service.CustomerInput{Name: "Müşteri B"})
	if err != nil {
		t.Fatalf("müşteri B oluşturulamadı: %v", err)
	}

	newOffer := func(t *testing.T, customerID *string, name string) {
		t.Helper()
		_, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID,
			CustomerID:     customerID,
			CustomerName:   name,
			Items:          []service.OfferItemInput{{ProductName: "Kalem", Quantity: 1, UnitPrice: 100}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
	}

	newOffer(t, &customerA.ID, "Müşteri A")
	newOffer(t, &customerA.ID, "Müşteri A")
	newOffer(t, &customerB.ID, "Müşteri B")
	newOffer(t, nil, "Serbest Metin Müşteri")

	t.Run("no_filter_returns_all_four", func(t *testing.T) {
		res, err := offerSvc.List(ctx, org.ID, false, 1, 200, "")
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		if len(res.Offers) != 4 {
			t.Fatalf("filtresiz liste 4 teklif dönmeli, geldi: %d", len(res.Offers))
		}
		if res.Total != 4 {
			t.Errorf("filtresiz toplam 4 olmalı, geldi: %d", res.Total)
		}
	})

	t.Run("customer_id_filter_returns_only_that_customers_offers", func(t *testing.T) {
		res, err := offerSvc.List(ctx, org.ID, false, 1, 200, customerA.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		if len(res.Offers) != 2 {
			t.Fatalf("müşteri A'nın 2 teklifi olmalı, geldi: %d", len(res.Offers))
		}
		if res.Total != 2 {
			t.Errorf("müşteri A toplamı 2 olmalı, geldi: %d", res.Total)
		}
		for _, o := range res.Offers {
			if o.CustomerID == nil || *o.CustomerID != customerA.ID {
				t.Errorf("dönen teklifin customer_id'si müşteri A değil: %+v", o.CustomerID)
			}
		}
	})

	t.Run("customer_id_filter_for_customer_with_one_offer", func(t *testing.T) {
		res, err := offerSvc.List(ctx, org.ID, false, 1, 200, customerB.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		if len(res.Offers) != 1 {
			t.Fatalf("müşteri B'nin 1 teklifi olmalı, geldi: %d", len(res.Offers))
		}
	})

	t.Run("free_text_customer_offer_never_matches_a_customer_id_filter", func(t *testing.T) {
		// customer_id=null olan "Serbest Metin Müşteri" teklifi, HİÇBİR
		// customer_id filtresiyle eşleşmemeli -- yalnızca filtresiz listede
		// görünür (yukarıdaki no_filter testinde zaten doğrulandı).
		res, err := offerSvc.List(ctx, org.ID, false, 1, 200, customerA.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		for _, o := range res.Offers {
			if o.CustomerName == "Serbest Metin Müşteri" {
				t.Errorf("serbest metin (customer_id=null) teklif filtreli listede göründü")
			}
		}
	})

	t.Run("unknown_customer_id_returns_empty_not_error", func(t *testing.T) {
		res, err := offerSvc.List(ctx, org.ID, false, 1, 200, "00000000-0000-0000-0000-000000000000")
		if err != nil {
			t.Fatalf("bilinmeyen customer_id hata döndürmemeli: %v", err)
		}
		if len(res.Offers) != 0 {
			t.Errorf("bilinmeyen customer_id boş liste dönmeli, geldi: %d", len(res.Offers))
		}
	})

	t.Run("customer_id_filter_is_organization_scoped", func(t *testing.T) {
		// customerA, org'a ait -- otherOrg'da hiç teklif yok, ama asıl kontrol
		// customer_id'nin organization_id ile BİRLİKTE filtrelendiğidir:
		// otherOrg + customerA.ID kombinasyonu (farklı org'daki bir UUID)
		// hiçbir satırla eşleşmemeli.
		res, err := offerSvc.List(ctx, otherOrg.ID, false, 1, 200, customerA.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		if len(res.Offers) != 0 {
			t.Errorf("başka organizasyonun customer_id'siyle çapraz sorgu boş dönmeli, geldi: %d", len(res.Offers))
		}
	})
}
