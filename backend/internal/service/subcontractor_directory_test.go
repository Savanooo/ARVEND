package service_test

// Taşeronlar (migration 0069): kart = tedarikçi (is_subcontractor);
// projedeki basit taşeron kaydı karta bağlanır (kart verilmezse aynı adlı
// kart bulunur/açılır); proje dışı ödemeler kartın kendisine yazılır ve
// taşeronun defteri hepsini tek listede gösterir.

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

func TestSubcontractorDirectory(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	box := testSecretBox(t)
	orgSvc := service.NewOrganizationService(q)
	settingsSvc := service.NewSettingsService(q, box)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000")
	supplierSvc := service.NewSupplierService(pool, q, box)

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Taşeron Org", "taseron-rehberi-test")
	today := time.Date(2026, 10, 14, 0, 0, 0, 0, time.UTC)

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
	cardByID := func(t *testing.T, id string, withTotals bool) domain.SubcontractorCard {
		t.Helper()
		cards, err := supplierSvc.ListSubcontractorCards(ctx, org.ID, withTotals, "")
		if err != nil {
			t.Fatal(err)
		}
		for _, c := range cards {
			if c.ID == id {
				return c
			}
		}
		t.Fatalf("kart listede yok: %s", id)
		return domain.SubcontractorCard{}
	}

	p1 := newProject(t, "Kadıköy")
	p2 := newProject(t, "Üsküdar")

	t.Run("kart açılır, kod otomatik verilir", func(t *testing.T) {
		card, err := supplierSvc.CreateSubcontractorCard(ctx, org.ID, service.SupplierInput{LegalName: "Elektrikçi Hasan", Phone: "0555"})
		if err != nil {
			t.Fatal(err)
		}
		if !card.IsSubcontractor || card.Code == "" || card.Code[:4] != "TSR-" {
			t.Fatalf("kart alanları: %+v", card)
		}
		second, err := supplierSvc.CreateSubcontractorCard(ctx, org.ID, service.SupplierInput{LegalName: "Boyacı Ali"})
		if err != nil || second.Code == card.Code {
			t.Fatalf("ikinci kart farklı kod almalı: %v %v", second, err)
		}
		if _, err := supplierSvc.CreateSubcontractorCard(ctx, org.ID, service.SupplierInput{LegalName: "  "}); !errors.Is(err, service.ErrSubcontractorNameRequired) {
			t.Fatalf("adsız kart reddedilmeli, geldi %v", err)
		}
	})

	t.Run("projede karttan seçilen taşeron karta bağlanır, ad karttan gelir", func(t *testing.T) {
		card, err := supplierSvc.CreateSubcontractorCard(ctx, org.ID, service.SupplierInput{LegalName: "Sıvacı Mehmet", Phone: "0532"})
		if err != nil {
			t.Fatal(err)
		}
		sub, err := projectSvc.CreateSubcontractor(ctx, p1.ID, org.ID, service.SubcontractorInput{
			SupplierID: card.ID, ContractAmount: 10000, Currency: "TRY", WorkDescription: "Sıva",
		})
		if err != nil {
			t.Fatal(err)
		}
		if sub.SupplierID == nil || *sub.SupplierID != card.ID || sub.Name != "Sıvacı Mehmet" || sub.Phone != "0532" {
			t.Fatalf("karttan gelmeli: %+v", sub)
		}
	})

	t.Run("ad elle yazılırsa aynı adlı karta bağlanır, yoksa kart açılır", func(t *testing.T) {
		a, err := projectSvc.CreateSubcontractor(ctx, p1.ID, org.ID, service.SubcontractorInput{
			Name: "Fayansçı  Kemal", ContractAmount: 5000, Currency: "TRY",
		})
		if err != nil {
			t.Fatal(err)
		}
		b, err := projectSvc.CreateSubcontractor(ctx, p2.ID, org.ID, service.SubcontractorInput{
			Name: "fayansçı kemal", ContractAmount: 7000, Currency: "TRY",
		})
		if err != nil {
			t.Fatal(err)
		}
		if a.SupplierID == nil || b.SupplierID == nil || *a.SupplierID != *b.SupplierID {
			t.Fatalf("aynı ad tek karta bağlanmalı: %v %v", a.SupplierID, b.SupplierID)
		}
		card := cardByID(t, *a.SupplierID, false)
		if !card.IsSubcontractor {
			t.Fatal("otomatik açılan kart taşeron olmalı")
		}
	})

	t.Run("defter: projeli ve proje dışı ödemeler tek listede, toplamlarla", func(t *testing.T) {
		card, err := supplierSvc.CreateSubcontractorCard(ctx, org.ID, service.SupplierInput{LegalName: "Çatıcı Veli"})
		if err != nil {
			t.Fatal(err)
		}
		sub, err := projectSvc.CreateSubcontractor(ctx, p2.ID, org.ID, service.SubcontractorInput{
			SupplierID: card.ID, ContractAmount: 20000, Currency: "TRY",
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.CreateSubcontractorPayment(ctx, p2.ID, sub.ID, org.ID, service.SubcontractorPaymentInput{
			Amount: 8000, Currency: "TRY", PaidDate: today,
		}); err != nil {
			t.Fatal(err)
		}
		direct, err := supplierSvc.CreateDirectPayment(ctx, org.ID, card.ID, service.DirectPaymentInput{
			Amount: 1500, PaidDate: today, Description: "Depo çatısı tamiri", IdempotencyKey: "dp-1",
		})
		if err != nil {
			t.Fatal(err)
		}
		again, err := supplierSvc.CreateDirectPayment(ctx, org.ID, card.ID, service.DirectPaymentInput{
			Amount: 1500, PaidDate: today, IdempotencyKey: "dp-1",
		})
		if err != nil || again.ID != direct.ID {
			t.Fatalf("aynı anahtar aynı ödemeyi dönmeli: %v %v", again, err)
		}

		ledger, err := supplierSvc.GetSubcontractorLedger(ctx, org.ID, card.ID, "")
		if err != nil {
			t.Fatal(err)
		}
		if len(ledger.Engagements) != 1 || ledger.Engagements[0].PaidAmount != 8000 || ledger.Engagements[0].ProjectName != "Üsküdar" {
			t.Fatalf("projedeki iş: %+v", ledger.Engagements)
		}
		sources := map[string]float64{}
		for _, p := range ledger.Payments {
			sources[p.Source] += p.Amount
		}
		if sources["simple"] != 8000 || sources["direct"] != 1500 {
			t.Fatalf("ödemeler: %+v", sources)
		}
		c := cardByID(t, card.ID, true)
		if len(c.PaidTotals) != 1 || c.PaidTotals[0].Amount != 9500 {
			t.Fatalf("toplam 9500 olmalı: %+v", c.PaidTotals)
		}
		if noTotals := cardByID(t, card.ID, false); len(noTotals.PaidTotals) != 0 {
			t.Fatal("finans okuyamayana toplam gelmemeli")
		}

		// İptal edilen proje dışı ödeme toplamdan düşer; ikinci iptal olmaz.
		if _, err := supplierSvc.VoidDirectPayment(ctx, org.ID, card.ID, direct.ID, "", "yanlış"); err != nil {
			t.Fatal(err)
		}
		if _, err := supplierSvc.VoidDirectPayment(ctx, org.ID, card.ID, direct.ID, "", ""); !errors.Is(err, service.ErrDirectPaymentNotFound) {
			t.Fatalf("ikinci iptal: beklenen ErrDirectPaymentNotFound, geldi %v", err)
		}
		if c := cardByID(t, card.ID, true); c.PaidTotals[0].Amount != 8000 {
			t.Fatalf("iptal sonrası toplam 8000 olmalı: %+v", c.PaidTotals)
		}
	})

	t.Run("arşivdeki karta ödeme ve proje bağı yok; başka firma göremez", func(t *testing.T) {
		card, err := supplierSvc.CreateSubcontractorCard(ctx, org.ID, service.SupplierInput{LegalName: "Arşiv Usta"})
		if err != nil {
			t.Fatal(err)
		}
		if err := supplierSvc.Archive(ctx, card.ID, org.ID, ""); err != nil {
			t.Fatal(err)
		}
		if _, err := supplierSvc.CreateDirectPayment(ctx, org.ID, card.ID, service.DirectPaymentInput{Amount: 10, PaidDate: today}); !errors.Is(err, service.ErrSubcontractorCardArchived) {
			t.Fatalf("arşivdeki karta ödeme: beklenen ErrSubcontractorCardArchived, geldi %v", err)
		}
		if _, err := projectSvc.CreateSubcontractor(ctx, p1.ID, org.ID, service.SubcontractorInput{
			SupplierID: card.ID, ContractAmount: 100, Currency: "TRY",
		}); !errors.Is(err, service.ErrSubcontractorCardArchived) {
			t.Fatalf("arşivdeki kartla proje kaydı: beklenen ErrSubcontractorCardArchived, geldi %v", err)
		}
		other := mustCreateOrg(t, ctx, orgSvc, pool, "Başka Taşeron Org", "taseron-rehberi-test-2")
		if _, err := supplierSvc.GetSubcontractorLedger(ctx, other.ID, card.ID, ""); !errors.Is(err, service.ErrSubcontractorCardNotFound) {
			t.Fatalf("başka firma: beklenen ErrSubcontractorCardNotFound, geldi %v", err)
		}
		if _, err := projectSvc.CreateSubcontractor(ctx, p1.ID, org.ID, service.SubcontractorInput{
			SupplierID: "00000000-0000-0000-0000-000000000009", ContractAmount: 100, Currency: "TRY",
		}); !errors.Is(err, service.ErrSubcontractorCardNotFound) {
			t.Fatalf("olmayan kart: beklenen ErrSubcontractorCardNotFound, geldi %v", err)
		}
	})
}
