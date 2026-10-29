package service_test

// Satın almalar proje maliyetine girer (migration 0078, docs/maliyet-
// tanimlari.md "Satın almalar") -- gerçek bir PostgreSQL bağlantısı
// gerektirir. Ürün sahibi kararı: talep ONAYLANINCA maliyete girer ve
// onaylarken "proje maliyetine eklensin mi" diye sorulur. Onaylı sipariş
// talebin tahmininin YERİNE geçer; satın alma max(sipariş, bağlı onaylı
// faturalar) kadar sayılır ve bağlı faturalar ayrıca masraf olarak
// sayılmaz. Finans özeti, Maliyet Kontrolü, proje listesi ve Ana Sayfa aynı
// rakamı verir.

import (
	"errors"
	"math"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestPurchaseProjectCost(t *testing.T) {
	e := newDashTestEnv(t, "satin-alma-maliyet")
	ctx := e.ctx
	org := e.org.ID
	svc := e.projectSvc
	q := sqlc.New(e.pool)
	costCodeSvc := service.NewCostCodeService(e.pool, q)
	supplierSvc := service.NewSupplierService(e.pool, q, testSecretBox(t))
	today := time.Now()
	near := func(a, b float64) bool { return math.Abs(a-b) < 0.005 }
	yes, no := true, false

	cc, err := costCodeSvc.Create(ctx, org, service.CostCodeInput{Code: "SAM-MLZ", Name: "Malzeme", Category: "Malzeme"})
	if err != nil {
		t.Fatal(err)
	}
	sup, err := supplierSvc.Create(ctx, org, service.SupplierInput{Code: "SAM-SUP", LegalName: "Yapı Market", Specialty: "Malzeme"})
	if err != nil {
		t.Fatal(err)
	}
	p := e.project(t, "Satın Alma Maliyeti", domain.ProjectStatusActive, "TRY", 1000000)

	summary := func(t *testing.T) *domain.ProjectFinancialSummary {
		t.Helper()
		fs, err := svc.FinancialSummary(ctx, p.ID, org)
		if err != nil {
			t.Fatal(err)
		}
		return fs
	}
	costControl := func(t *testing.T) *domain.CostControlSummary {
		t.Helper()
		s, err := svc.CostControlSummary(ctx, p.ID, org)
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	item := func(desc string, qty float64, unit *float64) service.PurchaseRequestItemInput {
		return service.PurchaseRequestItemInput{CostCodeID: cc.ID, Description: desc, Quantity: qty, Unit: "adet", EstimatedUnitCost: unit}
	}
	price := func(v float64) *float64 { return &v }
	submittedPR := func(t *testing.T, items ...service.PurchaseRequestItemInput) *domain.PurchaseRequest {
		t.Helper()
		pr, err := svc.CreatePurchaseRequest(ctx, p.ID, org, service.PurchaseRequestInput{Title: "Talep", Items: items})
		if err != nil {
			t.Fatal(err)
		}
		if pr, err = svc.SubmitPurchaseRequest(ctx, p.ID, pr.ID, org, ""); err != nil {
			t.Fatal(err)
		}
		return pr
	}
	approve := func(t *testing.T, pr *domain.PurchaseRequest, d service.PurchaseCostDecision) *domain.PurchaseRequest {
		t.Helper()
		out, err := svc.ApprovePurchaseRequestWithCost(ctx, p.ID, pr.ID, org, "", d)
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	prCost := func(t *testing.T, prID string) domain.PurchaseCost {
		t.Helper()
		out, err := svc.PurchaseRequestCosts(ctx, p.ID, prID, org)
		if err != nil {
			t.Fatal(err)
		}
		return out[prID]
	}
	poCost := func(t *testing.T, poID string) domain.PurchaseCost {
		t.Helper()
		out, err := svc.PurchaseOrderCosts(ctx, p.ID, poID, org)
		if err != nil {
			t.Fatal(err)
		}
		return out[poID]
	}
	newPO := func(t *testing.T, prID string, items ...service.PurchaseOrderItemInput) *domain.PurchaseOrder {
		t.Helper()
		po, err := svc.CreatePurchaseOrder(ctx, p.ID, org, service.PurchaseOrderInput{
			SupplierID: sup.ID, PurchaseRequestID: prID, IssueDate: today, TaxRate: 20, Items: items,
		})
		if err != nil {
			t.Fatal(err)
		}
		return po
	}
	poItem := func(desc string, qty, unitPrice float64) service.PurchaseOrderItemInput {
		return service.PurchaseOrderItemInput{CostCodeID: cc.ID, Description: desc, Quantity: qty, Unit: "adet", UnitPrice: unitPrice}
	}
	invoice := func(t *testing.T, poID string, amount float64) {
		t.Helper()
		vat := 20.0
		in := service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Alış faturası", Amount: amount, Currency: "TRY",
			ExpenseDate: today, CostCodeID: cc.ID, VATRate: &vat,
		}
		if poID != "" {
			in.PurchaseOrderID = &poID
		}
		if _, err := createApprovedExpense(ctx, svc, p.ID, org, in); err != nil {
			t.Fatal(err)
		}
	}
	type check struct {
		name      string
		got, want float64
	}
	expect := func(t *testing.T, checks ...check) {
		t.Helper()
		for _, c := range checks {
			if !near(c.got, c.want) {
				t.Errorf("%s = %v, beklenen %v", c.name, c.got, c.want)
			}
		}
	}

	var pr1 *domain.PurchaseRequest
	var po1 *domain.PurchaseOrder

	t.Run("1_submitted_request_is_not_cost", func(t *testing.T) {
		// 10 x 1.000 + 5 x 200 = 11.000 tahmini.
		pr1 = submittedPR(t, item("Alçıpan", 10, price(1000)), item("Vida", 5, price(200)))
		fs := summary(t)
		c := prCost(t, pr1.ID)
		expect(t,
			check{"purchase_cost", fs.PurchaseCost, 0},
			check{"realized_cost", fs.RealizedCost, 0},
			check{"talep amount", c.Amount, 0},
			check{"talep potential (onay ekranı)", c.Potential, 11000},
		)
		if c.Source != domain.PurchaseCostSourceNone || c.Warning != "" || !c.Included {
			t.Fatalf("onay bekleyen talep: %+v", c)
		}
	})

	t.Run("2_approved_request_counts_its_estimate", func(t *testing.T) {
		out := approve(t, pr1, service.PurchaseCostDecision{})
		if !out.IncludeInProjectCost || out.CostEstimate != nil {
			t.Fatalf("kararsız onay maliyete ekler, tahmin kalemlerden: %+v", out)
		}
		fs, ctl, c := summary(t), costControl(t), prCost(t, pr1.ID)
		expect(t,
			check{"purchase_cost", fs.PurchaseCost, 11000},
			check{"realized_cost", fs.RealizedCost, 11000},
			// Talep tahmininin KDV'si bilinmez: KDV hariç maliyet aynıdır.
			check{"realized_cost_vat", fs.RealizedCostVAT, 0},
			check{"realized_cost_net", fs.RealizedCostNet, 11000},
			check{"cost_control actual", ctl.ActualCost, 11000},
			check{"cost_control purchase_actual", ctl.PurchaseActualCost, 11000},
			check{"talep amount", c.Amount, 11000},
		)
		if c.Source != domain.PurchaseCostSourceEstimate {
			t.Fatalf("kaynak tahmin olmalı: %+v", c)
		}
	})

	t.Run("3_approved_order_replaces_estimate", func(t *testing.T) {
		// 10 x 1.100 + 5 x 200 = 12.000 + %20 KDV 2.400 = 14.400.
		po1 = newPO(t, pr1.ID, poItem("Alçıpan", 10, 1100), poItem("Vida", 5, 200))
		if po1.PurchaseRequestID == nil || *po1.PurchaseRequestID != pr1.ID || !po1.IncludeInProjectCost {
			t.Fatalf("talepten açılan sipariş talebe bağlanır ve kararı devralır: %+v", po1)
		}
		if fs := summary(t); !near(fs.PurchaseCost, 11000) {
			t.Fatalf("taslak sipariş tahminin yerine geçmez: %v", fs.PurchaseCost)
		}
		if c := poCost(t, po1.ID); !near(c.Potential, 14400) || c.Amount != 0 {
			t.Fatalf("taslak siparişin onaylanırsa gireceği tutar: %+v", c)
		}
		if _, err := svc.ApprovePurchaseOrder(ctx, p.ID, po1.ID, org, ""); err != nil {
			t.Fatal(err)
		}
		fs, ctl := summary(t), costControl(t)
		expect(t,
			// İkisi birden ASLA: 11.000 + 14.400 değil.
			check{"purchase_cost", fs.PurchaseCost, 14400},
			check{"purchase_cost_vat", fs.PurchaseCostVAT, 2400},
			check{"realized_cost", fs.RealizedCost, 14400},
			check{"realized_cost_net", fs.RealizedCostNet, 12000},
			check{"cost_control actual", ctl.ActualCost, 14400},
			check{"cost_control actual_net", ctl.ActualCostNet, 12000},
			check{"talep amount", prCost(t, pr1.ID).Amount, 14400},
			check{"sipariş amount", poCost(t, po1.ID).Amount, 14400},
		)
		if c := prCost(t, pr1.ID); c.Source != domain.PurchaseCostSourceOrders {
			t.Fatalf("talebin kaynağı siparişleri olmalı: %+v", c)
		}
	})

	t.Run("4_partial_invoice_keeps_order_amount_no_double_count", func(t *testing.T) {
		invoice(t, po1.ID, 6000) // KDV 1.000
		fs, ctl := summary(t), costControl(t)
		expect(t,
			check{"total_expenses (nakit)", fs.TotalExpenses, 6000},
			check{"expense_cost", fs.ExpenseCost, 0},
			check{"purchase_cost", fs.PurchaseCost, 14400},
			check{"purchase_cost_vat", fs.PurchaseCostVAT, 2400},
			check{"realized_cost", fs.RealizedCost, 14400},
			check{"paid_cost", fs.PaidCost, 6000},
			check{"cost_control actual", ctl.ActualCost, 14400},
			check{"faturalanan", poCost(t, po1.ID).InvoicedAmount, 6000},
		)
	})

	t.Run("5_invoices_above_order_raise_cost", func(t *testing.T) {
		invoice(t, po1.ID, 10000) // KDV 1.666,67; faturalar 16.000 > sipariş 14.400
		fs, ctl, c := summary(t), costControl(t), poCost(t, po1.ID)
		expect(t,
			check{"purchase_cost", fs.PurchaseCost, 16000},
			check{"purchase_cost_vat", fs.PurchaseCostVAT, 2666.67},
			check{"realized_cost", fs.RealizedCost, 16000},
			check{"realized_cost_net", fs.RealizedCostNet, 13333.33},
			check{"expense_cost", fs.ExpenseCost, 0},
			check{"cost_control actual", ctl.ActualCost, 16000},
			check{"cost_control actual_net", ctl.ActualCostNet, 13333.33},
			check{"sipariş amount", c.Amount, 16000},
		)
		if c.Source != domain.PurchaseCostSourceInvoices {
			t.Fatalf("faturalar siparişi aştı: %+v", c)
		}
	})

	t.Run("6_unlinked_expense_is_a_separate_line", func(t *testing.T) {
		if _, err := createApprovedExpense(ctx, svc, p.ID, org, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Nakliye", Amount: 500, Currency: "TRY", ExpenseDate: today, CostCodeID: cc.ID,
		}); err != nil {
			t.Fatal(err)
		}
		fs := summary(t)
		expect(t,
			check{"expense_cost", fs.ExpenseCost, 500},
			check{"realized_cost", fs.RealizedCost, 16500},
			check{"total_expenses", fs.TotalExpenses, 16500},
			check{"cost_control actual", costControl(t).ActualCost, 16500},
		)
	})

	t.Run("7_cancelled_order_falls_back_to_estimate", func(t *testing.T) {
		pr2 := approve(t, submittedPR(t, item("Çimento", 3, price(1000))), service.PurchaseCostDecision{})
		if fs := summary(t); !near(fs.PurchaseCost, 19000) {
			t.Fatalf("16.000 + 3.000 tahmin: %v", fs.PurchaseCost)
		}
		po2 := newPO(t, pr2.ID, poItem("Çimento", 3, 1000)) // 3.600
		if _, err := svc.ApprovePurchaseOrder(ctx, p.ID, po2.ID, org, ""); err != nil {
			t.Fatal(err)
		}
		if fs := summary(t); !near(fs.PurchaseCost, 19600) {
			t.Fatalf("sipariş tahminin yerine: 16.000 + 3.600 = %v", fs.PurchaseCost)
		}
		if _, err := svc.CancelPurchaseOrder(ctx, p.ID, po2.ID, org, "", "tedarikçi vazgeçti"); err != nil {
			t.Fatal(err)
		}
		fs, c := summary(t), prCost(t, pr2.ID)
		expect(t, check{"purchase_cost", fs.PurchaseCost, 19000}, check{"talep amount", c.Amount, 3000})
		if c.Source != domain.PurchaseCostSourceEstimate {
			t.Fatalf("siparişi iptal edilen onaylı talep tahmine döner: %+v", c)
		}
	})

	var pr3 *domain.PurchaseRequest
	var po3 *domain.PurchaseOrder

	t.Run("8_flag_false_counts_nothing", func(t *testing.T) {
		pr3 = approve(t, submittedPR(t, item("Depo malzemesi", 2, price(500))), service.PurchaseCostDecision{Include: &no})
		fs, c := summary(t), prCost(t, pr3.ID)
		expect(t,
			check{"purchase_cost", fs.PurchaseCost, 19000},
			check{"purchase_excluded", fs.PurchaseExcluded, 1000},
			check{"talep amount", c.Amount, 0},
			check{"talep potential", c.Potential, 1000},
		)
		if c.Included {
			t.Fatal("karar hayır olmalı")
		}
		po3 = newPO(t, pr3.ID, poItem("Depo malzemesi", 1, 1000)) // 1.200
		if po3.IncludeInProjectCost {
			t.Fatal("sipariş talebin 'hayır' kararını devralmalı")
		}
		if _, err := svc.ApprovePurchaseOrder(ctx, p.ID, po3.ID, org, ""); err != nil {
			t.Fatal(err)
		}
		invoice(t, po3.ID, 1500)
		fs = summary(t)
		expect(t,
			check{"purchase_cost", fs.PurchaseCost, 19000},
			check{"purchase_excluded = max(1.200, 1.500)", fs.PurchaseExcluded, 1500},
			// Maliyete eklenmeyen satın almanın faturası masraf satırına da girmez.
			check{"expense_cost", fs.ExpenseCost, 500},
			check{"realized_cost", fs.RealizedCost, 19500},
			// Nakit gerçektir: ödenen bütün onaylı masraflardır.
			check{"total_expenses", fs.TotalExpenses, 18000},
			check{"paid_cost", fs.PaidCost, 18000},
			check{"cost_control actual", costControl(t).ActualCost, 19500},
		)
	})

	t.Run("9_decision_changes_later_and_cascades", func(t *testing.T) {
		out, err := svc.SetPurchaseRequestCost(ctx, p.ID, pr3.ID, org, "", service.PurchaseCostDecision{Include: &yes})
		if err != nil || !out.IncludeInProjectCost {
			t.Fatalf("karar değişmeli: %v %+v", err, out)
		}
		po, err := svc.GetPurchaseOrder(ctx, p.ID, po3.ID, org)
		if err != nil || !po.IncludeInProjectCost {
			t.Fatalf("talebin kararı açık siparişe de uygulanmalı: %v %+v", err, po)
		}
		fs := summary(t)
		expect(t, check{"purchase_cost", fs.PurchaseCost, 20500}, check{"purchase_excluded", fs.PurchaseExcluded, 0})

		if _, err := svc.SetPurchaseOrderCost(ctx, p.ID, po3.ID, org, "", false); err != nil {
			t.Fatal(err)
		}
		fs = summary(t)
		expect(t, check{"purchase_cost", fs.PurchaseCost, 19000}, check{"purchase_excluded", fs.PurchaseExcluded, 1500})

		if _, err := svc.SetPurchaseRequestCost(ctx, p.ID, pr3.ID, org, "", service.PurchaseCostDecision{}); !errors.Is(err, service.ErrPurchaseCostDecisionEmpty) {
			t.Fatalf("boş karar reddedilmeli: %v", err)
		}
		neg := -1.0
		if _, err := svc.SetPurchaseRequestCost(ctx, p.ID, pr3.ID, org, "", service.PurchaseCostDecision{CostEstimate: &neg}); !errors.Is(err, service.ErrInvalidCostEstimate) {
			t.Fatalf("negatif tahmin reddedilmeli: %v", err)
		}
		draft, err := svc.CreatePurchaseRequest(ctx, p.ID, org, service.PurchaseRequestInput{Title: "Taslak", Items: []service.PurchaseRequestItemInput{item("x", 1, price(1))}})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := svc.SetPurchaseRequestCost(ctx, p.ID, draft.ID, org, "", service.PurchaseCostDecision{Include: &no}); !errors.Is(err, service.ErrPurchaseRequestCostNotChangeable) {
			t.Fatalf("onaylanmamış talebin kararı değiştirilemez: %v", err)
		}
		events, err := svc.ListProjectEvents(ctx, p.ID, org)
		if err != nil {
			t.Fatal(err)
		}
		var reqEvt, ordEvt bool
		for _, ev := range events {
			reqEvt = reqEvt || ev.EventType == domain.ProjectEventPurchaseRequestCostDecision
			ordEvt = ordEvt || ev.EventType == domain.ProjectEventPurchaseOrderCostDecision
		}
		if !reqEvt || !ordEvt {
			t.Fatalf("karar değişiklikleri olay kaydına yazılmalı: talep %v sipariş %v", reqEvt, ordEvt)
		}
	})

	t.Run("10_rejected_and_cancelled_requests_count_nothing", func(t *testing.T) {
		rejected := submittedPR(t, item("Reddedilecek", 1, price(800)))
		if _, err := svc.RejectPurchaseRequest(ctx, p.ID, rejected.ID, org, "", "gerek yok"); err != nil {
			t.Fatal(err)
		}
		cancelled := approve(t, submittedPR(t, item("İptal edilecek", 1, price(700))), service.PurchaseCostDecision{})
		if fs := summary(t); !near(fs.PurchaseCost, 19700) {
			t.Fatalf("onaylı talep sayılır: %v", fs.PurchaseCost)
		}
		if _, err := svc.CancelPurchaseRequest(ctx, p.ID, cancelled.ID, org, "", "vazgeçildi"); err != nil {
			t.Fatal(err)
		}
		fs := summary(t)
		expect(t,
			check{"purchase_cost", fs.PurchaseCost, 19000},
			check{"reddedilen amount", prCost(t, rejected.ID).Amount, 0},
			check{"iptal edilen amount", prCost(t, cancelled.ID).Amount, 0},
		)
	})

	t.Run("11_no_price_warning_and_estimate_at_approval", func(t *testing.T) {
		pr6 := submittedPR(t, item("Kum", 3, nil))
		c := prCost(t, pr6.ID)
		if c.Warning != domain.PurchaseCostNoPriceWarning || c.UnpricedItems != 1 || c.Potential != 0 {
			t.Fatalf("fiyatsız talep onaydan önce uyarmalı: %+v", c)
		}
		estimate := 2500.0
		out := approve(t, pr6, service.PurchaseCostDecision{Include: &yes, CostEstimate: &estimate})
		if out.CostEstimate == nil || *out.CostEstimate != 2500 {
			t.Fatalf("onayda girilen tahmin saklanmalı: %+v", out.CostEstimate)
		}
		c = prCost(t, pr6.ID)
		fs := summary(t)
		expect(t,
			check{"talep amount", c.Amount, 2500},
			check{"purchase_cost", fs.PurchaseCost, 21500},
			// Talebin tek kalemi maliyet koduna bağlı: tahmin Maliyet Kontrolü'nde de görünür.
			check{"cost_control actual (+ 500 masraf)", costControl(t).ActualCost, 22000},
		)
		if c.Warning != "" {
			t.Fatalf("tahmin girilince uyarı kalkmalı: %q", c.Warning)
		}

		pr7 := approve(t, submittedPR(t, item("Fiyatsız", 1, nil)), service.PurchaseCostDecision{})
		if c := prCost(t, pr7.ID); c.Warning != domain.PurchaseCostNoPriceWarning || c.Amount != 0 {
			t.Fatalf("tahminsiz onaylanan fiyatsız talep maliyete 0 girer ve uyarır: %+v", c)
		}
		if _, err := svc.ApprovePurchaseRequestWithCost(ctx, p.ID, submittedPR(t, item("Negatif", 1, nil)).ID, org, "",
			service.PurchaseCostDecision{CostEstimate: ptrFloat(-5)}); !errors.Is(err, service.ErrInvalidCostEstimate) {
			t.Fatalf("negatif tahminle onay reddedilmeli: %v", err)
		}
		// Sonradan tahmin girilebilir (onaylı, siparişsiz).
		later := 400.0
		if _, err := svc.SetPurchaseRequestCost(ctx, p.ID, pr7.ID, org, "", service.PurchaseCostDecision{CostEstimate: &later}); err != nil {
			t.Fatal(err)
		}
		if fs := summary(t); !near(fs.PurchaseCost, 21900) {
			t.Fatalf("sonradan girilen tahmin: %v", fs.PurchaseCost)
		}
	})

	t.Run("12_order_without_request_and_short_close", func(t *testing.T) {
		po8 := newPO(t, "", poItem("Boya", 10, 100)) // 1.200
		if po8.PurchaseRequestID != nil || !po8.IncludeInProjectCost {
			t.Fatalf("talepsiz sipariş kendi kararıyla (evet) başlar: %+v", po8)
		}
		if _, err := svc.ApprovePurchaseOrderWithCost(ctx, p.ID, po8.ID, org, "", &yes); err != nil {
			t.Fatal(err)
		}
		if fs := summary(t); !near(fs.PurchaseCost, 23100) {
			t.Fatalf("talepsiz onaylı sipariş: %v", fs.PurchaseCost)
		}
		items, err := svc.ListPurchaseOrderItems(ctx, p.ID, po8.ID, org)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := svc.CreatePurchaseReceipt(ctx, p.ID, po8.ID, org, service.PurchaseReceiptInput{
			ReceivedDate: today, Destination: domain.ReceiptDestinationSite,
			Items: []service.PurchaseReceiptItemInput{{PurchaseOrderItemID: items[0].ID, AcceptedQuantity: 4}},
		}); err != nil {
			t.Fatal(err)
		}
		if fs := summary(t); !near(fs.PurchaseCost, 23100) || !near(fs.ReceivedNotCosted, 480) {
			t.Fatalf("açık siparişte teslim maliyeti değiştirmez; faturası bekleniyor 480: %v %v", fs.PurchaseCost, fs.ReceivedNotCosted)
		}
		// Kısa kapanış: yalnızca teslim alınan 4 x 100 + %20 = 480 kalır.
		if _, err := svc.ClosePurchaseOrder(ctx, p.ID, po8.ID, org, ""); err != nil {
			t.Fatal(err)
		}
		fs := summary(t)
		expect(t,
			check{"purchase_cost", fs.PurchaseCost, 22380},
			check{"received_not_costed", fs.ReceivedNotCosted, 480},
			check{"sipariş amount", poCost(t, po8.ID).Amount, 480},
		)
		if _, err := svc.SetPurchaseOrderCost(ctx, p.ID, po8.ID, org, "", false); !errors.Is(err, service.ErrPurchaseOrderCostNotChangeable) {
			t.Fatalf("kapatılmış siparişin kararı kesinleşmiştir: %v", err)
		}

		po9 := newPO(t, "", poItem("Genel kullanım", 1, 1000))
		if _, err := svc.ApprovePurchaseOrderWithCost(ctx, p.ID, po9.ID, org, "", &no); err != nil {
			t.Fatal(err)
		}
		fs = summary(t)
		expect(t, check{"purchase_cost", fs.PurchaseCost, 22380}, check{"purchase_excluded", fs.PurchaseExcluded, 2700})
	})

	t.Run("13_all_consumers_agree", func(t *testing.T) {
		fs, ctl := summary(t), costControl(t)
		// Kırılım: masraf satırı + satın almalar (taşeron yok).
		if !near(fs.RealizedCost, fs.ExpenseCost+fs.PurchaseCost+fs.SubcontractorWorkPaid+fs.NewSubcontractAccrued) {
			t.Fatalf("kırılım toplamı gerçekleşene eşit olmalı: %+v", fs)
		}
		if !near(fs.RealizedCostNet, fs.RealizedCost-fs.RealizedCostVAT) {
			t.Fatalf("KDV hariç maliyet = maliyet - içindeki KDV: %v %v %v", fs.RealizedCostNet, fs.RealizedCost, fs.RealizedCostVAT)
		}
		// Talep ve siparişlerin tek tek katkıları satın alma satırını verir.
		prs, err := svc.PurchaseRequestCosts(ctx, p.ID, "", org)
		if err != nil {
			t.Fatal(err)
		}
		pos, err := svc.PurchaseOrderCosts(ctx, p.ID, "", org)
		if err != nil {
			t.Fatal(err)
		}
		orders, err := svc.ListPurchaseOrders(ctx, p.ID, org)
		if err != nil {
			t.Fatal(err)
		}
		sum := 0.0
		for _, c := range prs {
			sum += c.Amount
		}
		for _, o := range orders {
			if o.PurchaseRequestID == nil {
				sum += pos[o.ID].Amount
			}
		}
		if !near(sum, fs.PurchaseCost) {
			t.Fatalf("talep + talepsiz sipariş katkıları %v, satın alma satırı %v", sum, fs.PurchaseCost)
		}
		// Maliyet Kontrolü: bütün satırlar maliyet koduna bağlı -- gerçekleşen birebir aynı.
		if !near(ctl.ActualCost, fs.RealizedCost) || !near(ctl.ActualCostNet, fs.RealizedCostNet) ||
			!near(ctl.PurchaseActualCost, fs.PurchaseCost) || fs.PurchaseCostUncoded != 0 {
			t.Fatalf("Maliyet Kontrolü (%v, net %v, satın alma %v) özetle (%v, net %v, satın alma %v) aynı olmalı",
				ctl.ActualCost, ctl.ActualCostNet, ctl.PurchaseActualCost, fs.RealizedCost, fs.RealizedCostNet, fs.PurchaseCost)
		}
		list, err := svc.List(ctx, org, service.ProjectListFilter{Limit: 200})
		if err != nil {
			t.Fatal(err)
		}
		var row *domain.Project
		for i := range list.Projects {
			if list.Projects[i].ID == p.ID {
				row = &list.Projects[i]
			}
		}
		if row == nil {
			t.Fatal("proje listede yok")
		}
		if !near(row.RealizedCost(), fs.RealizedCost) || !near(row.RealizedCostNet(), fs.RealizedCostNet) ||
			!near(row.RealizedGrossProfit(), fs.RealizedGrossProfit) || !near(row.RealizedGrossProfitNet(), fs.RealizedGrossProfitNet) {
			t.Fatalf("liste (maliyet %v/%v, kâr %v/%v) özetle (%v/%v, %v/%v) aynı olmalı",
				row.RealizedCost(), row.RealizedCostNet(), row.RealizedGrossProfit(), row.RealizedGrossProfitNet(),
				fs.RealizedCost, fs.RealizedCostNet, fs.RealizedGrossProfit, fs.RealizedGrossProfitNet)
		}
		_, authz := e.owner(t, "satin-alma-sahip")
		d := e.get(t, authz, domain.RoleAdmin)
		if d.Sections.Finance == nil || len(d.Sections.Finance.ByCurrency) != 1 {
			t.Fatalf("Ana Sayfa finans bölümü tek para birimi beklenir: %+v", d.Sections.Finance)
		}
		f := d.Sections.Finance.ByCurrency[0]
		if !near(f.RealizedCost, fs.RealizedCost) || !near(f.RealizedCostNet, fs.RealizedCostNet) || !near(f.PaidCost, fs.PaidCost) {
			t.Fatalf("Ana Sayfa (maliyet %v, net %v, ödenen %v) özetle (%v, %v, %v) aynı olmalı",
				f.RealizedCost, f.RealizedCostNet, f.PaidCost, fs.RealizedCost, fs.RealizedCostNet, fs.PaidCost)
		}
		// Tahmini (taahhüt bazlı): satın alma gerçekleşenin içinde, ayrıca taahhüt yok.
		if !near(fs.CommittedCost, fs.RealizedCost) || !near(fs.ForecastCost, fs.RealizedCost) {
			t.Fatalf("satın almanın kalan taahhüdü yoktur: tahmini %v, gerçekleşen %v", fs.ForecastCost, fs.RealizedCost)
		}
	})

	t.Run("14_locked_project_keeps_its_figures", func(t *testing.T) {
		pending := submittedPR(t, item("Kilitli", 1, price(100)))
		openPO := newPO(t, "", poItem("Kilitli sipariş", 1, 100))
		before := summary(t).RealizedCost
		e.exec(t, "UPDATE projects SET status = 'completed' WHERE id = $1", p.ID)
		t.Cleanup(func() { e.exec(t, "UPDATE projects SET status = 'active' WHERE id = $1", p.ID) })
		if _, err := svc.ApprovePurchaseRequestWithCost(ctx, p.ID, pending.ID, org, "", service.PurchaseCostDecision{}); !errors.Is(err, service.ErrProjectLocked) {
			t.Fatalf("tamamlanmış projede talep onayı rakamları değiştiremez: %v", err)
		}
		if _, err := svc.SetPurchaseRequestCost(ctx, p.ID, pr3.ID, org, "", service.PurchaseCostDecision{Include: &yes}); !errors.Is(err, service.ErrProjectLocked) {
			t.Fatalf("tamamlanmış projede karar değişmez: %v", err)
		}
		if _, err := svc.SetPurchaseOrderCost(ctx, p.ID, openPO.ID, org, "", false); !errors.Is(err, service.ErrProjectLocked) {
			t.Fatalf("tamamlanmış projede sipariş kararı değişmez: %v", err)
		}
		if after := summary(t).RealizedCost; !near(before, after) {
			t.Fatalf("rakamlar değişmemeli: %v -> %v", before, after)
		}
	})
}

// Kiracı izolasyonu ve maliyet kodu olmayan satın alma: başka firmanın
// talebine/siparişine erişilemez, karar değiştirilemez, sipariş başka
// projenin/firmanın talebine bağlanamaz; kodsuz satın alma finans özetinde
// sayılır, Maliyet Kontrolü'nde görünmez.
func TestPurchaseProjectCostIsolationAndUncoded(t *testing.T) {
	a := newDashTestEnv(t, "satin-alma-a")
	b := newDashTestEnv(t, "satin-alma-b")
	ctx := a.ctx
	box := testSecretBox(t)
	near := func(x, y float64) bool { return math.Abs(x-y) < 0.005 }
	yes := true

	pa := a.project(t, "A Projesi", domain.ProjectStatusActive, "TRY", 500000)
	pb := b.project(t, "B Projesi", domain.ProjectStatusActive, "TRY", 500000)
	pb2 := b.project(t, "B İkinci Proje", domain.ProjectStatusActive, "TRY", 500000)
	qb := sqlc.New(b.pool)
	ccB, err := service.NewCostCodeService(b.pool, qb).Create(ctx, b.org.ID, service.CostCodeInput{Code: "SAB-MLZ", Name: "Malzeme", Category: "Malzeme"})
	if err != nil {
		t.Fatal(err)
	}
	supA, err := service.NewSupplierService(a.pool, sqlc.New(a.pool), box).Create(ctx, a.org.ID, service.SupplierInput{Code: "SAA-SUP", LegalName: "A Tedarik"})
	if err != nil {
		t.Fatal(err)
	}
	supB, err := service.NewSupplierService(b.pool, qb, box).Create(ctx, b.org.ID, service.SupplierInput{Code: "SAB-SUP", LegalName: "B Tedarik"})
	if err != nil {
		t.Fatal(err)
	}
	approvedPR := func(t *testing.T, env *dashTestEnv, projectID string, items ...service.PurchaseRequestItemInput) *domain.PurchaseRequest {
		t.Helper()
		pr, err := env.projectSvc.CreatePurchaseRequest(ctx, projectID, env.org.ID, service.PurchaseRequestInput{Title: "Talep", Items: items})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := env.projectSvc.SubmitPurchaseRequest(ctx, projectID, pr.ID, env.org.ID, ""); err != nil {
			t.Fatal(err)
		}
		out, err := env.projectSvc.ApprovePurchaseRequest(ctx, projectID, pr.ID, env.org.ID, "")
		if err != nil {
			t.Fatal(err)
		}
		return out
	}

	// B: kodsuz 7.000 + kodlu 3.000 tahmin.
	prB := approvedPR(t, b, pb.ID,
		service.PurchaseRequestItemInput{Description: "Kodsuz", Quantity: 7, EstimatedUnitCost: ptrFloat(1000)},
		service.PurchaseRequestItemInput{CostCodeID: ccB.ID, Description: "Kodlu", Quantity: 3, EstimatedUnitCost: ptrFloat(1000)},
	)

	t.Run("1_uncoded_purchase_counts_but_not_in_cost_control", func(t *testing.T) {
		fs, err := b.projectSvc.FinancialSummary(ctx, pb.ID, b.org.ID)
		if err != nil {
			t.Fatal(err)
		}
		ctl, err := b.projectSvc.CostControlSummary(ctx, pb.ID, b.org.ID)
		if err != nil {
			t.Fatal(err)
		}
		if !near(fs.PurchaseCost, 10000) || !near(fs.PurchaseCostUncoded, 7000) || !near(ctl.PurchaseActualCost, 3000) || !near(ctl.ActualCost, 3000) {
			t.Fatalf("özet %v (kodsuz %v), Maliyet Kontrolü %v/%v", fs.PurchaseCost, fs.PurchaseCostUncoded, ctl.ActualCost, ctl.PurchaseActualCost)
		}
		// Karışık kodlu talepte onayda girilen tahmin kodsuz kalır.
		if _, err := b.projectSvc.SetPurchaseRequestCost(ctx, pb.ID, prB.ID, b.org.ID, "", service.PurchaseCostDecision{CostEstimate: ptrFloat(12000)}); err != nil {
			t.Fatal(err)
		}
		fs, _ = b.projectSvc.FinancialSummary(ctx, pb.ID, b.org.ID)
		ctl, _ = b.projectSvc.CostControlSummary(ctx, pb.ID, b.org.ID)
		if !near(fs.PurchaseCost, 12000) || !near(fs.PurchaseCostUncoded, 12000) || ctl.ActualCost != 0 {
			t.Fatalf("tahmin: özet %v (kodsuz %v), Maliyet Kontrolü %v", fs.PurchaseCost, fs.PurchaseCostUncoded, ctl.ActualCost)
		}
	})

	t.Run("2_other_tenant_cannot_see_or_change", func(t *testing.T) {
		if _, err := a.projectSvc.SetPurchaseRequestCost(ctx, pb.ID, prB.ID, a.org.ID, "", service.PurchaseCostDecision{Include: &yes}); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("başka firmanın talebinin kararı değiştirilemez: %v", err)
		}
		if _, err := a.projectSvc.SetPurchaseRequestCost(ctx, pa.ID, prB.ID, a.org.ID, "", service.PurchaseCostDecision{Include: &yes}); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("kendi projesinin URL'siyle başka firmanın talebi: %v", err)
		}
		costs, err := a.projectSvc.PurchaseRequestCosts(ctx, pb.ID, "", a.org.ID)
		if err != nil || len(costs) != 0 {
			t.Fatalf("başka firmanın talep maliyetleri görünmemeli: %v %v", err, costs)
		}
		if _, err := a.projectSvc.CreatePurchaseOrder(ctx, pa.ID, a.org.ID, service.PurchaseOrderInput{
			SupplierID: supA.ID, PurchaseRequestID: prB.ID, IssueDate: time.Now(),
			Items: []service.PurchaseOrderItemInput{{CostCodeID: ccB.ID, Description: "x", Quantity: 1, UnitPrice: 1}},
		}); !errors.Is(err, service.ErrPurchaseOrderRequestNotApproved) {
			t.Fatalf("başka firmanın talebine sipariş açılamamalı: %v", err)
		}
		// Aynı firmada başka projenin talebine de bağlanamaz.
		if _, err := b.projectSvc.CreatePurchaseOrder(ctx, pb2.ID, b.org.ID, service.PurchaseOrderInput{
			SupplierID: supB.ID, PurchaseRequestID: prB.ID, IssueDate: time.Now(),
			Items: []service.PurchaseOrderItemInput{{CostCodeID: ccB.ID, Description: "x", Quantity: 1, UnitPrice: 1}},
		}); !errors.Is(err, service.ErrPurchaseOrderRequestNotApproved) {
			t.Fatalf("başka projenin talebine sipariş bağlanamaz: %v", err)
		}
		fsA, err := a.projectSvc.FinancialSummary(ctx, pa.ID, a.org.ID)
		if err != nil {
			t.Fatal(err)
		}
		if fsA.PurchaseCost != 0 || fsA.RealizedCost != 0 {
			t.Fatalf("A'nın maliyeti B'nin satın almalarından etkilenmemeli: %+v", fsA)
		}
		if _, err := a.projectSvc.FinancialSummary(ctx, pb.ID, a.org.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("başka firmanın finans özeti okunamaz: %v", err)
		}
	})
}
