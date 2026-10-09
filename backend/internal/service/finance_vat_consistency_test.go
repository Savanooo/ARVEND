package service_test

// Gerçekleşen maliyet ve kârın TEK formülü -- gerçek bir PostgreSQL bağlantısı
// gerektirir. Proje listesi (GET /projects), finans özeti
// (GET /projects/{id}/financial-summary), Maliyet Kontrolü ve ek iş
// kârlılığı aynı projede AYNI rakamları vermeli: onaylı + iptal edilmemiş
// masraflar, eski (legacy) taşeron ödemeleri ve taşeron modülü ödemeleri;
// onay bekleyen/reddedilen/iptal edilen masraf, iptal edilen ödeme ve
// onaylanmamış ek iş hiçbir yerde sayılmaz. KDV hariç karşılıklar finans
// özetinin kuralıyla (domain.VATBasis) türetilir: onaylı masrafların
// içindeki KDV düşülür, oranı belirtilmemiş masraf tamamıyla kalır.

import (
	"context"
	"math"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestFinanceVATConsistency(t *testing.T) {
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
	costCodeSvc := service.NewCostCodeService(pool, q)
	supplierSvc := service.NewSupplierService(pool, q, box)

	org := mustCreateOrg(t, ctx, orgSvc, pool, "KDV Tutarlılık Firma", "kdv-tutarlilik-firma")
	today := time.Now()

	// Sözleşme 1.200.000 KDV dahil = 1.000.000 + %20 KDV (200.000).
	newProject := func(t *testing.T, name string) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerName: "Tutarlılık Müşteri", VatRate: ptrFloat(20),
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
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, org.ID, service.CreateProjectInput{Name: name})
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
	approved := func(t *testing.T, projectID string, in service.ExpenseInput) *domain.Expense {
		t.Helper()
		e, err := createApprovedExpense(ctx, projectSvc, projectID, org.ID, in)
		if err != nil {
			t.Fatal(err)
		}
		return e
	}
	// changeOrder: %20 KDV'li ek iş/eksiltme; approve=true ise müşteri
	// linkten onaylar, false ise gönderilmiş (onay bekleyen) kalır.
	changeOrder := func(t *testing.T, projectID, changeType string, subtotal float64, approve bool) *domain.ChangeOrder {
		t.Helper()
		co, err := projectSvc.CreateChangeOrder(ctx, projectID, org.ID, service.ChangeOrderInput{
			ChangeType: changeType, Title: "Ek iş " + changeType, VatRate: 20,
			Items: []service.ChangeOrderItemInput{{Description: "Kalem", Quantity: 1, Unit: "adet", UnitPrice: subtotal}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.SendChangeOrder(ctx, projectID, co.ID, org.ID, ""); err != nil {
			t.Fatal(err)
		}
		if !approve {
			return co
		}
		var token string
		if err := pool.QueryRow(ctx, `SELECT token::text FROM project_change_order_share_links
			WHERE change_order_id = $1 AND revoked_at IS NULL ORDER BY created_at DESC LIMIT 1`, co.ID).Scan(&token); err != nil {
			t.Fatalf("aktif link bulunamadı: %v", err)
		}
		out, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", "")
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	listRow := func(t *testing.T, projectID string) domain.Project {
		t.Helper()
		list, err := projectSvc.List(ctx, org.ID, service.ProjectListFilter{Limit: 200})
		if err != nil {
			t.Fatal(err)
		}
		for _, p := range list.Projects {
			if p.ID == projectID {
				return p
			}
		}
		t.Fatalf("proje listede yok")
		return domain.Project{}
	}
	near := func(a, b float64) bool { return math.Abs(a-b) < 0.005 }

	// ---------- Ortak senaryo: her maliyet kaynağı + her dışlanan kayıt ----------
	p := newProject(t, "KDV Tutarlılık Projesi")

	// Güncel bedel: 1.200.000 + 60.000 (ek iş, KDV 10.000) - 12.000
	// (eksiltme, KDV 2.000) = 1.248.000; KDV 208.000; KDV hariç 1.040.000.
	// Gönderilmiş ama onaylanmamış ek iş hiçbir yerde sayılmaz.
	co1 := changeOrder(t, p.ID, domain.ChangeOrderAddition, 50000, true)
	co2 := changeOrder(t, p.ID, domain.ChangeOrderDeduction, 10000, true)
	changeOrder(t, p.ID, domain.ChangeOrderAddition, 7000, false)

	// Bütçe kalemi + kodlu masraf (Maliyet Kontrolü'nün gerçekleşeni).
	cc, err := costCodeSvc.Create(ctx, org.ID, service.CostCodeInput{Code: "TUT-MLZ", Name: "Malzeme", Category: "Malzeme"})
	if err != nil {
		t.Fatal(err)
	}
	line, err := projectSvc.CreateBudgetLine(ctx, p.ID, org.ID, service.BudgetLineInput{
		CostCodeID: cc.ID, Description: "Malzeme", OriginalAmount: 500000,
	})
	if err != nil {
		t.Fatal(err)
	}

	// Onaylı masraflar: 221.850,01 TL, içlerindeki KDV 31.000,99.
	approved(t, p.ID, expense(120000, ptrFloat(20))) // KDV 20.000
	approved(t, p.ID, expense(30000, nil))           // belirtilmemiş: tamamı maliyet
	approved(t, p.ID, expense(750, ptrFloat(0)))     // KDV yok
	approved(t, p.ID, expense(100.01, ptrFloat(1)))  // KDV 0,99 (kuruş yuvarlaması)
	coExpense := expense(11000, ptrFloat(10))        // KDV 1.000, ek işe bağlı
	coExpense.ChangeOrderID = co1.ID
	approved(t, p.ID, coExpense)
	coded := expense(60000, ptrFloat(20)) // KDV 10.000, bütçe kalemine bağlı
	coded.BudgetLineID = line.ID
	approved(t, p.ID, coded)

	// Hiçbir yerde sayılmayanlar: onay bekleyen, reddedilen, onaylanıp iptal edilen.
	if _, err := projectSvc.CreateExpense(ctx, p.ID, org.ID, expense(60000, ptrFloat(20))); err != nil {
		t.Fatal(err)
	}
	rejected, err := projectSvc.CreateExpense(ctx, p.ID, org.ID, expense(9000, ptrFloat(20)))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := projectSvc.RejectExpense(ctx, p.ID, rejected.ID, org.ID, "", "Fatura yok"); err != nil {
		t.Fatal(err)
	}
	voided := approved(t, p.ID, expense(12000, ptrFloat(20)))
	if _, err := projectSvc.VoidExpense(ctx, p.ID, voided.ID, org.ID, "", "Mükerrer"); err != nil {
		t.Fatal(err)
	}

	// Eski (legacy) taşeron: 50.000 sözleşme, 25.000 ödendi (+ iptal edilen 5.000).
	legacy, err := projectSvc.CreateSubcontractor(ctx, p.ID, org.ID, service.SubcontractorInput{
		Name: "Eski Taşeron", ContractAmount: 50000, Currency: "TRY",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := projectSvc.CreateSubcontractorPayment(ctx, p.ID, legacy.ID, org.ID, service.SubcontractorPaymentInput{
		Amount: 25000, Currency: "TRY", PaidDate: today,
	}); err != nil {
		t.Fatal(err)
	}
	legacyVoid, err := projectSvc.CreateSubcontractorPayment(ctx, p.ID, legacy.ID, org.ID, service.SubcontractorPaymentInput{
		Amount: 5000, Currency: "TRY", PaidDate: today,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := projectSvc.VoidSubcontractorPayment(ctx, p.ID, legacyVoid.ID, org.ID, "", "Hatalı"); err != nil {
		t.Fatal(err)
	}

	// Taşeron modülü: aktif 100.000'lik sözleşme, 40.000 ödendi (+ iptal edilen 3.000).
	sup, err := supplierSvc.Create(ctx, org.ID, service.SupplierInput{Code: "TUT-TAS", LegalName: "Tutarlılık Taşeron", Specialty: "Kaba"})
	if err != nil {
		t.Fatal(err)
	}
	scCode, err := costCodeSvc.Create(ctx, org.ID, service.CostCodeInput{Code: "TUT-TAS", Name: "Taşeron", Category: "Taşeron"})
	if err != nil {
		t.Fatal(err)
	}
	sc, err := projectSvc.CreateSubcontract(ctx, p.ID, org.ID, service.SubcontractInput{
		SupplierID: sup.ID, Title: "Kaba inşaat",
		Items: []service.SubcontractItemInput{{CostCodeID: scCode.ID, Description: "İmalat", OriginalAmount: 100000}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := projectSvc.ActivateSubcontract(ctx, p.ID, sc.ID, org.ID, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, org.ID, service.SubcontractPaymentInput{
		Amount: 40000, Currency: "TRY", PaidDate: today,
	}); err != nil {
		t.Fatal(err)
	}
	scVoid, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, org.ID, service.SubcontractPaymentInput{
		Amount: 3000, Currency: "TRY", PaidDate: today,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := projectSvc.VoidSubcontractPayment(ctx, p.ID, scVoid.ID, org.ID, "", "Hatalı"); err != nil {
		t.Fatal(err)
	}

	// Tahsilat 300.000 (+ iptal edilen 50.000).
	if _, err := projectSvc.CreateCollection(ctx, p.ID, org.ID, service.CollectionInput{
		Amount: 300000, Currency: "TRY", ReceivedDate: today,
	}); err != nil {
		t.Fatal(err)
	}
	collVoid, err := projectSvc.CreateCollection(ctx, p.ID, org.ID, service.CollectionInput{
		Amount: 50000, Currency: "TRY", ReceivedDate: today,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := projectSvc.VoidCollection(ctx, p.ID, collVoid.ID, org.ID, "", "Hatalı"); err != nil {
		t.Fatal(err)
	}

	fs, err := projectSvc.FinancialSummary(ctx, p.ID, org.ID)
	if err != nil {
		t.Fatal(err)
	}

	t.Run("1_project_list_equals_financial_summary", func(t *testing.T) {
		row := listRow(t, p.ID)
		// Liste ile özet BİREBİR aynı (float eşitliği: ikisi de kuruşa yuvarlı).
		pairs := []struct {
			name       string
			list, summ float64
			want       float64
		}{
			{"current_contract_value", row.CurrentContractValue(), fs.CurrentContractValue, 1248000},
			{"remaining_receivable", row.RemainingReceivable(), fs.RemainingReceivable, 948000},
			{"total_expenses", row.TotalExpenses, fs.TotalExpenses, 221850.01},
			{"expense_vat_total", row.ExpenseVATTotal, fs.ExpenseVATTotal, 31000.99},
			{"subcontractor_paid", row.SubcontractorPaid, fs.SubcontractorPaid, 25000},
			{"new_subcontract_paid", row.NewSubcontractPaid, fs.NewSubcontractPaid, 40000},
			// 221.850,01 + 25.000 + 40.000
			{"realized_cost", row.RealizedCost(), fs.RealizedCost, 286850.01},
			{"realized_gross_profit", row.RealizedGrossProfit(), fs.RealizedGrossProfit, 961149.99},
			{"contract_vat_amount", row.ContractVATAmount, fs.ContractVATAmount, 208000},
			{"current_contract_value_net", row.CurrentContractValueNet(), fs.CurrentContractValueNet, 1040000},
			// 286.850,01 - 31.000,99
			{"realized_cost_net", row.RealizedCostNet(), fs.RealizedCostNet, 255849.02},
			// 1.040.000 - 255.849,02
			{"realized_gross_profit_net", row.RealizedGrossProfitNet(), fs.RealizedGrossProfitNet, 784150.98},
		}
		for _, c := range pairs {
			if c.list != c.summ {
				t.Errorf("%s: liste %v != özet %v", c.name, c.list, c.summ)
			}
			if c.summ != c.want {
				t.Errorf("%s: %v, beklenen %v", c.name, c.summ, c.want)
			}
		}
		if !row.ContractVATKnown || !fs.ContractVATKnown {
			t.Errorf("tekliften açılan projede sözleşme KDV'si bilinir: liste %v özet %v", row.ContractVATKnown, fs.ContractVATKnown)
		}
	})

	t.Run("2_cost_control_nets_follow_summary_rule", func(t *testing.T) {
		cs, err := projectSvc.CostControlSummary(ctx, p.ID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		// Gerçekleşen yalnızca kodlu masraf: 60.000 (KDV 10.000). ETC KDV dahil
		// gerçekleşenden: 500.000 - 60.000 = 440.000, KDV'si bilinmez.
		if cs.ActualCost != 60000 || cs.ActualCostNet != 50000 {
			t.Errorf("gerçekleşen dahil/hariç: %v %v", cs.ActualCost, cs.ActualCostNet)
		}
		if cs.EACTotal != 500000 || cs.EACNet != 490000 {
			t.Errorf("EAC dahil/hariç: %v %v", cs.EACTotal, cs.EACNet)
		}
		// Sözleşme bedeli ve KDV'si finans özetiyle aynı kaynaktan.
		if cs.ContractValue != fs.CurrentContractValue || cs.ContractValueNet != fs.CurrentContractValueNet ||
			cs.ContractVATAmount != fs.ContractVATAmount || cs.ContractVATKnown != fs.ContractVATKnown {
			t.Errorf("sözleşme: %v/%v %v/%v %v/%v %v/%v", cs.ContractValue, fs.CurrentContractValue,
				cs.ContractValueNet, fs.CurrentContractValueNet, cs.ContractVATAmount, fs.ContractVATAmount,
				cs.ContractVATKnown, fs.ContractVATKnown)
		}
		// Tahmini kâr: KDV dahil 1.248.000 - 500.000; KDV hariç 1.040.000 - 490.000.
		if cs.ForecastProfit != 748000 || cs.ForecastProfitNet != 550000 || cs.ForecastMarginPercentNet != 52.88 {
			t.Errorf("tahmini kâr dahil/hariç/marj: %v %v %v", cs.ForecastProfit, cs.ForecastProfitNet, cs.ForecastMarginPercentNet)
		}

		// Satırların toplamı özete eşit (proje toplamı satır toplamıdır).
		lines, err := projectSvc.CostControlLines(ctx, p.ID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		var actualNet, eacNet float64
		for _, l := range lines {
			actualNet += l.ActualCostNet
			eacNet += l.EACNet
			if !near(l.EACNet, l.ActualCostNet+l.ETCAmount) {
				t.Errorf("satır EAC hariç = gerçekleşen hariç + ETC olmalı: %+v", l)
			}
		}
		if !near(actualNet, cs.ActualCostNet) || !near(eacNet, cs.EACNet) {
			t.Errorf("satır toplamları: %v/%v %v/%v", actualNet, cs.ActualCostNet, eacNet, cs.EACNet)
		}

		// Finans özetinin bütçe bazlı tahmini Maliyet Kontrolü'nün EAC'sinden +
		// eski taşeron (ödenen 25.000 + kalan 25.000).
		if fs.ForecastBasis != domain.ForecastBasisBudget || fs.ForecastCost != 550000 || fs.ForecastCostNet != 540000 {
			t.Errorf("özet tahmini: %v %v %v", fs.ForecastBasis, fs.ForecastCost, fs.ForecastCostNet)
		}
		if fs.ForecastCostNet != cs.EACNet+fs.SubcontractorPaid+fs.SubcontractorRemaining || fs.ForecastProfitNet != 500000 {
			t.Errorf("özetin KDV hariç tahmini Maliyet Kontrolü'nden gelmeli: %v %v", fs.ForecastCostNet, fs.ForecastProfitNet)
		}
	})

	t.Run("3_change_order_profitability_nets", func(t *testing.T) {
		cos, err := projectSvc.ListChangeOrders(ctx, p.ID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		byID := map[string]*domain.ChangeOrderProfitability{}
		for _, co := range cos {
			byID[co.ID] = co.Profitability
		}
		add, ded := byID[co1.ID], byID[co2.ID]
		if add == nil || ded == nil {
			t.Fatalf("kârlılık yok: %+v %+v", add, ded)
		}
		// Ek iş: gelir 60.000 (KDV hariç 50.000); bağlı masraf 11.000 (KDV 1.000).
		if add.RevenueEffect != 60000 || add.RealizedCost != 11000 || add.RealizedProfit != 49000 {
			t.Errorf("ek iş KDV dahil: %+v", add)
		}
		if add.RevenueEffectNet != 50000 || add.RealizedCostNet != 10000 || add.CommittedCostNet != 10000 ||
			add.RealizedProfitNet != 40000 || add.EstimatedProfitNet != 40000 || add.RealizedMarginPercentNet != 80 {
			t.Errorf("ek iş KDV hariç: %+v", add)
		}
		// Eksiltme: gelir etkisi -12.000 (KDV hariç -10.000), maliyet yok.
		if ded.RevenueEffectNet != -10000 || ded.RealizedProfitNet != -10000 || ded.RealizedMarginPercentNet != -100 {
			t.Errorf("eksiltme KDV hariç: %+v", ded)
		}
	})

	t.Run("4_without_vat_rates_nets_equal_gross_costs", func(t *testing.T) {
		plain := newProject(t, "KDV'siz Masraf Projesi")
		approved(t, plain.ID, expense(1000, nil))
		row := listRow(t, plain.ID)
		pfs, err := projectSvc.FinancialSummary(ctx, plain.ID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		if row.RealizedCostNet() != row.RealizedCost() || row.RealizedCostNet() != pfs.RealizedCostNet || row.RealizedCost() != 1000 {
			t.Errorf("oranı belirtilmemiş masraf tamamıyla maliyet: %v %v %v", row.RealizedCostNet(), row.RealizedCost(), pfs.RealizedCostNet)
		}
		// Kâr: KDV hariç bedel (1.000.000) - maliyet (1.000).
		if row.RealizedGrossProfitNet() != 999000 || row.RealizedGrossProfitNet() != pfs.RealizedGrossProfitNet {
			t.Errorf("kâr hariç: %v %v", row.RealizedGrossProfitNet(), pfs.RealizedGrossProfitNet)
		}
	})
}
