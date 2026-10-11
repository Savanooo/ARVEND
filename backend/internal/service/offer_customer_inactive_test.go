package service_test

// Pasif (arşivlenmiş) müşteri kartı YENİ bir teklife bağlanamaz; o karta
// zaten bağlı bir taslak ise düzenlenmeye devam edebilir. Eskiden mobilde
// pasif müşterinin kartındaki "Yeni Teklif" teklifi arşivdeki karta
// bağlıyordu (sunucu is_active'e hiç bakmıyordu). Gerçek bir PostgreSQL
// bağlantısı gerektirir (bkz. tenant_isolation_test.go yardımcıları).

import (
	"context"
	"errors"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestOfferRejectsInactiveCustomer(t *testing.T) {
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

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Pasif Müşteri Teklif Test", "pasif-musteri-teklif-test")

	active, err := customerSvc.Create(ctx, org.ID, service.CustomerInput{Name: "Aktif Müşteri"})
	if err != nil {
		t.Fatal(err)
	}
	passive, err := customerSvc.Create(ctx, org.ID, service.CustomerInput{Name: "Arşiv Müşteri"})
	if err != nil {
		t.Fatal(err)
	}
	items := []service.OfferItemInput{{ProductName: "Kalem", Quantity: 1, UnitPrice: 100}}

	// Müşteri aktifken bağlanan taslak; sonra müşteri pasifleşir.
	linkedDraft, err := offerSvc.Create(ctx, service.CreateOfferInput{
		OrganizationID: org.ID, CustomerID: &passive.ID, CustomerName: passive.Name, Items: items,
	})
	if err != nil {
		t.Fatal(err)
	}
	otherDraft, err := offerSvc.Create(ctx, service.CreateOfferInput{
		OrganizationID: org.ID, CustomerID: &active.ID, CustomerName: active.Name, Items: items,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := customerSvc.Archive(ctx, passive.ID, org.ID); err != nil {
		t.Fatal(err)
	}

	t.Run("yeni teklif pasif müşteriye bağlanamaz", func(t *testing.T) {
		_, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerID: &passive.ID, CustomerName: passive.Name, Items: items,
		})
		if !errors.Is(err, service.ErrOfferCustomerInactive) {
			t.Fatalf("pasif müşteriyle yeni teklif reddedilmeli: %v", err)
		}
	})

	t.Run("aktif müşteriyle yeni teklif serbest", func(t *testing.T) {
		if _, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerID: &active.ID, CustomerName: active.Name, Items: items,
		}); err != nil {
			t.Fatalf("aktif müşteri reddedilmemeli: %v", err)
		}
	})

	t.Run("zaten pasif müşteriye bağlı taslak düzenlenebilir", func(t *testing.T) {
		updated, err := offerSvc.Update(ctx, linkedDraft.ID, org.ID, service.UpdateOfferInput{
			CustomerID: &passive.ID, CustomerName: passive.Name, Notes: "miktar düzeltildi", Items: items,
		})
		if err != nil {
			t.Fatalf("bağlı taslağın düzenlenmesi engellenmemeli: %v", err)
		}
		if updated.CustomerID == nil || *updated.CustomerID != passive.ID {
			t.Errorf("taslak aynı karta bağlı kalmalı: %v", updated.CustomerID)
		}
	})

	t.Run("başka bir taslağa pasif müşteri yeni seçilemez", func(t *testing.T) {
		_, err := offerSvc.Update(ctx, otherDraft.ID, org.ID, service.UpdateOfferInput{
			CustomerID: &passive.ID, CustomerName: passive.Name, Items: items,
		})
		if !errors.Is(err, service.ErrOfferCustomerInactive) {
			t.Fatalf("taslağa pasif müşteri yeni bağlanamamalı: %v", err)
		}
	})

	t.Run("serbest metin müşteri etkilenmez", func(t *testing.T) {
		if _, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerName: "Kartsız Müşteri", Items: items,
		}); err != nil {
			t.Fatalf("kartsız teklif reddedilmemeli: %v", err)
		}
	})
}
