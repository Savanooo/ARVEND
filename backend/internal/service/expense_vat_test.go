package service_test

// Masraflara KDV bilgisi (migration 0065, ürün sahibi kararı 2026-10-07) --
// gerçek bir PostgreSQL bağlantısı gerektirir. Kural: masrafın tutarı ödenen
// (KDV dahil) tutardır; oran verilirse içindeki KDV finans özetinin "KDV
// hariç" maliyetinden düşülür. Oran belirtilmemiş masraf önceki gibi tutarın
// tamamıyla sayılır; onay bekleyen/reddedilen/iptal edilmiş masraf hiç
// sayılmaz.

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

func TestExpenseVAT(t *testing.T) {
	dbURL := testDBURL(t)
	box := testSecretBox(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	settingsSvc := service.NewSettingsService(q, box)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000")

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Masraf KDV Firma", "masraf-kdv-firma")
	today := time.Now()

	// Sözleşme 1.200.000 KDV dahil = 1.000.000 + %20 KDV (200.000).
	newVATProject := func(t *testing.T) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerName: "KDV Müşteri", VatRate: ptrFloat(20),
			Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 1000000}},
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
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, org.ID, service.CreateProjectInput{Name: "KDV Masraf Projesi"})
		if err != nil {
			t.Fatal(err)
		}
		return p
	}
	expense := func(amount float64, rate *float64) service.ExpenseInput {
		return service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Malzeme", Amount: amount,
			Currency: "TRY", ExpenseDate: today, VATRate: rate,
		}
	}
	summary := func(t *testing.T, p *domain.Project) *domain.ProjectFinancialSummary {
		t.Helper()
		fs, err := projectSvc.FinancialSummary(ctx, p.ID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		return fs
	}

	t.Run("1_expense_carries_rate_vat_and_net", func(t *testing.T) {
		p := newVATProject(t)
		e, err := projectSvc.CreateExpense(ctx, p.ID, org.ID, expense(120000, ptrFloat(20)))
		if err != nil {
			t.Fatal(err)
		}
		if e.VATRate == nil || *e.VATRate != 20 || e.VATAmount == nil || *e.VATAmount != 20000 {
			t.Fatalf("oran/KDV: %v %v", e.VATRate, e.VATAmount)
		}
		if net := e.NetAmount(); net == nil || *net != 100000 || e.Amount != 120000 {
			t.Fatalf("KDV hariç / ödenen: %v %v", net, e.Amount)
		}
		// Kuruşa yuvarlama: 100,01 TL içindeki %1 KDV = 0,99.
		small, err := projectSvc.CreateExpense(ctx, p.ID, org.ID, expense(100.01, ptrFloat(1)))
		if err != nil {
			t.Fatal(err)
		}
		if *small.VATAmount != 0.99 || *small.NetAmount() != 99.02 {
			t.Fatalf("yuvarlama: %v %v", *small.VATAmount, *small.NetAmount())
		}
		// Belirtilmemiş: üçü de boş -- bilinmeyen KDV sıfır sayılmaz.
		plain, err := projectSvc.CreateExpense(ctx, p.ID, org.ID, expense(500, nil))
		if err != nil {
			t.Fatal(err)
		}
		if plain.VATRate != nil || plain.VATAmount != nil || plain.NetAmount() != nil {
			t.Fatalf("belirtilmemiş KDV: %+v", plain)
		}
		// KDV yok (%0): tutarın tamamı KDV hariçtir.
		zero, err := projectSvc.CreateExpense(ctx, p.ID, org.ID, expense(750, ptrFloat(0)))
		if err != nil {
			t.Fatal(err)
		}
		if *zero.VATAmount != 0 || *zero.NetAmount() != 750 {
			t.Fatalf("KDV yok: %v %v", *zero.VATAmount, *zero.NetAmount())
		}
		list, err := projectSvc.ListExpenses(ctx, p.ID, org.ID)
		if err != nil || len(list) != 4 {
			t.Fatalf("liste: %d %v", len(list), err)
		}
	})

	t.Run("2_invalid_rate_rejected", func(t *testing.T) {
		p := newVATProject(t)
		for _, rate := range []float64{-1, 100.01, 120} {
			if _, err := projectSvc.CreateExpense(ctx, p.ID, org.ID, expense(100, ptrFloat(rate))); !errors.Is(err, service.ErrInvalidExpenseVATRate) {
				t.Errorf("oran %v reddedilmeli: %v", rate, err)
			}
		}
		e, err := projectSvc.CreateExpense(ctx, p.ID, org.ID, expense(100, ptrFloat(100)))
		if err != nil {
			t.Fatalf("%%100 sınırı geçerli: %v", err)
		}
		if _, err := projectSvc.UpdateExpense(ctx, p.ID, e.ID, org.ID, expense(100, ptrFloat(-5))); !errors.Is(err, service.ErrInvalidExpenseVATRate) {
			t.Errorf("düzenlemede de reddedilmeli: %v", err)
		}
	})

	t.Run("4_edit_rewrites_vat_and_links_and_goes_back_to_pending", func(t *testing.T) {
		p := newVATProject(t)
		co, err := projectSvc.CreateChangeOrder(ctx, p.ID, org.ID, service.ChangeOrderInput{
			ChangeType: domain.ChangeOrderAddition, Title: "Ek iş",
			Items: []service.ChangeOrderItemInput{{Description: "Kalem", Quantity: 1, Unit: "adet", UnitPrice: 5000}},
		})
		if err != nil {
			t.Fatal(err)
		}
		e, err := createApprovedExpense(ctx, projectSvc, p.ID, org.ID, expense(120000, ptrFloat(20)))
		if err != nil {
			t.Fatal(err)
		}
		if fs := summary(t, p); fs.RealizedCost != 120000 {
			t.Fatalf("onaylı masraf: %v", fs.RealizedCost)
		}

		in := expense(110000, ptrFloat(10))
		in.ChangeOrderID = co.ID
		in.SupplierName, in.InvoiceNo, in.Notes = "Yapı Market", "YM-1", "Düzeltildi"
		updated, err := projectSvc.UpdateExpense(ctx, p.ID, e.ID, org.ID, in)
		if err != nil {
			t.Fatal(err)
		}
		if updated.ApprovalStatus != domain.ExpenseApprovalPending {
			t.Errorf("düzenlenen masraf yeniden onay beklemeli: %v", updated.ApprovalStatus)
		}
		if *updated.VATRate != 10 || *updated.VATAmount != 10000 || *updated.NetAmount() != 100000 {
			t.Errorf("KDV yeniden hesaplanmalı: %v %v %v", *updated.VATRate, *updated.VATAmount, *updated.NetAmount())
		}
		if updated.ChangeOrderID == nil || *updated.ChangeOrderID != co.ID || updated.SupplierName != "Yapı Market" ||
			updated.InvoiceNo != "YM-1" || updated.Notes != "Düzeltildi" {
			t.Errorf("alanlar yazılmalı: %+v", updated)
		}
		// Yeniden onay bekliyor: özetten düştü.
		if fs := summary(t, p); fs.RealizedCost != 0 {
			t.Errorf("bekleyen düzenleme sayıldı: %v", fs.RealizedCost)
		}

		// Reddedilen masraf düzeltilip yeniden onaya gönderilebilir; oran
		// boş gelirse "belirtilmedi" olur, ek iş bağı kalkar.
		if _, err := projectSvc.RejectExpense(ctx, p.ID, e.ID, org.ID, "", "Fatura yok"); err != nil {
			t.Fatal(err)
		}
		cleared, err := projectSvc.UpdateExpense(ctx, p.ID, e.ID, org.ID, expense(110000, nil))
		if err != nil {
			t.Fatal(err)
		}
		if cleared.ApprovalStatus != domain.ExpenseApprovalPending || cleared.DecisionNote != "" {
			t.Errorf("ret düzenlemeyle temizlenmeli: %v %q", cleared.ApprovalStatus, cleared.DecisionNote)
		}
		if cleared.VATRate != nil || cleared.VATAmount != nil || cleared.ChangeOrderID != nil {
			t.Errorf("oran ve bağ temizlenmeli: %v %v %v", cleared.VATRate, cleared.VATAmount, cleared.ChangeOrderID)
		}

		// Başka projenin ek işine bağlanamaz.
		other := newVATProject(t)
		otherCO, err := projectSvc.CreateChangeOrder(ctx, other.ID, org.ID, service.ChangeOrderInput{
			ChangeType: domain.ChangeOrderAddition, Title: "Başka ek iş",
			Items: []service.ChangeOrderItemInput{{Description: "Kalem", Quantity: 1, Unit: "adet", UnitPrice: 1}},
		})
		if err != nil {
			t.Fatal(err)
		}
		bad := expense(110000, nil)
		bad.ChangeOrderID = otherCO.ID
		if _, err := projectSvc.UpdateExpense(ctx, p.ID, e.ID, org.ID, bad); !errors.Is(err, service.ErrInvalidChangeOrderRef) {
			t.Errorf("başka projenin ek işi reddedilmeli: %v", err)
		}
	})
}
