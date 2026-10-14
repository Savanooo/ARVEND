package service_test

// Teklif silme talebi (migration 0067): silme izni olmayan kişi talep açar,
// silme yetkilisi onaylar (teklif silinir) ya da reddeder; talep eden geri
// çekebilir. İzin kapıları router'da -- burada durum kuralları, bildirimler
// ve teklif detayındaki "bekleyen talep" alanı.

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestOfferDeleteRequest(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	userSvc := service.NewUserService(pool, q)
	notifSvc := service.NewNotificationService(q)
	offerSvc := service.NewOfferService(pool, q, service.NewSettingsService(q, testSecretBox(t)), "http://localhost:3000")

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Silme Talebi Org", "teklif-silme-talebi")
	orgUUID, _ := repository.StringToUUID(org.ID)
	if err := q.SeedSystemRolesForOrg(ctx, orgUUID); err != nil {
		t.Fatalf("rol seed: %v", err)
	}
	suffix := fmt.Sprintf("%d", time.Now().UnixNano()%1_000_000_000)
	owner, err := userSvc.Create(ctx, org.ID, "sil_owner_"+suffix, "GeciciSifre123!", "Firma Sahibi", domain.RoleAdmin, domain.OrgRoleOwner)
	if err != nil {
		t.Fatal(err)
	}
	requester, err := userSvc.Create(ctx, org.ID, "sil_talep_"+suffix, "GeciciSifre123!", "Satış Personeli", domain.RoleKullanici, domain.OrgRoleField)
	if err != nil {
		t.Fatal(err)
	}
	other, err := userSvc.Create(ctx, org.ID, "sil_diger_"+suffix, "GeciciSifre123!", "Başka Biri", domain.RoleKullanici, domain.OrgRoleField)
	if err != nil {
		t.Fatal(err)
	}

	newOffer := func(t *testing.T) *domain.Offer {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, UserID: requester.ID, CustomerName: "Müşteri",
			Items: []service.OfferItemInput{{ProductName: "Kalem", Quantity: 1, UnitPrice: 100}},
		})
		if err != nil {
			t.Fatal(err)
		}
		return o
	}
	notifCount := func(t *testing.T, userID, typ string) int {
		t.Helper()
		res, err := notifSvc.List(ctx, userID, org.ID, 1, 100)
		if err != nil {
			t.Fatal(err)
		}
		n := 0
		for _, x := range res.Notifications {
			if x.Type == typ {
				n++
			}
		}
		return n
	}
	pendingOn := func(t *testing.T, offerID string) *domain.OfferDeleteRequest {
		t.Helper()
		got, err := offerSvc.Get(ctx, offerID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		return got.DeleteRequest
	}

	t.Run("talep açılır, detayda görünür, ikinci talep reddedilir, sahibe bildirim gider", func(t *testing.T) {
		o := newOffer(t)
		req, err := offerSvc.RequestDelete(ctx, o.ID, org.ID, requester.ID, "  yanlış müşteriye açıldı  ")
		if err != nil {
			t.Fatal(err)
		}
		if req.Reason != "yanlış müşteriye açıldı" || req.RequestedByName != "Satış Personeli" {
			t.Fatalf("talep alanları: %+v", req)
		}
		p := pendingOn(t, o.ID)
		if p == nil || p.ID != req.ID || p.RequestedByName != "Satış Personeli" {
			t.Fatalf("teklif detayında bekleyen talep olmalı: %+v", p)
		}
		if _, err := offerSvc.RequestDelete(ctx, o.ID, org.ID, other.ID, ""); !errors.Is(err, service.ErrOfferDeleteAlreadyRequested) {
			t.Fatalf("ikinci talep: beklenen ErrOfferDeleteAlreadyRequested, geldi %v", err)
		}
		if n := notifCount(t, owner.ID, domain.NotificationOfferDeleteRequested); n < 1 {
			t.Fatal("firma sahibine silme talebi bildirimi gitmeli")
		}
		if n := notifCount(t, requester.ID, domain.NotificationOfferDeleteRequested); n != 0 {
			t.Fatal("talep eden kendi talebinin bildirimini almamalı")
		}
		list, err := offerSvc.ListPendingDeleteRequests(ctx, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		found := false
		for _, r := range list {
			if r.OfferID == o.ID && r.OfferNo == o.OfferNo && r.GrandTotal > 0 {
				found = true
			}
		}
		if !found {
			t.Fatalf("onay listesinde teklif özetiyle görünmeli: %+v", list)
		}
	})

	t.Run("yalnızca talep eden geri çekebilir", func(t *testing.T) {
		o := newOffer(t)
		if _, err := offerSvc.RequestDelete(ctx, o.ID, org.ID, requester.ID, ""); err != nil {
			t.Fatal(err)
		}
		if err := offerSvc.WithdrawDeleteRequest(ctx, o.ID, org.ID, other.ID); !errors.Is(err, service.ErrOfferDeleteRequestNotOwn) {
			t.Fatalf("başkası geri çekememeli, geldi %v", err)
		}
		if err := offerSvc.WithdrawDeleteRequest(ctx, o.ID, org.ID, requester.ID); err != nil {
			t.Fatal(err)
		}
		if pendingOn(t, o.ID) != nil {
			t.Fatal("geri çekilen talep bekliyor görünmemeli")
		}
		// Geri çekildikten sonra yeniden talep açılabilir.
		if _, err := offerSvc.RequestDelete(ctx, o.ID, org.ID, requester.ID, ""); err != nil {
			t.Fatalf("yeniden talep açılabilmeli: %v", err)
		}
	})

	t.Run("ret: teklif kalır, talep edene gerekçeyle bildirilir", func(t *testing.T) {
		o := newOffer(t)
		if _, err := offerSvc.RequestDelete(ctx, o.ID, org.ID, requester.ID, ""); err != nil {
			t.Fatal(err)
		}
		before := notifCount(t, requester.ID, domain.NotificationOfferDeleteRejected)
		if err := offerSvc.RejectDeleteRequest(ctx, o.ID, org.ID, owner.ID, "müşteri hâlâ düşünüyor"); err != nil {
			t.Fatal(err)
		}
		if pendingOn(t, o.ID) != nil {
			t.Fatal("reddedilen talep bekliyor görünmemeli")
		}
		if notifCount(t, requester.ID, domain.NotificationOfferDeleteRejected) != before+1 {
			t.Fatal("talep edene ret bildirimi gitmeli")
		}
		if err := offerSvc.RejectDeleteRequest(ctx, o.ID, org.ID, owner.ID, ""); !errors.Is(err, service.ErrOfferDeleteRequestNotFound) {
			t.Fatalf("bekleyen talep yokken ret: beklenen ErrOfferDeleteRequestNotFound, geldi %v", err)
		}
	})

	t.Run("onay: teklif silinir, talep edene bildirilir", func(t *testing.T) {
		o := newOffer(t)
		if _, err := offerSvc.RequestDelete(ctx, o.ID, org.ID, requester.ID, ""); err != nil {
			t.Fatal(err)
		}
		before := notifCount(t, requester.ID, domain.NotificationOfferDeleteApproved)
		if err := offerSvc.ApproveDeleteRequest(ctx, o.ID, org.ID, owner.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.Get(ctx, o.ID, org.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("onaylanan talepte teklif silinmeli, geldi %v", err)
		}
		if notifCount(t, requester.ID, domain.NotificationOfferDeleteApproved) != before+1 {
			t.Fatal("talep edene onay bildirimi gitmeli")
		}
	})

	t.Run("kabul edilmiş teklif için talep açılamaz", func(t *testing.T) {
		o := newOffer(t)
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, org.ID, domain.OfferStatusGonderildi, owner.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, org.ID, domain.OfferStatusKabulEdildi, owner.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.RequestDelete(ctx, o.ID, org.ID, requester.ID, ""); !errors.Is(err, service.ErrOfferAccepted) {
			t.Fatalf("beklenen ErrOfferAccepted, geldi %v", err)
		}
	})

	t.Run("başka firmanın teklifine talep açılamaz", func(t *testing.T) {
		o := newOffer(t)
		otherOrg := mustCreateOrg(t, ctx, orgSvc, pool, "Başka Firma", "teklif-silme-talebi-2")
		if _, err := offerSvc.RequestDelete(ctx, o.ID, otherOrg.ID, requester.ID, ""); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("beklenen ErrNotFound, geldi %v", err)
		}
		if err := offerSvc.ApproveDeleteRequest(ctx, o.ID, otherOrg.ID, owner.ID); !errors.Is(err, service.ErrOfferDeleteRequestNotFound) {
			t.Fatalf("başka firmadan onay: beklenen ErrOfferDeleteRequestNotFound, geldi %v", err)
		}
	})
}
