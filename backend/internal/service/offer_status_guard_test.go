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

// TestOfferCannotReturnToDraft: müşteriye gönderilmiş (veya karar verilmiş)
// bir revizyon "taslak"a geri alınamaz -- aksi halde Update() o revizyonu
// yerinde yeniden yazar, müşterinin elindeki hâlâ aktif link artık
// gönderilmemiş bir içeriği gösterirdi.
func TestOfferCannotReturnToDraft(t *testing.T) {
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
	org := mustCreateOrg(t, ctx, orgSvc, pool, "Taslak Geri Alma Test", "taslak-geri-alma-test")

	newOffer := func(t *testing.T) *domain.Offer {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID,
			CustomerName:   "Müşteri",
			Items:          []service.OfferItemInput{{ProductName: "Kalem", Quantity: 1, UnitPrice: 100}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		return o
	}

	for _, from := range []string{domain.OfferStatusGonderildi, domain.OfferStatusReddedildi} {
		t.Run("from_"+from, func(t *testing.T) {
			o := newOffer(t)
			if _, err := offerSvc.UpdateStatus(ctx, o.ID, org.ID, from, ""); err != nil {
				t.Fatalf("durum %q yapılamadı: %v", from, err)
			}
			_, err := offerSvc.UpdateStatus(ctx, o.ID, org.ID, domain.OfferStatusTaslak, "")
			if !errors.Is(err, service.ErrOfferCannotReturnToDraft) {
				t.Fatalf("%q -> taslak reddedilmeliydi, err=%v", from, err)
			}
			got, err := offerSvc.Get(ctx, o.ID, org.ID)
			if err != nil {
				t.Fatalf("teklif okunamadı: %v", err)
			}
			if got.Status != from {
				t.Errorf("durum değişmemeliydi: beklenen %q, gelen %q", from, got.Status)
			}
			// Gönderilmiş revizyon hâlâ yerinde düzenlenemez.
			if _, err := offerSvc.Update(ctx, o.ID, org.ID, service.UpdateOfferInput{
				CustomerName: "Sessiz değişiklik",
				Items:        []service.OfferItemInput{{ProductName: "X", Quantity: 1, UnitPrice: 1}},
			}); !errors.Is(err, service.ErrOfferNotEditable) {
				t.Errorf("gönderilmiş revizyon düzenlenebildi: err=%v", err)
			}
		})
	}

	t.Run("draft_to_draft_is_noop", func(t *testing.T) {
		o := newOffer(t)
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, org.ID, domain.OfferStatusTaslak, ""); err != nil {
			t.Fatalf("taslak -> taslak hata vermemeli: %v", err)
		}
	})

	t.Run("revise_still_opens_a_new_draft", func(t *testing.T) {
		o := newOffer(t)
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, org.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		revised, err := offerSvc.Revise(ctx, o.ID, org.ID, "")
		if err != nil {
			t.Fatalf("revize edilemedi: %v", err)
		}
		if revised.Status != domain.OfferStatusTaslak || revised.RevisionNo != 1 {
			t.Errorf("Revize Et yeni taslak revizyon açmalı: status=%q rev=%d", revised.Status, revised.RevisionNo)
		}
	})
}
