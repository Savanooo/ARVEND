package service_test

// Faz 6 (Proje Finans Modülleri) için otomatik testler -- gerçek bir
// PostgreSQL bağlantısı gerektirir.

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestProjectFinance(t *testing.T) {
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

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "Finans Test Firma A", "finans-test-firma-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "Finans Test Firma B", "finans-test-firma-b")

	today := time.Now()

	// newProject, sözleşme bedeli verilen kabul edilmiş bir teklifi
	// projeye dönüştürür (gerçek akış: gönder -> link -> kabul -> dönüştür).
	newProject := func(t *testing.T, orgID string, unitPrice float64) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID,
			CustomerName:   "Finans Test Müşteri",
			VatRate:        ptrFloat(0), // KDV'siz: contract_amount = unitPrice
			Items:          []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: unitPrice}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgID, "", nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatalf("kabul edilemedi: %v", err)
		}
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: "Finans Projesi"})
		if err != nil {
			t.Fatalf("proje oluşturulamadı: %v", err)
		}
		return p
	}

	t.Run("1_payment_plan_created_per_project", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		pct30, pct40 := 30.0, 40.0
		for i, spec := range []struct {
			name string
			pct  *float64
		}{{"Peşinat", &pct30}, {"Ara Ödeme", &pct40}, {"Teslim", nil}} {
			in := service.PaymentPlanItemInput{Name: spec.name, Percentage: spec.pct, SortOrder: i}
			if spec.pct == nil {
				in.PlannedAmount = 30000
			}
			if _, err := projectSvc.CreatePaymentPlanItem(ctx, p.ID, orgA.ID, in); err != nil {
				t.Fatalf("%s kalemi oluşturulamadı: %v", spec.name, err)
			}
		}
		items, err := projectSvc.ListPaymentPlan(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("plan alınamadı: %v", err)
		}
		if len(items) != 3 {
			t.Fatalf("beklenen 3 kalem, geldi: %d", len(items))
		}
		// Yüzde verilen kalemlerin tutarı contract_amount'tan hesaplanmalı.
		if items[0].PlannedAmount != 30000 || items[1].PlannedAmount != 40000 {
			t.Errorf("yüzdeden tutar hesaplanmadı: %v / %v", items[0].PlannedAmount, items[1].PlannedAmount)
		}
		if items[0].Status != domain.PlanItemPending {
			t.Errorf("yeni kalem pending olmalı: %s", items[0].Status)
		}
	})

	t.Run("2_collection_written_to_correct_project", func(t *testing.T) {
		p1 := newProject(t, orgA.ID, 50000)
		p2 := newProject(t, orgA.ID, 50000)
		if _, err := projectSvc.CreateCollection(ctx, p1.ID, orgA.ID, service.CollectionInput{
			Amount: 1000, Currency: "TRY", ReceivedDate: today,
		}); err != nil {
			t.Fatalf("tahsilat eklenemedi: %v", err)
		}
		c1, _ := projectSvc.ListCollections(ctx, p1.ID, orgA.ID)
		c2, _ := projectSvc.ListCollections(ctx, p2.ID, orgA.ID)
		if len(c1) != 1 || len(c2) != 0 {
			t.Errorf("tahsilat yanlış projeye yazıldı: p1=%d p2=%d", len(c1), len(c2))
		}
	})

	t.Run("3_collection_moves_plan_item_to_partial_then_paid", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		pct := 30.0
		item, err := projectSvc.CreatePaymentPlanItem(ctx, p.ID, orgA.ID, service.PaymentPlanItemInput{
			Name: "Peşinat", Percentage: &pct,
		})
		if err != nil {
			t.Fatalf("kalem oluşturulamadı: %v", err)
		}
		// 30.000'lik kaleme önce 10.000 -> partial
		if _, err := projectSvc.CreateCollection(ctx, p.ID, orgA.ID, service.CollectionInput{
			PaymentPlanItemID: &item.ID, Amount: 10000, Currency: "TRY", ReceivedDate: today,
		}); err != nil {
			t.Fatalf("kısmi tahsilat eklenemedi: %v", err)
		}
		items, _ := projectSvc.ListPaymentPlan(ctx, p.ID, orgA.ID)
		if items[0].Status != domain.PlanItemPartial {
			t.Errorf("kısmi tahsilat sonrası durum partial olmalı: %s", items[0].Status)
		}
		if items[0].CollectedAmount != 10000 {
			t.Errorf("kalem tahsilatı yanlış: %v", items[0].CollectedAmount)
		}
		// Kalan 20.000 -> paid
		if _, err := projectSvc.CreateCollection(ctx, p.ID, orgA.ID, service.CollectionInput{
			PaymentPlanItemID: &item.ID, Amount: 20000, Currency: "TRY", ReceivedDate: today,
		}); err != nil {
			t.Fatalf("ikinci tahsilat eklenemedi: %v", err)
		}
		items, _ = projectSvc.ListPaymentPlan(ctx, p.ID, orgA.ID)
		if items[0].Status != domain.PlanItemPaid {
			t.Errorf("tam tahsilat sonrası durum paid olmalı: %s", items[0].Status)
		}
	})

	t.Run("4_voided_collection_drops_from_total", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		c, err := projectSvc.CreateCollection(ctx, p.ID, orgA.ID, service.CollectionInput{
			Amount: 25000, Currency: "TRY", ReceivedDate: today,
		})
		if err != nil {
			t.Fatalf("tahsilat eklenemedi: %v", err)
		}
		before, _ := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if before.CollectedAmount != 25000 {
			t.Fatalf("tahsilat toplamı yanlış: %v", before.CollectedAmount)
		}
		if _, err := projectSvc.VoidCollection(ctx, p.ID, c.ID, orgA.ID, "", "yanlış giriş"); err != nil {
			t.Fatalf("iptal edilemedi: %v", err)
		}
		after, _ := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if after.CollectedAmount != 0 {
			t.Errorf("iptal edilen tahsilat toplamdan düşmedi: %v", after.CollectedAmount)
		}
		// Kayıt SİLİNMEMELİ, iz kalmalı.
		list, _ := projectSvc.ListCollections(ctx, p.ID, orgA.ID)
		if len(list) != 1 || list[0].VoidedAt == nil {
			t.Errorf("iptal edilen tahsilat kaydı kayboldu ya da işaretlenmedi: %+v", list)
		}
	})

	t.Run("5_and_6_balance_and_over_collection", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		if _, err := projectSvc.CreateCollection(ctx, p.ID, orgA.ID, service.CollectionInput{
			Amount: 40000, Currency: "TRY", ReceivedDate: today,
		}); err != nil {
			t.Fatalf("tahsilat eklenemedi: %v", err)
		}
		s, _ := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if s.RemainingReceivable != 60000 {
			t.Errorf("bakiye yanlış: %v want 60000", s.RemainingReceivable)
		}
		if s.OverCollected() != 0 {
			t.Errorf("fazla tahsilat olmamalı: %v", s.OverCollected())
		}
		// Fazla tahsilat: toplam 110.000 -> bakiye -10.000
		if _, err := projectSvc.CreateCollection(ctx, p.ID, orgA.ID, service.CollectionInput{
			Amount: 70000, Currency: "TRY", ReceivedDate: today,
		}); err != nil {
			t.Fatalf("tahsilat eklenemedi: %v", err)
		}
		s, _ = projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if s.RemainingReceivable != -10000 {
			t.Errorf("negatif bakiye gizlenmiş/yanlış: %v want -10000", s.RemainingReceivable)
		}
		if s.OverCollected() != 10000 {
			t.Errorf("fazla tahsilat yanlış: %v want 10000", s.OverCollected())
		}
	})

	t.Run("7_and_8_expense_total_and_void", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		e1, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Çimento", Amount: 5000,
			Currency: "TRY", ExpenseDate: today,
		})
		if err != nil {
			t.Fatalf("masraf eklenemedi: %v", err)
		}
		if _, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseTransport, Description: "Nakliye", Amount: 1500,
			Currency: "TRY", ExpenseDate: today,
		}); err != nil {
			t.Fatalf("masraf eklenemedi: %v", err)
		}
		s, _ := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if s.TotalExpenses != 6500 {
			t.Errorf("masraf toplamı yanlış: %v want 6500", s.TotalExpenses)
		}
		if _, err := projectSvc.VoidExpense(ctx, p.ID, e1.ID, orgA.ID, "", "iptal"); err != nil {
			t.Fatalf("masraf iptal edilemedi: %v", err)
		}
		s, _ = projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if s.TotalExpenses != 1500 {
			t.Errorf("iptal edilen masraf toplamdan düşmedi: %v want 1500", s.TotalExpenses)
		}
	})

	t.Run("10c_paid_sales_invoice_records_a_linked_collection", func(t *testing.T) {
		// Sahada (2026-10): "fatura kestim, ödendi yaptım ama özette veri yok".
		p := newProject(t, orgA.ID, 100000)
		inv, err := projectSvc.CreateInvoice(ctx, p.ID, orgA.ID, service.InvoiceInput{
			InvoiceNo: "FTR-1", InvoiceType: domain.InvoiceTypeSales, InvoiceDate: today,
			Amount: 10000, Currency: "TRY", Status: domain.InvoiceIssued, CustomerName: "Serkan Bey",
		})
		if err != nil {
			t.Fatal(err)
		}
		collected := func() float64 {
			s, err := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
			if err != nil {
				t.Fatal(err)
			}
			return s.CollectedAmount
		}
		if _, err := projectSvc.UpdateInvoiceStatus(ctx, p.ID, inv.ID, orgA.ID, domain.InvoicePaid, "", true); err != nil {
			t.Fatal(err)
		}
		if got := collected(); got != 10000 {
			t.Fatalf("ödenen fatura tahsilat olarak özete girmeli: %v", got)
		}
		cols, _ := projectSvc.ListCollections(ctx, p.ID, orgA.ID)
		if len(cols) != 1 || cols[0].InvoiceID == nil || *cols[0].InvoiceID != inv.ID || cols[0].ReferenceNo != "FTR-1" {
			t.Fatalf("tahsilat faturaya bağlı olmalı: %+v", cols)
		}
		// Tekrar "ödendi": ikinci tahsilat açılmaz.
		if _, err := projectSvc.UpdateInvoiceStatus(ctx, p.ID, inv.ID, orgA.ID, domain.InvoicePaid, "", true); err != nil {
			t.Fatal(err)
		}
		if got := collected(); got != 10000 {
			t.Errorf("aynı fatura iki kez sayılmamalı: %v", got)
		}
		// "Ödendi"den çıkınca bağlı tahsilat iptal edilir.
		if _, err := projectSvc.UpdateInvoiceStatus(ctx, p.ID, inv.ID, orgA.ID, domain.InvoiceSent, "", true); err != nil {
			t.Fatal(err)
		}
		if got := collected(); got != 0 {
			t.Errorf("bağlı tahsilat iptal edilmeli: %v", got)
		}
		// Kullanıcı tahsilatı ayrıca girdiyse: yalnızca durum değişir.
		if _, err := projectSvc.UpdateInvoiceStatus(ctx, p.ID, inv.ID, orgA.ID, domain.InvoicePaid, "", false); err != nil {
			t.Fatal(err)
		}
		if got := collected(); got != 0 {
			t.Errorf("record=false iken tahsilat açılmamalı: %v", got)
		}
		// Elle girilmiş (faturaya bağlı olmayan) tahsilata durum değişikliği dokunmaz.
		if _, err := projectSvc.CreateCollection(ctx, p.ID, orgA.ID, service.CollectionInput{
			Amount: 2500, Currency: "TRY", ReceivedDate: today,
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.UpdateInvoiceStatus(ctx, p.ID, inv.ID, orgA.ID, domain.InvoiceCancelled, "", true); err != nil {
			t.Fatal(err)
		}
		if got := collected(); got != 2500 {
			t.Errorf("elle girilen tahsilat korunmalı: %v", got)
		}

		// Alış faturası ödenince tahsilat AÇILMAZ (para çıkışıdır).
		buy, err := projectSvc.CreateInvoice(ctx, p.ID, orgA.ID, service.InvoiceInput{
			InvoiceNo: "ALIS-1", InvoiceType: domain.InvoiceTypePurchase, InvoiceDate: today,
			Amount: 4000, Currency: "TRY", Status: domain.InvoiceIssued,
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.UpdateInvoiceStatus(ctx, p.ID, buy.ID, orgA.ID, domain.InvoicePaid, "", true); err != nil {
			t.Fatal(err)
		}
		if got := collected(); got != 2500 {
			t.Errorf("alış faturası tahsilat açmamalı: %v", got)
		}
	})

	t.Run("10b_subcontractor_payments_cannot_exceed_contract", func(t *testing.T) {
		// Sahada (2026-10): 1.000 TL'lik sözleşmeye 21.000 TL ödeme girilebilmişti.
		p := newProject(t, orgA.ID, 100000)
		sub, err := projectSvc.CreateSubcontractor(ctx, p.ID, orgA.ID, service.SubcontractorInput{
			Name: "Sınır Usta", ContractAmount: 1000, Currency: "TRY",
		})
		if err != nil {
			t.Fatal(err)
		}
		pay := func(amount float64, key string) error {
			_, err := projectSvc.CreateSubcontractorPayment(ctx, p.ID, sub.ID, orgA.ID, service.SubcontractorPaymentInput{
				Amount: amount, Currency: "TRY", PaidDate: today, IdempotencyKey: key,
			})
			return err
		}
		err = pay(21000, "")
		var over *service.PaymentExceedsContractError
		if !errors.As(err, &over) || !errors.Is(err, service.ErrPaymentExceedsContract) {
			t.Fatalf("sözleşmeyi aşan ödeme reddedilmeli, geldi %v", err)
		}
		if !strings.Contains(err.Error(), "En fazla 1.000,00 TL ödenebilir") {
			t.Errorf("mesaj ne kadar ödenebileceğini söylemeli: %q", err.Error())
		}
		if err := pay(600, "k1"); err != nil {
			t.Fatalf("sınır içindeki ödeme: %v", err)
		}
		if err := pay(400.01, ""); !errors.Is(err, service.ErrPaymentExceedsContract) {
			t.Errorf("1 kuruş bile aşamaz: %v", err)
		}
		if err := pay(400, "k2"); err != nil {
			t.Fatalf("tam sınıra kadar ödenebilir: %v", err)
		}
		// Ağ tekrarı (aynı anahtar) sınıra dayanmışken de hata vermez, aynı kaydı döner.
		if err := pay(400, "k2"); err != nil {
			t.Errorf("aynı anahtarlı tekrar reddedilmemeli: %v", err)
		}
		// İptal edilen ödeme toplamdan düşer, yeri açılır.
		pays, _ := projectSvc.ListSubcontractorPayments(ctx, p.ID, orgA.ID)
		for _, pp := range pays {
			if pp.SubcontractorID == sub.ID && pp.Amount == 600 {
				if _, err := projectSvc.VoidSubcontractorPayment(ctx, p.ID, pp.ID, orgA.ID, "", "yanlış girildi"); err != nil {
					t.Fatal(err)
				}
			}
		}
		if err := pay(600, ""); err != nil {
			t.Errorf("iptalden sonra yer açılmalı: %v", err)
		}
	})

	t.Run("10d_subcontractor_profit_percent", func(t *testing.T) {
		// Ürün sahibi kararı (2026-10-06): taşeron formunda sözleşme bedeli +
		// bizim kâr payımız (%).
		p := newProject(t, orgA.ID, 100000)
		pct := func(v float64) *float64 { return &v }
		sub, err := projectSvc.CreateSubcontractor(ctx, p.ID, orgA.ID, service.SubcontractorInput{
			Name: "Kârlı Usta", ContractAmount: 100000, Currency: "TRY", ProfitPercent: pct(20),
		})
		if err != nil {
			t.Fatal(err)
		}
		find := func() domain.Subcontractor {
			t.Helper()
			list, err := projectSvc.ListSubcontractors(ctx, p.ID, orgA.ID)
			if err != nil {
				t.Fatal(err)
			}
			for _, x := range list {
				if x.ID == sub.ID {
					return x
				}
			}
			t.Fatal("taşeron listede yok")
			return domain.Subcontractor{}
		}
		got := find()
		profit, customer, ok := got.SubcontractorProfit()
		if !ok || profit != 20000 || customer != 120000 {
			t.Fatalf("kâr/müşteri tutarı: %v %v %v", profit, customer, ok)
		}

		// Alanı göndermeyen düzenleme (eski istemci) kâr payını silmez.
		in := service.SubcontractorInput{Name: "Kârlı Usta", ContractAmount: 80000, Status: got.Status}
		if _, err := projectSvc.UpdateSubcontractor(ctx, p.ID, sub.ID, orgA.ID, in); err != nil {
			t.Fatal(err)
		}
		if got = find(); got.ProfitPercent == nil || *got.ProfitPercent != 20 {
			t.Fatalf("kâr payı korunmalı: %v", got.ProfitPercent)
		}
		if profit, customer, _ := got.SubcontractorProfit(); profit != 16000 || customer != 96000 {
			t.Errorf("yeni bedele göre: %v %v", profit, customer)
		}

		in.ProfitPercent = pct(0)
		if _, err := projectSvc.UpdateSubcontractor(ctx, p.ID, sub.ID, orgA.ID, in); err != nil {
			t.Fatal(err)
		}
		if got = find(); got.ProfitPercent == nil || *got.ProfitPercent != 0 {
			t.Errorf("0 yazılabilmeli: %v", got.ProfitPercent)
		}

		in.ProfitPercent = pct(1500)
		if _, err := projectSvc.UpdateSubcontractor(ctx, p.ID, sub.ID, orgA.ID, in); !errors.Is(err, service.ErrInvalidProfitPercent) {
			t.Errorf("aralık dışı reddedilmeli: %v", err)
		}
		if _, err := projectSvc.CreateSubcontractor(ctx, p.ID, orgA.ID, service.SubcontractorInput{
			Name: "Eksi", ContractAmount: 1000, Currency: "TRY", ProfitPercent: pct(-5),
		}); !errors.Is(err, service.ErrInvalidProfitPercent) {
			t.Errorf("negatif reddedilmeli: %v", err)
		}
	})

	t.Run("10e_profit_with_and_without_vat", func(t *testing.T) {
		// Ürün sahibi kararı (2026-10-06): kâr hem KDV dahil hem KDV hariç.
		// KDV %20: sözleşme 1.200.000 (KDV dahil) = 1.000.000 + 200.000 KDV.
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgA.ID, CustomerName: "KDV Müşteri", VatRate: ptrFloat(20),
			Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 1000000}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatal(err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgA.ID, "", nil)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatal(err)
		}
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgA.ID, service.CreateProjectInput{Name: "KDV Projesi"})
		if err != nil {
			t.Fatal(err)
		}
		// 900.000 maliyet (taşeron ödemesi -- masraf onay akışından bağımsız).
		sub, err := projectSvc.CreateSubcontractor(ctx, p.ID, orgA.ID, service.SubcontractorInput{
			Name: "Ana Taşeron", ContractAmount: 900000, Currency: "TRY",
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.CreateSubcontractorPayment(ctx, p.ID, sub.ID, orgA.ID, service.SubcontractorPaymentInput{
			Amount: 900000, Currency: "TRY", PaidDate: today,
		}); err != nil {
			t.Fatal(err)
		}

		fs, err := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatal(err)
		}
		if fs.CurrentContractValue != 1200000 || fs.ContractVATAmount != 200000 || !fs.ContractVATKnown {
			t.Fatalf("bedel/KDV: %v %v %v", fs.CurrentContractValue, fs.ContractVATAmount, fs.ContractVATKnown)
		}
		if fs.CurrentContractValueNet != 1000000 {
			t.Errorf("KDV hariç bedel: %v", fs.CurrentContractValueNet)
		}
		if fs.RealizedGrossProfit != 300000 || fs.RealizedGrossProfitNet != 100000 {
			t.Errorf("kâr KDV dahil/hariç: %v / %v", fs.RealizedGrossProfit, fs.RealizedGrossProfitNet)
		}
		if fs.RealizedMarginPercent != 25 || fs.RealizedMarginPercentNet != 10 {
			t.Errorf("marj KDV dahil/hariç: %v / %v", fs.RealizedMarginPercent, fs.RealizedMarginPercentNet)
		}
		// Bütçe yok: tahmin taahhüt bazlı ve web/mobil için tek kaynak.
		if fs.ForecastBasis != domain.ForecastBasisCommitments || fs.ForecastCost != fs.CommittedCost {
			t.Errorf("tahmin kaynağı: %v %v/%v", fs.ForecastBasis, fs.ForecastCost, fs.CommittedCost)
		}
		if fs.ForecastProfit != 300000 || fs.ForecastProfitNet != 100000 || fs.ForecastMarginPercentNet != 10 {
			t.Errorf("tahmini kâr: %v / %v / %v", fs.ForecastProfit, fs.ForecastProfitNet, fs.ForecastMarginPercentNet)
		}
	})

	t.Run("9_and_10_subcontractor_commitment_and_payments", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		sub, err := projectSvc.CreateSubcontractor(ctx, p.ID, orgA.ID, service.SubcontractorInput{
			Name: "Demirci Usta", ContractAmount: 20000, Currency: "TRY",
		})
		if err != nil {
			t.Fatalf("taşeron eklenemedi: %v", err)
		}
		if _, err := projectSvc.CreateSubcontractor(ctx, p.ID, orgA.ID, service.SubcontractorInput{
			Name: "Sıvacı", ContractAmount: 10000, Currency: "TRY",
		}); err != nil {
			t.Fatalf("taşeron eklenemedi: %v", err)
		}
		s, _ := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if s.TotalSubcontractorCommitment != 30000 {
			t.Errorf("taşeron taahhüt toplamı yanlış: %v want 30000", s.TotalSubcontractorCommitment)
		}

		if _, err := projectSvc.CreateSubcontractorPayment(ctx, p.ID, sub.ID, orgA.ID, service.SubcontractorPaymentInput{
			Amount: 8000, Currency: "TRY", PaidDate: today,
		}); err != nil {
			t.Fatalf("taşeron ödemesi eklenemedi: %v", err)
		}
		subs, _ := projectSvc.ListSubcontractors(ctx, p.ID, orgA.ID)
		var target *domain.Subcontractor
		for i := range subs {
			if subs[i].ID == sub.ID {
				target = &subs[i]
			}
		}
		if target == nil || target.PaidAmount != 8000 || target.RemainingAmount != 12000 {
			t.Errorf("taşeron ödenen/kalan yanlış: %+v", target)
		}
		s, _ = projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if s.SubcontractorPaid != 8000 || s.SubcontractorRemaining != 22000 {
			t.Errorf("özet taşeron değerleri yanlış: paid=%v remaining=%v", s.SubcontractorPaid, s.SubcontractorRemaining)
		}
	})

	t.Run("11_12_13_cross_tenant_blocked", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		sub, err := projectSvc.CreateSubcontractor(ctx, p.ID, orgA.ID, service.SubcontractorInput{
			Name: "A Taşeronu", ContractAmount: 5000, Currency: "TRY",
		})
		if err != nil {
			t.Fatalf("taşeron eklenemedi: %v", err)
		}

		// 11: Firma B, Firma A'nın projesine tahsilat giremez.
		if _, err := projectSvc.CreateCollection(ctx, p.ID, orgB.ID, service.CollectionInput{
			Amount: 100, Currency: "TRY", ReceivedDate: today,
		}); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("cross-tenant tahsilat engellenmedi: err=%v", err)
		}
		// 12: masraf
		if _, err := projectSvc.CreateExpense(ctx, p.ID, orgB.ID, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "x", Amount: 100, Currency: "TRY", ExpenseDate: today,
		}); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("cross-tenant masraf engellenmedi: err=%v", err)
		}
		// 13: taşeron ödemesi
		if _, err := projectSvc.CreateSubcontractorPayment(ctx, p.ID, sub.ID, orgB.ID, service.SubcontractorPaymentInput{
			Amount: 100, Currency: "TRY", PaidDate: today,
		}); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("cross-tenant taşeron ödemesi engellenmedi: err=%v", err)
		}
		// Okuma uçları da sızdırmamalı.
		if rows, _ := projectSvc.ListCollections(ctx, p.ID, orgB.ID); len(rows) != 0 {
			t.Errorf("Firma B, Firma A'nın tahsilatlarını gördü")
		}
		if rows, _ := projectSvc.ListExpenses(ctx, p.ID, orgB.ID); len(rows) != 0 {
			t.Errorf("Firma B, Firma A'nın masraflarını gördü")
		}
		if rows, _ := projectSvc.ListSubcontractors(ctx, p.ID, orgB.ID); len(rows) != 0 {
			t.Errorf("Firma B, Firma A'nın taşeronlarını gördü")
		}
		if _, err := projectSvc.FinancialSummary(ctx, p.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın finans özetini görebildi: err=%v", err)
		}
	})

	t.Run("14_wrong_currency_rejected", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000) // TRY
		if _, err := projectSvc.CreateCollection(ctx, p.ID, orgA.ID, service.CollectionInput{
			Amount: 100, Currency: "EUR", ReceivedDate: today,
		}); !errors.Is(err, service.ErrCurrencyMismatch) {
			t.Errorf("farklı para biriminde tahsilat kabul edildi: err=%v", err)
		}
		if _, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseOther, Description: "x", Amount: 100, Currency: "USD", ExpenseDate: today,
		}); !errors.Is(err, service.ErrCurrencyMismatch) {
			t.Errorf("farklı para biriminde masraf kabul edildi: err=%v", err)
		}
	})

	t.Run("15_negative_amount_rejected", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		if _, err := projectSvc.CreateCollection(ctx, p.ID, orgA.ID, service.CollectionInput{
			Amount: -500, Currency: "TRY", ReceivedDate: today,
		}); !errors.Is(err, service.ErrInvalidAmount) {
			t.Errorf("negatif tahsilat kabul edildi: err=%v", err)
		}
		if _, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseOther, Description: "x", Amount: 0, Currency: "TRY", ExpenseDate: today,
		}); !errors.Is(err, service.ErrInvalidAmount) {
			t.Errorf("sıfır tutarlı masraf kabul edildi: err=%v", err)
		}
	})

	// Senaryo 16: özetin TÜM alanları elle hesaplanan değerlerle birebir
	// tutmalı -- özellikle iki maliyet/kâr kavramının ayrımı.
	t.Run("16_financial_summary_is_correct", func(t *testing.T) {
		p := newProject(t, orgA.ID, 1000000)
		mustCollect(t, projectSvc, ctx, p.ID, orgA.ID, 400000, today)
		mustExpense(t, projectSvc, ctx, p.ID, orgA.ID, 300000, today)
		sub, err := projectSvc.CreateSubcontractor(ctx, p.ID, orgA.ID, service.SubcontractorInput{
			Name: "Taşeron", ContractAmount: 250000, Currency: "TRY",
		})
		if err != nil {
			t.Fatalf("taşeron eklenemedi: %v", err)
		}
		if _, err := projectSvc.CreateSubcontractorPayment(ctx, p.ID, sub.ID, orgA.ID, service.SubcontractorPaymentInput{
			Amount: 50000, Currency: "TRY", PaidDate: today,
		}); err != nil {
			t.Fatalf("ödeme eklenemedi: %v", err)
		}

		s, err := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		checks := []struct {
			name string
			got  float64
			want float64
		}{
			{"contract_amount", s.ContractAmount, 1000000},
			{"collected", s.CollectedAmount, 400000},
			{"remaining_receivable", s.RemainingReceivable, 600000},
			{"total_expenses", s.TotalExpenses, 300000},
			{"subcontractor_commitment", s.TotalSubcontractorCommitment, 250000},
			{"subcontractor_paid", s.SubcontractorPaid, 50000},
			{"subcontractor_remaining", s.SubcontractorRemaining, 200000},
			// Gerçekleşen: masraf + taşerona ÖDENEN
			{"realized_cost", s.RealizedCost, 350000},
			// Taahhüt: gerçekleşen + taşeronun kalan yükümlülüğü
			{"committed_cost", s.CommittedCost, 550000},
			{"realized_gross_profit", s.RealizedGrossProfit, 650000},
			{"estimated_gross_profit", s.EstimatedGrossProfit, 450000},
			{"realized_margin", s.RealizedMarginPercent, 65},
			{"estimated_margin", s.EstimatedMarginPercent, 45},
		}
		for _, c := range checks {
			if c.got != c.want {
				t.Errorf("%s yanlış: %v want %v", c.name, c.got, c.want)
			}
		}
	})

	t.Run("17_list_aggregates_match_summary", func(t *testing.T) {
		p := newProject(t, orgA.ID, 200000)
		mustCollect(t, projectSvc, ctx, p.ID, orgA.ID, 75000, today)
		mustExpense(t, projectSvc, ctx, p.ID, orgA.ID, 20000, today)
		sub, _ := projectSvc.CreateSubcontractor(ctx, p.ID, orgA.ID, service.SubcontractorInput{
			Name: "T", ContractAmount: 30000, Currency: "TRY",
		})
		if _, err := projectSvc.CreateSubcontractorPayment(ctx, p.ID, sub.ID, orgA.ID, service.SubcontractorPaymentInput{
			Amount: 12000, Currency: "TRY", PaidDate: today,
		}); err != nil {
			t.Fatalf("ödeme eklenemedi: %v", err)
		}

		summary, _ := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		list, err := projectSvc.List(ctx, orgA.ID, service.ProjectListFilter{Limit: 200})
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		var row *domain.Project
		for i := range list.Projects {
			if list.Projects[i].ID == p.ID {
				row = &list.Projects[i]
			}
		}
		if row == nil {
			t.Fatalf("proje listede yok")
		}
		if row.CollectedAmount != summary.CollectedAmount ||
			row.TotalExpenses != summary.TotalExpenses ||
			row.SubcontractorPaid != summary.SubcontractorPaid ||
			row.RemainingReceivable() != summary.RemainingReceivable ||
			row.RealizedCost() != summary.RealizedCost ||
			row.RealizedGrossProfit() != summary.RealizedGrossProfit {
			t.Errorf("liste aggregate'leri özetle tutmuyor:\nliste=%+v\nözet=%+v", row, summary)
		}
	})

	t.Run("18_completed_and_cancelled_project_rules", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		mustCollect(t, projectSvc, ctx, p.ID, orgA.ID, 1000, today)

		// active -> completed
		if _, err := projectSvc.Update(ctx, p.ID, orgA.ID, service.UpdateProjectInput{
			Name: p.Name, Status: domain.ProjectStatusActive,
		}); err != nil {
			t.Fatalf("aktife alınamadı: %v", err)
		}
		if _, err := projectSvc.Update(ctx, p.ID, orgA.ID, service.UpdateProjectInput{
			Name: p.Name, Status: domain.ProjectStatusCompleted,
		}); err != nil {
			t.Fatalf("tamamlanamadı: %v", err)
		}
		// Tamamlanmış projede YENİ hareket kilitli.
		if _, err := projectSvc.CreateCollection(ctx, p.ID, orgA.ID, service.CollectionInput{
			Amount: 500, Currency: "TRY", ReceivedDate: today,
		}); !errors.Is(err, service.ErrProjectLocked) {
			t.Errorf("tamamlanmış projeye tahsilat girilebildi: err=%v", err)
		}
		// Ama GEÇMİŞ veriler okunabilmeli.
		if rows, err := projectSvc.ListCollections(ctx, p.ID, orgA.ID); err != nil || len(rows) != 1 {
			t.Errorf("tamamlanmış projenin geçmiş tahsilatları okunamadı: %v / %d", err, len(rows))
		}
		if _, err := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID); err != nil {
			t.Errorf("tamamlanmış projenin özeti okunamadı: %v", err)
		}
		// Yeniden aktife alınırsa hareket girilebilmeli.
		if _, err := projectSvc.Update(ctx, p.ID, orgA.ID, service.UpdateProjectInput{
			Name: p.Name, Status: domain.ProjectStatusActive,
		}); err != nil {
			t.Fatalf("proje yeniden açılamadı: %v", err)
		}
		if _, err := projectSvc.CreateCollection(ctx, p.ID, orgA.ID, service.CollectionInput{
			Amount: 500, Currency: "TRY", ReceivedDate: today,
		}); err != nil {
			t.Errorf("yeniden açılan projeye tahsilat girilemedi: %v", err)
		}

		// İptal edilmiş projede hareket oluşturulamaz.
		p2 := newProject(t, orgA.ID, 50000)
		if _, err := projectSvc.Update(ctx, p2.ID, orgA.ID, service.UpdateProjectInput{
			Name: p2.Name, Status: domain.ProjectStatusCancelled,
		}); err != nil {
			t.Fatalf("iptal edilemedi: %v", err)
		}
		if _, err := projectSvc.CreateExpense(ctx, p2.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseOther, Description: "x", Amount: 10, Currency: "TRY", ExpenseDate: today,
		}); !errors.Is(err, service.ErrProjectLocked) {
			t.Errorf("iptal edilmiş projeye masraf girilebildi: err=%v", err)
		}
	})

	t.Run("19_audit_events_created", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		mustCollect(t, projectSvc, ctx, p.ID, orgA.ID, 1000, today)
		mustExpense(t, projectSvc, ctx, p.ID, orgA.ID, 500, today)
		sub, _ := projectSvc.CreateSubcontractor(ctx, p.ID, orgA.ID, service.SubcontractorInput{
			Name: "T", ContractAmount: 1000, Currency: "TRY",
		})
		if _, err := projectSvc.CreateSubcontractorPayment(ctx, p.ID, sub.ID, orgA.ID, service.SubcontractorPaymentInput{
			Amount: 400, Currency: "TRY", PaidDate: today,
		}); err != nil {
			t.Fatalf("ödeme eklenemedi: %v", err)
		}
		if _, err := projectSvc.CreateInvoice(ctx, p.ID, orgA.ID, service.InvoiceInput{
			InvoiceNo: "FTR-1", InvoiceType: domain.InvoiceTypeSales, InvoiceDate: today,
			Amount: 1000, Currency: "TRY",
		}); err != nil {
			t.Fatalf("fatura eklenemedi: %v", err)
		}

		events, err := projectSvc.ListProjectEvents(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("olaylar alınamadı: %v", err)
		}
		seen := map[string]bool{}
		for _, e := range events {
			seen[e.EventType] = true
		}
		for _, want := range []string{
			domain.ProjectEventCreated,
			domain.ProjectEventCollectionReceived,
			domain.ProjectEventExpenseAdded,
			domain.ProjectEventSubcontractorAdded,
			domain.ProjectEventSubcontractorPaymentMade,
			domain.ProjectEventInvoiceCreated,
		} {
			if !seen[want] {
				t.Errorf("%s olayı üretilmedi (üretilenler: %v)", want, seen)
			}
		}
		// Audit kaydı değişmez olmalı.
		if _, err := pool.Exec(ctx, "UPDATE project_events SET event_type = 'hacked' WHERE project_id = $1", p.ID); err == nil {
			t.Errorf("project_events güncellenebildi (immutable olmalıydı)")
		}
	})

	// Senaryo 20: liste sorgusu, proje sayısından BAĞIMSIZ sabit sayıda
	// sorgu çalıştırmalı (N+1 yok). pg_stat_statements'a bağımlı olmadan
	// ölçmek için, aynı listeyi 1 ve N projeyle çağırıp sorgu sayısını
	// pgx'in istatistiklerinden değil, mantıksal olarak doğruluyoruz:
	// ListProjects + CountProjects = 2 sorgu, proje sayısı ne olursa olsun.
	t.Run("20_list_has_no_n_plus_1", func(t *testing.T) {
		// Sorguları sayan ayrı bir havuzla ölç: liste, proje SAYISINDAN
		// bağımsız sabit sayıda sorgu çalıştırmalı (ListProjects +
		// CountProjects = 2). Satır başına ek sorgu açılsaydı bu sayı
		// proje sayısıyla birlikte büyürdü.
		countingPool, counter := newCountingPool(t, ctx, dbURL)
		countingSvc := service.NewProjectService(countingPool, sqlc.New(countingPool), mustTestStore(t), settingsSvc, "http://localhost:3000")

		list, err := countingSvc.List(ctx, orgA.ID, service.ProjectListFilter{Limit: 200})
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		queries := counter.count()
		if len(list.Projects) < 5 {
			t.Skipf("anlamlı ölçüm için yeterli proje yok: %d", len(list.Projects))
		}
		if queries > 4 {
			t.Errorf("liste %d proje için %d sorgu çalıştırdı (N+1; beklenen <=4)",
				len(list.Projects), queries)
		}
		t.Logf("%d proje için %d sorgu çalıştırıldı", len(list.Projects), queries)
	})

	// Eşzamanlı çift tıklama aynı tahsilatı iki kez yazmamalı
	// (idempotency_key + kısmi UNIQUE indeks).
	t.Run("21_concurrent_double_submit_is_idempotent", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		key := fmt.Sprintf("test-key-%d", time.Now().UnixNano())

		var wg sync.WaitGroup
		results := make([]*domain.Collection, 2)
		errs := make([]error, 2)
		for i := range 2 {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				results[i], errs[i] = projectSvc.CreateCollection(ctx, p.ID, orgA.ID, service.CollectionInput{
					Amount: 5000, Currency: "TRY", ReceivedDate: today, IdempotencyKey: key,
				})
			}(i)
		}
		wg.Wait()

		// Artık İKİSİ de başarılı olmalı ve AYNI kaydı dönmeli: kaybeden
		// istek, unique ihlalini yakalayıp kazananın kaydını döndürür
		// (eskiden ham pg hatası 500'e dönüşüyordu).
		for i, e := range errs {
			if e != nil {
				t.Fatalf("eşzamanlı aynı-anahtarlı istek #%d hata verdi: %v", i, e)
			}
		}
		if results[0] == nil || results[1] == nil || results[0].ID != results[1].ID {
			t.Fatalf("aynı anahtarla iki farklı kayıt döndü: %v / %v", results[0], results[1])
		}
		s, _ := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if s.CollectedAmount != 5000 {
			t.Errorf("çift tıklama tahsilatı iki kez yazdı: toplam=%v want 5000", s.CollectedAmount)
		}
	})

	// RBAC/Project Membership sprint'inin child-resource IDOR sıkılaştırması
	// (bkz. project_operations_test.go 18_cross_project_child_resource_idor_
	// blocked ile aynı ilke, finans uçları için): AYNI organizasyon
	// içindeki BAŞKA bir projenin finans kaydı, doğru projenin URL'si
	// üzerinden ASLA erişilemez/değiştirilemez olmalı.
	t.Run("22_cross_project_finance_idor_blocked", func(t *testing.T) {
		pA := newProject(t, orgA.ID, 100000)
		pB := newProject(t, orgA.ID, 100000) // AYNI organizasyon, FARKLI proje.

		itemB, err := projectSvc.CreatePaymentPlanItem(ctx, pB.ID, orgA.ID, service.PaymentPlanItemInput{
			Name: "B Kalemi", PlannedAmount: 1000,
		})
		if err != nil {
			t.Fatalf("B ödeme kalemi: %v", err)
		}
		collB, err := projectSvc.CreateCollection(ctx, pB.ID, orgA.ID, service.CollectionInput{
			Amount: 1000, Currency: "TRY", ReceivedDate: today,
		})
		if err != nil {
			t.Fatalf("B tahsilatı: %v", err)
		}
		expB, err := projectSvc.CreateExpense(ctx, pB.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "B masrafı", Amount: 500,
			Currency: "TRY", ExpenseDate: today,
		})
		if err != nil {
			t.Fatalf("B masrafı: %v", err)
		}
		subB, err := projectSvc.CreateSubcontractor(ctx, pB.ID, orgA.ID, service.SubcontractorInput{
			Name: "B Taşeronu", ContractAmount: 5000, Currency: "TRY",
		})
		if err != nil {
			t.Fatalf("B taşeronu: %v", err)
		}

		if _, err := projectSvc.UpdatePaymentPlanItem(ctx, pA.ID, itemB.ID, orgA.ID, service.PaymentPlanItemInput{Name: "X", PlannedAmount: 1}); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("A projesi üzerinden B'nin ödeme kalemi güncellenebildi: err=%v", err)
		}
		if err := projectSvc.CancelPaymentPlanItem(ctx, pA.ID, itemB.ID, orgA.ID, ""); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("A projesi üzerinden B'nin ödeme kalemi iptal edilebildi: err=%v", err)
		}
		if _, err := projectSvc.VoidCollection(ctx, pA.ID, collB.ID, orgA.ID, "", ""); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("A projesi üzerinden B'nin tahsilatı iptal edilebildi: err=%v", err)
		}
		if _, err := projectSvc.UpdateExpense(ctx, pA.ID, expB.ID, orgA.ID, service.ExpenseInput{Category: domain.ExpenseMaterial, Description: "X", Amount: 1, ExpenseDate: today}); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("A projesi üzerinden B'nin masrafı güncellenebildi: err=%v", err)
		}
		if _, err := projectSvc.VoidExpense(ctx, pA.ID, expB.ID, orgA.ID, "", ""); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("A projesi üzerinden B'nin masrafı iptal edilebildi: err=%v", err)
		}
		if _, err := projectSvc.UpdateSubcontractor(ctx, pA.ID, subB.ID, orgA.ID, service.SubcontractorInput{Name: "X", ContractAmount: 1, Status: domain.SubcontractorPlanned}); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("A projesi üzerinden B'nin taşeronu güncellenebildi: err=%v", err)
		}
		if _, err := projectSvc.CreateSubcontractorPayment(ctx, pA.ID, subB.ID, orgA.ID, service.SubcontractorPaymentInput{Amount: 1, Currency: "TRY", PaidDate: today}); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("A projesi üzerinden B'nin taşeronuna ödeme kaydedilebildi: err=%v", err)
		}

		// Doğru proje id'siyle (pB) aynı işlem başarılı olmalı (false
		// positive üretmediğini doğrular).
		if _, err := projectSvc.UpdateExpense(ctx, pB.ID, expB.ID, orgA.ID, service.ExpenseInput{Category: domain.ExpenseMaterial, Description: "Y", Amount: 1, ExpenseDate: today}); err != nil {
			t.Errorf("doğru proje id'siyle masraf güncellenemedi: %v", err)
		}
	})
}

