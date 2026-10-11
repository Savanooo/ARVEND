package service_test

import (
	"context"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// TestOfferSetPassive: "Arşivle"/"Arşivden Çıkar" açık hedefle çalışır --
// teklif zaten istenen durumdaysa hiçbir şey değişmez (ekrandaki durumu
// bayat olan ikinci kişi arşivi geri almasın), arşive giriş bir kez
// "offer_cancelled", arşivden çıkış bir kez "offer_reactivated" olayı yazar.
// Gövdesiz eski uç (TogglePassive) tersine çevirmeye devam eder.
func TestOfferSetPassive(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	offerSvc := service.NewOfferService(pool, q, service.NewSettingsService(q, testSecretBox(t)), "http://localhost:3000")
	org := mustCreateOrg(t, ctx, orgSvc, pool, "Arşiv Test", "teklif-arsiv-test")

	o, err := offerSvc.Create(ctx, service.CreateOfferInput{
		OrganizationID: org.ID, CustomerName: "Müşteri",
		Items: []service.OfferItemInput{{ProductName: "Kalem", Quantity: 1, UnitPrice: 100}},
	})
	if err != nil {
		t.Fatal(err)
	}
	passive := func(t *testing.T) bool {
		t.Helper()
		got, err := offerSvc.Get(ctx, o.ID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		return got.IsPassive
	}
	countEvents := func(t *testing.T, eventType string) int {
		t.Helper()
		events, err := offerSvc.ListEvents(ctx, o.ID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		n := 0
		for _, e := range events {
			if e.EventType == eventType {
				n++
			}
		}
		return n
	}
	cancelledEvents := func(t *testing.T) int { return countEvents(t, domain.EventOfferCancelled) }
	reactivatedEvents := func(t *testing.T) int { return countEvents(t, domain.EventOfferReactivated) }

	if err := offerSvc.SetPassive(ctx, o.ID, org.ID, "", true); err != nil {
		t.Fatal(err)
	}
	if !passive(t) || cancelledEvents(t) != 1 {
		t.Fatalf("arşive alınmalı ve bir olay yazılmalı: passive=%v olay=%d", passive(t), cancelledEvents(t))
	}
	// İkinci "Arşivle" (bayat ekran): durum ve olaylar değişmez.
	if err := offerSvc.SetPassive(ctx, o.ID, org.ID, "", true); err != nil {
		t.Fatal(err)
	}
	if !passive(t) || cancelledEvents(t) != 1 {
		t.Errorf("zaten arşivdeki teklif arşivden çıkmamalı, olay tekrarlanmamalı: passive=%v olay=%d", passive(t), cancelledEvents(t))
	}
	if reactivatedEvents(t) != 0 {
		t.Errorf("arşive alma 'arşivden çıkarıldı' yazmamalı: %d", reactivatedEvents(t))
	}
	if err := offerSvc.SetPassive(ctx, o.ID, org.ID, "", false); err != nil {
		t.Fatal(err)
	}
	if passive(t) {
		t.Error("arşivden çıkarılmalı")
	}
	// Arşivden çıkış zaman çizelgesine yazılır (eskiden hiç loglanmıyordu).
	if reactivatedEvents(t) != 1 || cancelledEvents(t) != 1 {
		t.Errorf("arşivden çıkış bir offer_reactivated yazmalı: reactivated=%d cancelled=%d", reactivatedEvents(t), cancelledEvents(t))
	}
	if err := offerSvc.SetPassive(ctx, o.ID, org.ID, "", false); err != nil || passive(t) {
		t.Errorf("zaten aktif teklif aktif kalmalı: passive=%v err=%v", passive(t), err)
	}
	if reactivatedEvents(t) != 1 {
		t.Errorf("zaten aktif teklifte olay tekrarlanmamalı: %d", reactivatedEvents(t))
	}
	// Eski davranış: tersine çevirir.
	if err := offerSvc.TogglePassive(ctx, o.ID, org.ID, ""); err != nil || !passive(t) {
		t.Errorf("TogglePassive tersine çevirmeli: passive=%v err=%v", passive(t), err)
	}
	if err := offerSvc.TogglePassive(ctx, o.ID, org.ID, ""); err != nil || passive(t) {
		t.Errorf("TogglePassive tekrar tersine çevirmeli: passive=%v err=%v", passive(t), err)
	}
	if cancelledEvents(t) != 2 || reactivatedEvents(t) != 2 {
		t.Errorf("TogglePassive de iki yönü loglamalı: cancelled=%d reactivated=%d", cancelledEvents(t), reactivatedEvents(t))
	}
	other := mustCreateOrg(t, ctx, orgSvc, pool, "Arşiv Test B", "teklif-arsiv-test-b")
	if err := offerSvc.SetPassive(ctx, o.ID, other.ID, "", false); err != domain.ErrNotFound {
		t.Errorf("başka firmanın teklifi bulunamamalı: %v", err)
	}
}
