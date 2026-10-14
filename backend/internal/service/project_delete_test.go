package service_test

// Proje silme (migration 0070): para hareketi olmayan proje bütün
// kayıtlarıyla (otomatik bütçe/sözleşme, ödeme planı, taşeron kaydı…)
// silinir ve kaynak teklif yeniden dönüştürülebilir; para hareketi olan
// proje silinmez. Silme talebi teklifteki akışla aynı.

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestProjectDelete(t *testing.T) {
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
	settingsSvc := service.NewSettingsService(q, testSecretBox(t))
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000")

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Proje Silme Org", "proje-silme-test")
	orgUUID, _ := repository.StringToUUID(org.ID)
	if err := q.SeedSystemRolesForOrg(ctx, orgUUID); err != nil {
		t.Fatalf("rol seed: %v", err)
	}
	suffix := fmt.Sprintf("%d", time.Now().UnixNano()%1_000_000_000)
	owner, err := userSvc.Create(ctx, org.ID, "ps_owner_"+suffix, "GeciciSifre123!", "Firma Sahibi", domain.RoleAdmin, domain.OrgRoleOwner)
	if err != nil {
		t.Fatal(err)
	}
	pm, err := userSvc.Create(ctx, org.ID, "ps_pm_"+suffix, "GeciciSifre123!", "Proje Yöneticisi", domain.RoleKullanici, domain.OrgRoleProjectManager)
	if err != nil {
		t.Fatal(err)
	}
	today := time.Date(2026, 10, 14, 0, 0, 0, 0, time.UTC)

	newProject := func(t *testing.T) (*domain.Project, string) {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerName: "Müşteri", VatRate: ptrFloat(0),
			Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 50000}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, org.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatal(err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, org.ID, "", nil)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatal(err)
		}
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, org.ID, service.CreateProjectInput{Name: "Silinecek Proje"})
		if err != nil {
			t.Fatal(err)
		}
		return p, o.ID
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

	t.Run("para hareketi olmayan proje bütün kayıtlarıyla silinir, teklif serbest kalır", func(t *testing.T) {
		p, offerID := newProject(t)
		// Para hareketi olmayan kayıtlar silmeyi engellemez.
		if _, err := projectSvc.CreateSubcontractor(ctx, p.ID, org.ID, service.SubcontractorInput{
			Name: "Silme Testi Usta", ContractAmount: 1000, Currency: "TRY",
		}); err != nil {
			t.Fatal(err)
		}
		if err := projectSvc.DeleteProject(ctx, p.ID, org.ID, owner.ID); err != nil {
			t.Fatalf("silinmeli: %v", err)
		}
		if _, err := projectSvc.Get(ctx, p.ID, org.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("proje gitmeli, geldi %v", err)
		}
		if _, err := projectSvc.GetByOfferID(ctx, offerID, org.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("teklif yeniden dönüştürülebilmeli (bağ kalmamalı), geldi %v", err)
		}
		events, err := offerSvc.ListEvents(ctx, offerID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		found := false
		for _, e := range events {
			if e.EventType == domain.EventProjectDeleted {
				found = true
			}
		}
		if !found {
			t.Fatal("teklifin zaman çizelgesine project_deleted yazılmalı")
		}
		if _, err := projectSvc.CreateFromOffer(ctx, offerID, org.ID, service.CreateProjectInput{Name: "Yeniden"}); err != nil {
			t.Fatalf("teklif yeniden projeye dönüştürülebilmeli: %v", err)
		}
	})

	t.Run("masrafı olan proje silinmez, talep de açılmaz", func(t *testing.T) {
		p, _ := newProject(t)
		if _, err := projectSvc.CreateExpense(ctx, p.ID, org.ID, service.ExpenseInput{
			Category: "material", Description: "Çimento", Amount: 500, ExpenseDate: today, UserID: owner.ID,
		}); err != nil {
			t.Fatal(err)
		}
		err := projectSvc.DeleteProject(ctx, p.ID, org.ID, owner.ID)
		if !errors.Is(err, service.ErrProjectHasRecords) || !strings.Contains(err.Error(), "1 masraf") {
			t.Fatalf("masraflı proje: beklenen ErrProjectHasRecords (1 masraf), geldi %v", err)
		}
		if _, err := projectSvc.RequestProjectDelete(ctx, p.ID, org.ID, pm.ID, ""); !errors.Is(err, service.ErrProjectHasRecords) {
			t.Fatalf("masraflı projeye talep: beklenen ErrProjectHasRecords, geldi %v", err)
		}
		if _, err := projectSvc.Get(ctx, p.ID, org.ID); err != nil {
			t.Fatalf("proje yerinde kalmalı: %v", err)
		}
	})

	t.Run("silme talebi: tekrar yok, başkası geri çekemez, ret ve onay bildirilir", func(t *testing.T) {
		p, _ := newProject(t)
		req, err := projectSvc.RequestProjectDelete(ctx, p.ID, org.ID, pm.ID, "yanlış tekliften açıldı")
		if err != nil {
			t.Fatal(err)
		}
		if req.RequestedByName != "Proje Yöneticisi" {
			t.Fatalf("talep eden adı: %+v", req)
		}
		pending, err := projectSvc.PendingProjectDeleteRequest(ctx, p.ID, org.ID)
		if err != nil || pending == nil || pending.Reason != "yanlış tekliften açıldı" {
			t.Fatalf("bekleyen talep görünmeli: %+v %v", pending, err)
		}
		if _, err := projectSvc.RequestProjectDelete(ctx, p.ID, org.ID, pm.ID, ""); !errors.Is(err, service.ErrProjectDeleteAlreadyRequested) {
			t.Fatalf("ikinci talep: beklenen ErrProjectDeleteAlreadyRequested, geldi %v", err)
		}
		if err := projectSvc.WithdrawProjectDeleteRequest(ctx, p.ID, org.ID, owner.ID); !errors.Is(err, service.ErrProjectDeleteRequestNotOwn) {
			t.Fatalf("başkası geri çekememeli, geldi %v", err)
		}
		list, err := projectSvc.ListPendingProjectDeleteRequests(ctx, org.ID)
		if err != nil || len(list) == 0 || list[0].ProjectNo == "" {
			t.Fatalf("onay listesinde proje özetiyle görünmeli: %+v %v", list, err)
		}
		if n := notifCount(t, owner.ID, domain.NotificationProjectDeleteRequested); n < 1 {
			t.Fatal("sahibe silme talebi bildirimi gitmeli")
		}

		beforeRej := notifCount(t, pm.ID, domain.NotificationProjectDeleteRejected)
		if err := projectSvc.RejectProjectDeleteRequest(ctx, p.ID, org.ID, owner.ID, "devam ediyor"); err != nil {
			t.Fatal(err)
		}
		if notifCount(t, pm.ID, domain.NotificationProjectDeleteRejected) != beforeRej+1 {
			t.Fatal("ret bildirimi gitmeli")
		}
		if pending, _ := projectSvc.PendingProjectDeleteRequest(ctx, p.ID, org.ID); pending != nil {
			t.Fatal("reddedilen talep bekliyor görünmemeli")
		}

		if _, err := projectSvc.RequestProjectDelete(ctx, p.ID, org.ID, pm.ID, ""); err != nil {
			t.Fatal(err)
		}
		beforeOK := notifCount(t, pm.ID, domain.NotificationProjectDeleteApproved)
		if err := projectSvc.ApproveProjectDeleteRequest(ctx, p.ID, org.ID, owner.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.Get(ctx, p.ID, org.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("onaylanan talepte proje silinmeli, geldi %v", err)
		}
		if notifCount(t, pm.ID, domain.NotificationProjectDeleteApproved) != beforeOK+1 {
			t.Fatal("onay bildirimi proje silinse de kalmalı")
		}
	})

	t.Run("başka firmanın projesi silinemez", func(t *testing.T) {
		p, _ := newProject(t)
		other := mustCreateOrg(t, ctx, orgSvc, pool, "Başka Firma PS", "proje-silme-test-2")
		if err := projectSvc.DeleteProject(ctx, p.ID, other.ID, owner.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("beklenen ErrNotFound, geldi %v", err)
		}
		if _, err := projectSvc.Get(ctx, p.ID, org.ID); err != nil {
			t.Fatalf("proje yerinde kalmalı: %v", err)
		}
	})
}
