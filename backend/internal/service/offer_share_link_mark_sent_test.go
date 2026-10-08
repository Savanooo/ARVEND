package service_test

// "Gönder ve link oluştur" (POST /offers/{id}/share-links, mark_sent:true):
// sahadan gelen şikâyet "teklif atıyoruz, link vb., teklif kabul etme yok"
// -- taslak teklifin linki müşteriye gidiyor, sayfada Kabul Et / Reddet
// çıkmıyordu. Bu testler, işaretlemenin UpdateStatus ile aynı sonuçları
// (olay, önceki linklerin iptali, süre kontrolü) ürettiğini ve işaretleme
// istenmeyen linkin bugünkü gibi önizleme olarak kaldığını sabitler. Yetki
// (offers.approve) HTTP katmanında: bkz. middleware/offer_share_link_mark_sent_security_test.go.
// Gerçek PostgreSQL gerektirir.

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

func TestShareLinkMarkSent(t *testing.T) {
	dbURL := testDBURL(t)
	box := testSecretBox(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	q := sqlc.New(pool)
	userSvc := service.NewUserService(pool, q)
	settingsSvc := service.NewSettingsService(q, box)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	notifSvc := service.NewNotificationService(q)
	platformSvc := service.NewPlatformService(pool, q, userSvc, service.NewCalcService(q), service.NewProductService(q))

	newOrg := func(t *testing.T, slug string) (orgID, ownerID string) {
		t.Helper()
		var existing string
		if pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug).Scan(&existing) == nil {
			cleanupOrganization(t, pool, existing)
		}
		created, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
			Name: "Link Gönder " + slug, Slug: slug,
			OwnerUsername: "owner_" + slug, OwnerPassword: "GeciciSifre123!", OwnerFullName: "Firma Sahibi",
		})
		if err != nil {
			t.Fatalf("firma+sahip oluşturulamadı: %v", err)
		}
		t.Cleanup(func() { cleanupOrganization(t, pool, created.Organization.ID) })
		return created.Organization.ID, created.Owner.ID
	}
	orgA, ownerA := newOrg(t, "link-gonder-test-a")
	orgB, ownerB := newOrg(t, "link-gonder-test-b")

	newOffer := func(t *testing.T) *domain.Offer {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgA, UserID: ownerA, CustomerName: "Ahmet Yılmaz",
			Items: []service.OfferItemInput{{ProductName: "Çatı yenileme", Quantity: 1, UnitPrice: 1000}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		return o
	}
	countEvents := func(t *testing.T, offerID, eventType string) int {
		t.Helper()
		events, err := offerSvc.ListEvents(ctx, offerID, orgA)
		if err != nil {
			t.Fatalf("olaylar alınamadı: %v", err)
		}
		n := 0
		for _, e := range events {
			if e.EventType == eventType {
				n++
			}
		}
		return n
	}
	firstOpenNotices := func(t *testing.T, offerID string) int {
		t.Helper()
		res, err := notifSvc.List(ctx, ownerA, orgA, 1, 100)
		if err != nil {
			t.Fatalf("bildirimler alınamadı: %v", err)
		}
		n := 0
		for _, x := range res.Notifications {
			if x.Type == domain.NotificationOfferViewed && x.EntityID != nil && *x.EntityID == offerID {
				n++
			}
		}
		return n
	}
	statusOf := func(t *testing.T, offerID string) string {
		t.Helper()
		o, err := offerSvc.Get(ctx, offerID, orgA)
		if err != nil {
			t.Fatalf("teklif okunamadı: %v", err)
		}
		return o.Status
	}
	linkCount := func(t *testing.T, offerID string) int {
		t.Helper()
		links, err := offerSvc.ListShareLinks(ctx, offerID, orgA)
		if err != nil {
			t.Fatalf("linkler alınamadı: %v", err)
		}
		return len(links)
	}

	t.Run("draft_mark_sent_customer_can_respond", func(t *testing.T) {
		o := newOffer(t)
		link, err := offerSvc.CreateShareLinkMarkingSent(ctx, o.ID, orgA, ownerA, nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		if got := statusOf(t, o.ID); got != domain.OfferStatusGonderildi {
			t.Fatalf("teklif durumu %q, beklenen gönderildi", got)
		}
		if link.RevisionID != o.CurrentRevisionID {
			t.Errorf("link güncel revizyona bağlanmadı: %s, beklenen %s", link.RevisionID, o.CurrentRevisionID)
		}
		if n := countEvents(t, o.ID, domain.EventRevisionSent); n != 1 {
			t.Errorf("revision_sent %d kez, beklenen 1", n)
		}
		if n := countEvents(t, o.ID, domain.EventShareLinkCreated); n != 1 {
			t.Errorf("share_link_created %d kez, beklenen 1", n)
		}

		view, err := offerSvc.GetPublicView(ctx, link.Token, "", "Mozilla/5.0")
		if err != nil {
			t.Fatalf("müşteri sayfası açılamadı: %v", err)
		}
		if !view.CanRespond {
			t.Error("gönderilen linkte müşteri kabul/red yapabilmeli (can_respond)")
		}
		if view.Offer.Status != domain.OfferStatusGonderildi {
			t.Errorf("müşteri sayfası durumu %q, beklenen gönderildi", view.Offer.Status)
		}
		if n := firstOpenNotices(t, o.ID); n != 1 {
			t.Errorf("ilk açılış bildirimi %d kez, beklenen 1", n)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatalf("müşteri linkten kabul edemedi: %v", err)
		}
	})

	t.Run("draft_without_mark_sent_stays_preview", func(t *testing.T) {
		o := newOffer(t)
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgA, ownerA, nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		if got := statusOf(t, o.ID); got != domain.OfferStatusTaslak {
			t.Fatalf("işaretleme istenmeden durum değişti: %q", got)
		}
		if n := countEvents(t, o.ID, domain.EventRevisionSent); n != 0 {
			t.Errorf("önizleme linki revision_sent üretmemeli, %d kez", n)
		}
		view, err := offerSvc.GetPublicView(ctx, link.Token, "", "Mozilla/5.0")
		if err != nil {
			t.Fatalf("önizleme açılamadı: %v", err)
		}
		if view.CanRespond {
			t.Error("taslak önizlemesinde kabul/red açık olmamalı")
		}
		if view.Offer.Status != domain.OfferStatusTaslak {
			t.Errorf("önizleme durumu %q, beklenen taslak", view.Offer.Status)
		}
		if n := firstOpenNotices(t, o.ID); n != 0 {
			t.Errorf("taslak önizlemesi ilk açılış bildirimi üretmemeli, %d kez", n)
		}
	})

	t.Run("already_sent_mark_sent_is_noop", func(t *testing.T) {
		o := newOffer(t)
		first, err := offerSvc.CreateShareLinkMarkingSent(ctx, o.ID, orgA, ownerA, nil)
		if err != nil {
			t.Fatal(err)
		}
		second, err := offerSvc.CreateShareLinkMarkingSent(ctx, o.ID, orgA, ownerA, nil)
		if err != nil {
			t.Fatalf("gönderilmiş teklife ikinci link oluşturulamadı: %v", err)
		}
		if n := countEvents(t, o.ID, domain.EventRevisionSent); n != 1 {
			t.Errorf("zaten gönderilmiş teklif yeniden gönderilmiş sayıldı: revision_sent %d kez", n)
		}
		if n := countEvents(t, o.ID, domain.EventShareLinkRevoked); n != 0 {
			t.Errorf("aynı revizyonun linki iptal edilmemeli, share_link_revoked %d kez", n)
		}
		for _, l := range []string{first.Token, second.Token} {
			view, err := offerSvc.GetPublicView(ctx, l, "", "")
			if err != nil {
				t.Fatalf("link açılamadı: %v", err)
			}
			if !view.CanRespond {
				t.Error("aynı gönderilmiş revizyonun iki linki de karar verilebilir olmalı")
			}
		}

		// Karar verilmiş teklif: işaretleme yine dokunmaz (kabul kilidi
		// bozulmaz), link bugünkü gibi oluşur.
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA, domain.OfferStatusReddedildi, ownerA); err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.CreateShareLinkMarkingSent(ctx, o.ID, orgA, ownerA, nil); err != nil {
			t.Fatalf("reddedilmiş teklife link oluşturulamadı: %v", err)
		}
		if got := statusOf(t, o.ID); got != domain.OfferStatusReddedildi {
			t.Errorf("reddedilmiş teklifin durumu değişti: %q", got)
		}
	})

	t.Run("revised_draft_mark_sent_revokes_previous_revision_links", func(t *testing.T) {
		o := newOffer(t)
		old, err := offerSvc.CreateShareLinkMarkingSent(ctx, o.ID, orgA, ownerA, nil)
		if err != nil {
			t.Fatal(err)
		}
		revised, err := offerSvc.Revise(ctx, o.ID, orgA, ownerA)
		if err != nil {
			t.Fatalf("revize edilemedi: %v", err)
		}
		link, err := offerSvc.CreateShareLinkMarkingSent(ctx, o.ID, orgA, ownerA, nil)
		if err != nil {
			t.Fatalf("revizyonun linki oluşturulamadı: %v", err)
		}
		if link.RevisionID != revised.CurrentRevisionID {
			t.Errorf("link yeni revizyona bağlanmadı: %s, beklenen %s", link.RevisionID, revised.CurrentRevisionID)
		}
		if _, _, err := offerSvc.GetByShareLinkToken(ctx, old.Token, "", ""); !errors.Is(err, service.ErrShareLinkRevoked) {
			t.Errorf("önceki revizyonun linki iptal edilmeli: err=%v", err)
		}
		if n := countEvents(t, o.ID, domain.EventRevisionSent); n != 2 {
			t.Errorf("revision_sent %d kez, beklenen 2 (her revizyon bir kez)", n)
		}
		if _, canRespond, err := offerSvc.GetByShareLinkToken(ctx, link.Token, "", ""); err != nil || !canRespond {
			t.Errorf("yeni revizyonun linki karar verilebilir olmalı: canRespond=%v err=%v", canRespond, err)
		}
	})

	t.Run("expired_draft_mark_sent_creates_no_link", func(t *testing.T) {
		o := newOffer(t)
		if _, err := pool.Exec(ctx, "UPDATE offer_revisions SET valid_until = $2 WHERE id = $1",
			o.CurrentRevisionID, time.Now().AddDate(0, 0, -3)); err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.CreateShareLinkMarkingSent(ctx, o.ID, orgA, ownerA, nil); !errors.Is(err, service.ErrOfferSendExpired) {
			t.Fatalf("süresi geçmiş taslak gönderilmemeli: err=%v", err)
		}
		if got := statusOf(t, o.ID); got != domain.OfferStatusTaslak {
			t.Errorf("başarısız işaretlemede durum değişti: %q", got)
		}
		if n := linkCount(t, o.ID); n != 0 {
			t.Errorf("işaretleme başarısızken link oluşmamalı, %d link var", n)
		}
		if n := countEvents(t, o.ID, domain.EventShareLinkCreated); n != 0 {
			t.Errorf("share_link_created yazılmamalı, %d kez", n)
		}
	})

	t.Run("tenant_isolation", func(t *testing.T) {
		o := newOffer(t)
		if _, err := offerSvc.CreateShareLinkMarkingSent(ctx, o.ID, orgB, ownerB, nil); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("başka firmanın teklifi işaretlenmemeli: err=%v", err)
		}
		if got := statusOf(t, o.ID); got != domain.OfferStatusTaslak {
			t.Errorf("başka firmanın isteği durumu değiştirdi: %q", got)
		}
		if n := linkCount(t, o.ID); n != 0 {
			t.Errorf("başka firmanın isteği link oluşturdu: %d", n)
		}
	})
}
