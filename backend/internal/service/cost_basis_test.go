package service_test

// Maliyet tanımları (migration 0073, docs/maliyet-tanimlari.md) -- gerçek bir
// PostgreSQL bağlantısı gerektirir. Gerçekleşen maliyet tahakkuk esaslıdır:
// sözleşmeli taşeronun onaylı ama ödenmemiş hakedişi maliyettir; avans (basit
// taşerona "avans" diye girilen ya da sözleşmeli taşerona hakedişe
// bağlanmadan verilen) işe sayılana / hakedişten mahsup edilene kadar maliyet
// değildir; onay bekleyen masraf ve hakediş ayrı gösterilir. Proje listesi,
// finans özeti ve Ana Sayfa aynı rakamı verir.

import (
	"errors"
	"math"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestProjectCostBasis(t *testing.T) {
	e := newDashTestEnv(t, "maliyet-tanimlari")
	ctx := e.ctx
	org := e.org.ID
	svc := e.projectSvc
	q := sqlc.New(e.pool)
	costCodeSvc := service.NewCostCodeService(e.pool, q)
	supplierSvc := service.NewSupplierService(e.pool, q, testSecretBox(t))
	today := time.Now()
	near := func(a, b float64) bool { return math.Abs(a-b) < 0.005 }

	p := e.project(t, "Maliyet Tanımları", domain.ProjectStatusActive, "TRY", 1000000)
	summary := func(t *testing.T) *domain.ProjectFinancialSummary {
		t.Helper()
		fs, err := svc.FinancialSummary(ctx, p.ID, org)
		if err != nil {
			t.Fatal(err)
		}
		return fs
	}

	// Onaylı masraf 10.000; onay bekleyen 4.000 maliyete girmez, ayrıca görünür.
	if _, err := createApprovedExpense(ctx, svc, p.ID, org, service.ExpenseInput{
		Category: domain.ExpenseMaterial, Description: "Malzeme", Amount: 10000, Currency: "TRY", ExpenseDate: today,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.CreateExpense(ctx, p.ID, org, service.ExpenseInput{
		Category: domain.ExpenseMaterial, Description: "Bekleyen", Amount: 4000, Currency: "TRY", ExpenseDate: today,
	}); err != nil {
		t.Fatal(err)
	}

	// Basit taşeron: 100.000 sözleşme; 30.000 iş ödemesi + 20.000 avans.
	simple, err := svc.CreateSubcontractor(ctx, p.ID, org, service.SubcontractorInput{
		Name: "Basit Taşeron", ContractAmount: 100000, Currency: "TRY",
	})
	if err != nil {
		t.Fatal(err)
	}
	pay := func(t *testing.T, amount float64, kind string) *domain.SubcontractorPayment {
		t.Helper()
		out, err := svc.CreateSubcontractorPayment(ctx, p.ID, simple.ID, org, service.SubcontractorPaymentInput{
			Amount: amount, Currency: "TRY", PaidDate: today, PaymentKind: kind,
		})
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	work := pay(t, 30000, "")
	if work.PaymentKind != domain.SubcontractorPaymentKindWork {
		t.Fatalf("tür verilmeyen ödeme iş ödemesidir (eski istemciler), geldi %q", work.PaymentKind)
	}
	advance := pay(t, 20000, domain.SubcontractorPaymentKindAdvance)

	// Sözleşmeli taşeron: 200.000, avans 15.000, teminat %5. Hakedişe
	// bağlanmadan ödenen 15.000 avanstır.
	sup, err := supplierSvc.Create(ctx, org, service.SupplierInput{Code: "MT-TAS", LegalName: "Sözleşmeli Taşeron", Specialty: "Kaba"})
	if err != nil {
		t.Fatal(err)
	}
	cc, err := costCodeSvc.Create(ctx, org, service.CostCodeInput{Code: "MT-TAS", Name: "Taşeron", Category: "Taşeron"})
	if err != nil {
		t.Fatal(err)
	}
	sc, err := svc.CreateSubcontract(ctx, p.ID, org, service.SubcontractInput{
		SupplierID: sup.ID, Title: "Kaba inşaat", RetentionPercent: ptrFloat(5), AdvanceAmount: ptrFloat(15000),
		Items: []service.SubcontractItemInput{{CostCodeID: cc.ID, Description: "İmalat", OriginalAmount: 200000}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := svc.ActivateSubcontract(ctx, p.ID, sc.ID, org, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.CreateSubcontractPayment(ctx, p.ID, sc.ID, org, service.SubcontractPaymentInput{
		Amount: 15000, Currency: "TRY", PaidDate: today,
	}); err != nil {
		t.Fatal(err)
	}

	t.Run("1_advances_are_paid_but_not_cost", func(t *testing.T) {
		fs := summary(t)
		checks := []struct {
			name      string
			got, want float64
		}{
			{"realized_cost", fs.RealizedCost, 40000}, // 10.000 masraf + 30.000 iş
			{"paid_cost", fs.PaidCost, 75000},         // + 20.000 + 15.000 avans
			{"advance_open", fs.AdvanceOpen, 35000},
			{"subcontractor_paid", fs.SubcontractorPaid, 50000},
			{"subcontractor_work_paid", fs.SubcontractorWorkPaid, 30000},
			{"subcontractor_advance_open", fs.SubcontractorAdvanceOpen, 20000},
			// Kalan taahhüt: sözleşme - iş ödemesi; avans taahhüdün içinde kalır.
			{"subcontractor_remaining", fs.SubcontractorRemaining, 70000},
			{"new_subcontract_paid", fs.NewSubcontractPaid, 15000},
			{"new_subcontract_accrued", fs.NewSubcontractAccrued, 0},
			{"new_subcontract_advance_open", fs.NewSubcontractAdvanceOpen, 15000},
			{"new_subcontract_remaining", fs.NewSubcontractRemaining, 200000},
			{"pending_expenses", fs.PendingExpenses, 4000},
			{"pending_cost", fs.PendingCost, 4000},
			// Tahmini maliyet = gerçekleşen + kalan taahhüt = 40.000 + 70.000 + 200.000.
			{"committed_cost", fs.CommittedCost, 310000},
		}
		for _, c := range checks {
			if !near(c.got, c.want) {
				t.Errorf("%s = %v, beklenen %v", c.name, c.got, c.want)
			}
		}
	})

	t.Run("2_offset_moves_advance_into_cost_once", func(t *testing.T) {
		out, err := svc.OffsetSubcontractorAdvance(ctx, p.ID, advance.ID, org, "")
		if err != nil {
			t.Fatal(err)
		}
		if out.PaymentKind != domain.SubcontractorPaymentKindWork || out.OffsetAt == nil {
			t.Fatalf("işe sayılan avans iş ödemesi olmalı ve zamanı tutulmalı: %+v", out)
		}
		fs := summary(t)
		if !near(fs.RealizedCost, 60000) || !near(fs.SubcontractorAdvanceOpen, 0) || !near(fs.SubcontractorRemaining, 50000) {
			t.Fatalf("işe sayıldıktan sonra maliyet 60.000, açık avans 0, kalan 50.000 olmalı: %v %v %v",
				fs.RealizedCost, fs.SubcontractorAdvanceOpen, fs.SubcontractorRemaining)
		}
		if !near(fs.CommittedCost, 310000) {
			t.Fatalf("işe saymak tahmini maliyeti değiştirmemeli (yalnızca sınıf değişir): %v", fs.CommittedCost)
		}
		if _, err := svc.OffsetSubcontractorAdvance(ctx, p.ID, advance.ID, org, ""); !errors.Is(err, service.ErrNotOpenAdvance) {
			t.Fatalf("aynı avans iki kez işe sayılamaz, geldi %v", err)
		}
		if _, err := svc.OffsetSubcontractorAdvance(ctx, p.ID, work.ID, org, ""); !errors.Is(err, service.ErrNotOpenAdvance) {
			t.Fatalf("iş ödemesi işe sayılamaz, geldi %v", err)
		}
		voided := pay(t, 1000, domain.SubcontractorPaymentKindAdvance)
		if _, err := svc.VoidSubcontractorPayment(ctx, p.ID, voided.ID, org, "", "Hatalı"); err != nil {
			t.Fatal(err)
		}
		if _, err := svc.OffsetSubcontractorAdvance(ctx, p.ID, voided.ID, org, ""); !errors.Is(err, service.ErrNotOpenAdvance) {
			t.Fatalf("iptal edilmiş avans işe sayılamaz, geldi %v", err)
		}
		if _, err := svc.CreateSubcontractorPayment(ctx, p.ID, simple.ID, org, service.SubcontractorPaymentInput{
			Amount: 1, Currency: "TRY", PaidDate: today, PaymentKind: "bonus",
		}); !errors.Is(err, service.ErrInvalidPaymentKind) {
			t.Fatalf("bilinmeyen ödeme türü reddedilmeli, geldi %v", err)
		}
	})

	t.Run("3_certified_unpaid_claim_is_cost", func(t *testing.T) {
		items, err := svc.ListSubcontractItems(ctx, p.ID, sc.ID, org)
		if err != nil {
			t.Fatal(err)
		}
		// 80.000 iş; teminat %5 = 4.000; avans mahsubu 15.000; net 61.000.
		claim, err := svc.CreateProgressClaim(ctx, p.ID, sc.ID, org, service.ProgressClaimInput{
			PeriodEnd: today, AdvanceRecoveryAmount: 15000,
			Items: []service.ProgressClaimItemInput{{SubcontractItemID: items[0].ID, CurrentProgressAmount: 80000}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := svc.SubmitProgressClaim(ctx, p.ID, claim.ID, org, ""); err != nil {
			t.Fatal(err)
		}
		fs := summary(t)
		if !near(fs.NewSubcontractPendingClaims, 80000) || !near(fs.NewSubcontractAccrued, 0) || !near(fs.PendingCost, 84000) {
			t.Fatalf("onaya sunulan hakediş maliyet değil, bekleyen olarak görünmeli: %v %v %v",
				fs.NewSubcontractPendingClaims, fs.NewSubcontractAccrued, fs.PendingCost)
		}
		if _, err := svc.CertifyProgressClaim(ctx, p.ID, claim.ID, org, ""); err != nil {
			t.Fatal(err)
		}
		fs = summary(t)
		checks := []struct {
			name      string
			got, want float64
		}{
			{"new_subcontract_accrued", fs.NewSubcontractAccrued, 80000},
			{"new_subcontract_advance_open", fs.NewSubcontractAdvanceOpen, 0},
			{"new_subcontract_payable", fs.NewSubcontractPayable, 61000},
			{"new_subcontract_retention", fs.NewSubcontractRetention, 4000},
			{"new_subcontract_pending_claims", fs.NewSubcontractPendingClaims, 0},
			{"new_subcontract_remaining", fs.NewSubcontractRemaining, 120000},
			// 10.000 masraf + 50.000 basit iş + 80.000 onaylı hakediş.
			{"realized_cost", fs.RealizedCost, 140000},
			// Nakit değişmedi: 10.000 + 50.000 + 15.000.
			{"paid_cost", fs.PaidCost, 75000},
			{"committed_cost", fs.CommittedCost, 310000},
		}
		for _, c := range checks {
			if !near(c.got, c.want) {
				t.Errorf("%s = %v, beklenen %v", c.name, c.got, c.want)
			}
		}

		// Hakedişe bağlı ödeme ödenecekten düşer, maliyeti değiştirmez.
		if _, err := svc.CreateSubcontractPayment(ctx, p.ID, sc.ID, org, service.SubcontractPaymentInput{
			ProgressClaimID: claim.ID, Amount: 61000, Currency: "TRY", PaidDate: today,
		}); err != nil {
			t.Fatal(err)
		}
		fs = summary(t)
		if !near(fs.NewSubcontractPayable, 0) || !near(fs.RealizedCost, 140000) || !near(fs.PaidCost, 136000) {
			t.Fatalf("ödeme sonrası ödenecek 0, maliyet 140.000, ödenen 136.000 olmalı: %v %v %v",
				fs.NewSubcontractPayable, fs.RealizedCost, fs.PaidCost)
		}
	})

	t.Run("4_list_detail_dashboard_agree", func(t *testing.T) {
		fs := summary(t)
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
		if row.RealizedCost() != fs.RealizedCost || row.RealizedGrossProfit() != fs.RealizedGrossProfit ||
			row.SubcontractorRemaining != fs.SubcontractorRemaining {
			t.Fatalf("liste (maliyet %v, kâr %v, kalan %v) özetle (%v, %v, %v) aynı olmalı",
				row.RealizedCost(), row.RealizedGrossProfit(), row.SubcontractorRemaining,
				fs.RealizedCost, fs.RealizedGrossProfit, fs.SubcontractorRemaining)
		}

		_, authz := e.owner(t, "maliyet-sahip")
		d := e.get(t, authz, domain.RoleAdmin)
		if d.Sections.Finance == nil || len(d.Sections.Finance.ByCurrency) != 1 {
			t.Fatalf("Ana Sayfa finans bölümü tek para birimi beklenir: %+v", d.Sections.Finance)
		}
		f := d.Sections.Finance.ByCurrency[0]
		if !near(f.RealizedCost, fs.RealizedCost) || !near(f.PaidCost, fs.PaidCost) {
			t.Fatalf("Ana Sayfa (maliyet %v, ödenen %v) özetle (%v, %v) aynı olmalı",
				f.RealizedCost, f.PaidCost, fs.RealizedCost, fs.PaidCost)
		}
		if !near(f.CashBalance, f.CollectedTotal-fs.PaidCost) {
			t.Fatalf("nakit dengesi tahsilat - ödenen olmalı: %v", f.CashBalance)
		}
	})
}
