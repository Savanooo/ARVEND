package service_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// TestOfferValidUntil: geçerlilik tarihi (valid_until) güncellemede alan
// gönderilmezse korunur, müşteri kararı tarih geçtikten sonra reddedilir.
func TestOfferValidUntil(t *testing.T) {
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
	org := mustCreateOrg(t, ctx, orgSvc, pool, "Geçerlilik Test", "gecerlilik-test")

	istToday := func(offsetDays int) time.Time {
		n := time.Now().In(service.IstanbulLocation()).AddDate(0, 0, offsetDays)
		return time.Date(n.Year(), n.Month(), n.Day(), 0, 0, 0, 0, time.UTC)
	}
	items := []service.OfferItemInput{{ProductName: "Kalem", Quantity: 1, UnitPrice: 100}}
	newOffer := func(t *testing.T, validUntil *time.Time) *domain.Offer {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerName: "Müşteri", ValidUntil: validUntil, Items: items,
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		return o
	}
	// setValidUntil, doğrulamayı atlayıp tarihi doğrudan yazar -- "tarih
	// sonradan geçti" durumunu kurmak için.
	setValidUntil := func(t *testing.T, revisionID string, d time.Time) {
		t.Helper()
		if _, err := pool.Exec(ctx, "UPDATE offer_revisions SET valid_until = $2 WHERE id = $1", revisionID, d); err != nil {
			t.Fatal(err)
		}
	}
	sameDay := func(a *time.Time, b time.Time) bool {
		return a != nil && a.Format("2006-01-02") == b.Format("2006-01-02")
	}

	t.Run("update_without_field_preserves_date", func(t *testing.T) {
		d := istToday(10)
		o := newOffer(t, &d)
		updated, err := offerSvc.Update(ctx, o.ID, org.ID, service.UpdateOfferInput{CustomerName: "Müşteri", Items: items})
		if err != nil {
			t.Fatal(err)
		}
		if !sameDay(updated.ValidUntil, d) {
			t.Errorf("alan gönderilmeyince tarih korunmalı, gelen: %v", updated.ValidUntil)
		}
		cleared, err := offerSvc.Update(ctx, o.ID, org.ID, service.UpdateOfferInput{CustomerName: "Müşteri", Items: items, ValidUntilProvided: true})
		if err != nil {
			t.Fatal(err)
		}
		if cleared.ValidUntil != nil {
			t.Errorf("boş değer tarihi temizlemeli, gelen: %v", cleared.ValidUntil)
		}
		d2 := istToday(20)
		set, err := offerSvc.Update(ctx, o.ID, org.ID, service.UpdateOfferInput{CustomerName: "Müşteri", Items: items, ValidUntil: &d2, ValidUntilProvided: true})
		if err != nil || !sameDay(set.ValidUntil, d2) {
			t.Errorf("yeni tarih yazılmalı: %v err=%v", set.ValidUntil, err)
		}
	})

	t.Run("past_date_rejected", func(t *testing.T) {
		past := istToday(-1)
		if _, err := offerSvc.Create(ctx, service.CreateOfferInput{OrganizationID: org.ID, CustomerName: "M", ValidUntil: &past, Items: items}); !errors.Is(err, service.ErrOfferValidUntilInPast) {
			t.Errorf("geçmiş tarihli teklif oluşturulmamalı: %v", err)
		}
		o := newOffer(t, nil)
		if _, err := offerSvc.Update(ctx, o.ID, org.ID, service.UpdateOfferInput{CustomerName: "M", Items: items, ValidUntil: &past, ValidUntilProvided: true}); !errors.Is(err, service.ErrOfferValidUntilInPast) {
			t.Errorf("geçmiş tarih yazılmamalı: %v", err)
		}
		today := istToday(0)
		if _, err := offerSvc.Create(ctx, service.CreateOfferInput{OrganizationID: org.ID, CustomerName: "M", ValidUntil: &today, Items: items}); err != nil {
			t.Errorf("bugün geçerli bir tarih: %v", err)
		}
	})

	t.Run("customer_cannot_respond_after_valid_until", func(t *testing.T) {
		d := istToday(5)
		o := newOffer(t, &d)
		link, err := offerSvc.CreateShareLink(ctx, o.ID, org.ID, "", nil)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, org.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatal(err)
		}
		setValidUntil(t, o.CurrentRevisionID, istToday(-1))

		_, canRespond, err := offerSvc.GetByShareLinkToken(ctx, link.Token, "", "")
		if err != nil {
			t.Fatal(err)
		}
		if canRespond {
			t.Errorf("süresi dolmuş teklif için can_respond false olmalı")
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); !errors.Is(err, service.ErrOfferValidityExpired) {
			t.Fatalf("süresi dolmuş teklif kabul edilememeli: %v", err)
		}
		got, _ := offerSvc.Get(ctx, o.ID, org.ID)
		if got.Status != domain.OfferStatusGonderildi {
			t.Errorf("durum değişmemeli: %s", got.Status)
		}

		// valid_until = bugün: o gün dahil geçerlidir.
		setValidUntil(t, o.CurrentRevisionID, istToday(0))
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Errorf("geçerlilik günü içinde kabul edilebilmeli: %v", err)
		}
	})

	t.Run("expired_offer_cannot_be_sent_and_revise_drops_expired_date", func(t *testing.T) {
		o := newOffer(t, nil)
		setValidUntil(t, o.CurrentRevisionID, istToday(-3))
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, org.ID, domain.OfferStatusGonderildi, ""); !errors.Is(err, service.ErrOfferSendExpired) {
			t.Fatalf("süresi dolmuş taslak gönderilmemeli: %v", err)
		}
		if _, err := offerSvc.SendOfferEmail(ctx, o.ID, org.ID, "", service.SendOfferEmailInput{To: "musteri@example.com"}); !errors.Is(err, service.ErrOfferSendExpired) {
			t.Fatalf("süresi dolmuş teklif e-postayla gönderilmemeli: %v", err)
		}

		o2 := newOffer(t, nil)
		if _, err := offerSvc.UpdateStatus(ctx, o2.ID, org.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatal(err)
		}
		setValidUntil(t, o2.CurrentRevisionID, istToday(-3))
		revised, err := offerSvc.Revise(ctx, o2.ID, org.ID, "")
		if err != nil {
			t.Fatal(err)
		}
		if revised.ValidUntil != nil {
			t.Errorf("süresi dolmuş tarih yeni revizyona taşınmamalı: %v", revised.ValidUntil)
		}
	})
}

func TestOfferValidityExpiredUsesIstanbulDay(t *testing.T) {
	d := time.Date(2026, 3, 10, 0, 0, 0, 0, time.UTC)
	// 10 Mart 23:30 İstanbul = 20:30 UTC: hâlâ geçerli.
	if service.OfferValidityExpired(&d, time.Date(2026, 3, 10, 20, 30, 0, 0, time.UTC)) {
		t.Error("geçerlilik günü içinde süresi dolmuş sayılmamalı")
	}
	// 11 Mart 00:30 İstanbul = 10 Mart 21:30 UTC: süresi doldu.
	if !service.OfferValidityExpired(&d, time.Date(2026, 3, 10, 21, 30, 0, 0, time.UTC)) {
		t.Error("İstanbul'da ertesi gün süresi dolmuş sayılmalı")
	}
	if service.OfferValidityExpired(nil, time.Now()) {
		t.Error("tarihsiz teklif süresiz geçerlidir")
	}
}
