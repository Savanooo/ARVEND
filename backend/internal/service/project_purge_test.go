package service_test

// Proje temizliği (cmd/purge-project): iptal edilmiş, para hareketi olan
// proje bütün kayıtlarıyla silinir; başka projeye dokunulmaz; iptal
// edilmemiş proje silinmez.

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestPurgeCancelledProject(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	settingsSvc := service.NewSettingsService(q, testSecretBox(t))
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000")
	inv := service.NewInventoryService(pool, q, mustTestStore(t))

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Temizlik Org", "proje-temizlik-test")
	newProject := func(t *testing.T, name string) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerName: "Müşteri", VatRate: ptrFloat(0),
			Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 100000}},
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
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, org.ID, service.CreateProjectInput{Name: name})
		if err != nil {
			t.Fatal(err)
		}
		return p
	}
	fill := func(t *testing.T, p *domain.Project) {
		t.Helper()
		today := time.Now()
		if _, err := projectSvc.CreateExpense(ctx, p.ID, org.ID, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Çimento", Amount: 500, Currency: "TRY", ExpenseDate: today,
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.CreateCollection(ctx, p.ID, org.ID, service.CollectionInput{
			Amount: 1000, Currency: "TRY", ReceivedDate: today, PaymentMethod: "bank_transfer", IdempotencyKey: "purge-" + p.ID,
		}); err != nil {
			t.Fatal(err)
		}
		sub, err := projectSvc.CreateSubcontractor(ctx, p.ID, org.ID, service.SubcontractorInput{
			Name: "Temizlik Ustası " + p.Name, ContractAmount: 2000, Currency: "TRY",
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.CreateSubcontractorPayment(ctx, p.ID, sub.ID, org.ID, service.SubcontractorPaymentInput{
			Amount: 300, Currency: "TRY", PaidDate: today, IdempotencyKey: "purge-sp-" + p.ID,
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.CreateTask(ctx, p.ID, org.ID, service.TaskInput{Title: "Görev"}); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.SaveDailyReport(ctx, p.ID, org.ID, service.IstanbulToday(), service.DailyReportInput{WorkDone: "İş"}); err != nil {
			t.Fatal(err)
		}
		png := append([]byte{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A}, []byte(p.ID)...)
		if _, err := projectSvc.UploadPhoto(ctx, p.ID, org.ID, service.UploadInput{
			OriginalName: "f.png", Reader: bytes.NewReader(png), Stage: domain.PhotoStageProgress,
		}); err != nil {
			t.Fatal(err)
		}
	}

	doomed := newProject(t, "Silinecek")
	kept := newProject(t, "Kalacak")
	fill(t, doomed)
	fill(t, kept)

	// Stok fişi silinen projeye bağlıysa fiş kalır, bağ düşer.
	whs, err := inv.ListWarehouses(ctx, org.ID)
	if err != nil {
		t.Fatal(err)
	}
	item, err := inv.CreateItem(ctx, org.ID, service.InventoryItemInput{Name: "Kum"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
		Type: service.InventoryDocReceipt, WarehouseID: whs[0].ID,
		Lines: []service.InventoryLineInput{{ItemID: item.ID, Quantity: 5}},
	}); err != nil {
		t.Fatal(err)
	}
	issue, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
		Type: service.InventoryDocIssue, WarehouseID: whs[0].ID, ProjectID: doomed.ID,
		Lines: []service.InventoryLineInput{{ItemID: item.ID, Quantity: 2}},
	})
	if err != nil {
		t.Fatal(err)
	}

	found, err := service.FindProjectsForPurge(ctx, pool, doomed.ProjectNo, "proje-temizlik-test")
	if err != nil {
		t.Fatal(err)
	}
	if len(found) != 1 || found[0].ID != doomed.ID {
		t.Fatalf("proje numarasıyla bulunmalı: %+v", found)
	}

	if _, err := service.PurgeCancelledProject(ctx, pool, doomed.ID); !errors.Is(err, service.ErrProjectNotCancelled) {
		t.Fatalf("iptal edilmemiş proje silinmemeli: %v", err)
	}
	if _, err := projectSvc.Update(ctx, doomed.ID, org.ID, service.UpdateProjectInput{Name: doomed.Name, Status: domain.ProjectStatusCancelled}); err != nil {
		t.Fatal(err)
	}
	before, err := service.CountProjectPurge(ctx, pool, doomed.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(before) < 8 {
		t.Fatalf("deneme sayımı bağlı kayıtları göstermeli: %+v", before)
	}
	keptBefore, err := service.CountProjectPurge(ctx, pool, kept.ID)
	if err != nil {
		t.Fatal(err)
	}

	keys, err := service.PurgeCancelledProject(ctx, pool, doomed.ID)
	if err != nil {
		t.Fatalf("silinmeli: %v", err)
	}
	if len(keys) != 1 {
		t.Errorf("silinecek dosya anahtarı: %v", keys)
	}
	after, err := service.CountProjectPurge(ctx, pool, doomed.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != 0 {
		t.Errorf("hiç kayıt kalmamalı: %+v", after)
	}
	if _, err := projectSvc.Get(ctx, doomed.ID, org.ID); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("proje gitmeli: %v", err)
	}
	keptAfter, err := service.CountProjectPurge(ctx, pool, kept.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(keptAfter) != len(keptBefore) {
		t.Errorf("öbür projeye dokunulmamalı: önce %+v sonra %+v", keptBefore, keptAfter)
	}
	doc, err := inv.GetDocument(ctx, org.ID, issue.ID)
	if err != nil {
		t.Fatalf("stok fişi kalmalı: %v", err)
	}
	if doc.ProjectID != "" {
		t.Errorf("stok fişinin proje bağı düşmeli: %q", doc.ProjectID)
	}
}
