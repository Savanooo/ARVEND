package service_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// TestOfferListServerSideFilters: liste eskiden yalnızca ilk 50 teklifi
// döndürüp arama/durum/tarih filtresini istemcide uyguluyordu -- 51. ve
// sonraki teklifler hiçbir filtrede görünmüyordu. Filtreler artık
// sunucuda, toplamlar gerçek.
func TestOfferListServerSideFilters(t *testing.T) {
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
	org := mustCreateOrg(t, ctx, orgSvc, pool, "Teklif Liste Filtre Test", "teklif-liste-filtre-test")

	// 60 teklif: ilk oluşturulan ("Eski Müşteri %_") en eskidir ve varsayılan
	// 50'lik ilk sayfaya GİRMEZ. 10 tanesi gönderilmiş.
	var oldest *domain.Offer
	for i := 0; i < 60; i++ {
		name := fmt.Sprintf("Müşteri %02d", i)
		if i == 0 {
			name = "Eski Müşteri %_"
		}
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerName: name,
			Items: []service.OfferItemInput{{ProductName: "Kalem", Quantity: 1, UnitPrice: 10}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if i == 0 {
			oldest = o
		}
		if i%6 == 0 {
			if _, err := offerSvc.UpdateStatus(ctx, o.ID, org.ID, domain.OfferStatusGonderildi, ""); err != nil {
				t.Fatal(err)
			}
		}
	}
	// En eski teklifi geçmiş bir tarihe çek (tarih filtresi için).
	if _, err := pool.Exec(ctx, "UPDATE offers SET offer_date = '2024-01-15', created_at = now() - interval '400 days' WHERE id = $1", oldest.ID); err != nil {
		t.Fatal(err)
	}

	t.Run("total_is_real_not_page_size", func(t *testing.T) {
		res, err := offerSvc.List(ctx, org.ID, service.OfferListFilter{})
		if err != nil {
			t.Fatal(err)
		}
		if len(res.Offers) != 50 || res.Total != 60 {
			t.Errorf("ilk sayfa 50 satır, toplam 60 olmalı: satır=%d toplam=%d", len(res.Offers), res.Total)
		}
		if res.StatusCounts[domain.OfferStatusGonderildi] != 10 || res.StatusCounts[domain.OfferStatusTaslak] != 50 || res.StatusCounts[domain.OfferStatusKabulEdildi] != 0 {
			t.Errorf("durum sayaçları yanlış: %+v", res.StatusCounts)
		}
		page2, err := offerSvc.List(ctx, org.ID, service.OfferListFilter{Page: 2})
		if err != nil {
			t.Fatal(err)
		}
		if len(page2.Offers) != 10 || page2.Offers[len(page2.Offers)-1].ID != oldest.ID {
			t.Errorf("ikinci sayfa kalan 10 teklifi (en eski en sonda) içermeli: %d", len(page2.Offers))
		}
	})

	t.Run("search_finds_offer_beyond_first_page_and_escapes_wildcards", func(t *testing.T) {
		res, err := offerSvc.List(ctx, org.ID, service.OfferListFilter{Search: "eski müşteri %_"})
		if err != nil {
			t.Fatal(err)
		}
		if res.Total != 1 || len(res.Offers) != 1 || res.Offers[0].ID != oldest.ID {
			t.Errorf("arama ilk sayfanın dışındaki teklifi bulmalı: toplam=%d", res.Total)
		}
		pct, err := offerSvc.List(ctx, org.ID, service.OfferListFilter{Search: "%"})
		if err != nil {
			t.Fatal(err)
		}
		if pct.Total != 1 {
			t.Errorf("'%%' joker değil düz metin aranmalı: toplam=%d", pct.Total)
		}
		byNo, err := offerSvc.List(ctx, org.ID, service.OfferListFilter{Search: oldest.OfferNo})
		if err != nil || byNo.Total != 1 {
			t.Errorf("teklif no ile aranabilmeli: %v err=%v", byNo, err)
		}
	})

	t.Run("status_and_date_filters", func(t *testing.T) {
		sent, err := offerSvc.List(ctx, org.ID, service.OfferListFilter{Status: domain.OfferStatusGonderildi})
		if err != nil {
			t.Fatal(err)
		}
		if sent.Total != 10 || len(sent.Offers) != 10 {
			t.Errorf("gönderildi filtresi 10 teklif dönmeli: %d", sent.Total)
		}
		for _, o := range sent.Offers {
			if o.Status != domain.OfferStatusGonderildi {
				t.Errorf("filtre dışı durum: %s", o.Status)
			}
		}
		// Sekme sayaçları durum filtresinden bağımsızdır.
		if sent.StatusCounts[domain.OfferStatusTaslak] != 50 {
			t.Errorf("sayaçlar durum filtresinden etkilenmemeli: %+v", sent.StatusCounts)
		}

		from := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
		to := time.Date(2024, 1, 31, 0, 0, 0, 0, time.UTC)
		old, err := offerSvc.List(ctx, org.ID, service.OfferListFilter{DateFrom: &from, DateTo: &to})
		if err != nil {
			t.Fatal(err)
		}
		if old.Total != 1 || old.Offers[0].ID != oldest.ID {
			t.Errorf("tarih aralığı yalnızca eski teklifi dönmeli: %d", old.Total)
		}
		// Bitiş günü dahil.
		day := time.Date(2024, 1, 15, 0, 0, 0, 0, time.UTC)
		same, err := offerSvc.List(ctx, org.ID, service.OfferListFilter{DateFrom: &day, DateTo: &day})
		if err != nil || same.Total != 1 {
			t.Errorf("tek günlük aralık o günü içermeli: %v err=%v", same, err)
		}
	})

	t.Run("invalid_status_rejected", func(t *testing.T) {
		if _, err := offerSvc.List(ctx, org.ID, service.OfferListFilter{Status: "yok"}); err == nil {
			t.Error("geçersiz durum reddedilmeli")
		}
	})
}