func ptrFloat(f float64) *float64 { return &f }

func mustCollect(t *testing.T, svc *service.ProjectService, ctx context.Context, projectID, orgID string, amount float64, date time.Time) {
	t.Helper()
	if _, err := svc.CreateCollection(ctx, projectID, orgID, service.CollectionInput{
		Amount: amount, Currency: "TRY", ReceivedDate: date,
	}); err != nil {
		t.Fatalf("tahsilat eklenemedi (%v): %v", amount, err)
	}
}

func mustExpense(t *testing.T, svc *service.ProjectService, ctx context.Context, projectID, orgID string, amount float64, date time.Time) {
	t.Helper()
	if _, err := svc.CreateExpense(ctx, projectID, orgID, service.ExpenseInput{
		Category: domain.ExpenseMaterial, Description: "Test masrafı", Amount: amount,
		Currency: "TRY", ExpenseDate: date,
	}); err != nil {
		t.Fatalf("masraf eklenemedi (%v): %v", amount, err)
	}
}

// queryCounter, pgx'in QueryTracer arayüzüyle çalıştırılan SQL sorgularını
// sayar -- N+1 kontrolünü tahmine değil ölçüme dayandırmak için.
type queryCounter struct {
	mu sync.Mutex
	n  int
}

func (c *queryCounter) TraceQueryStart(ctx context.Context, _ *pgx.Conn, _ pgx.TraceQueryStartData) context.Context {
	c.mu.Lock()
	c.n++
	c.mu.Unlock()
	return ctx
}

func (c *queryCounter) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

func (c *queryCounter) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.n
}

// newCountingPool, her sorguyu sayan izleyicili ayrı bir havuz açar.
func newCountingPool(t *testing.T, ctx context.Context, dbURL string) (*pgxpool.Pool, *queryCounter) {
	t.Helper()
	cfg, err := pgxpool.ParseConfig(dbURL)
	if err != nil {
		t.Fatalf("havuz yapılandırması okunamadı: %v", err)
	}
	counter := &queryCounter{}
	cfg.ConnConfig.Tracer = counter
	// Tek bağlantı: bağlantı kurulumundaki ek sorgular ölçümü bulandırmasın.
	cfg.MinConns, cfg.MaxConns = 1, 1
	p, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatalf("sayan havuz açılamadı: %v", err)
	}
	t.Cleanup(p.Close)
	return p, counter
}
