package service

import (
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

func TestApplyForecast(t *testing.T) {
	base := func() domain.ProjectFinancialSummary {
		s := domain.ProjectFinancialSummary{
			CurrentContractValue: 1200000, ContractVATAmount: 200000, ContractVATKnown: true,
			RealizedCost: 500000, CommittedCost: 900000,
			SubcontractorPaid: 100000, SubcontractorWorkPaid: 100000, SubcontractorRemaining: 50000,
		}
		applyNetFigures(&s)
		return s
	}

	t.Run("bütçe kalemi yoksa (otomatik boş bütçe) taahhüt bazlı", func(t *testing.T) {
		s := base()
		applyForecast(&s, &domain.CostControlSummary{HasBudget: true, RevisedBudget: 0, EACTotal: 0})
		if s.ForecastBasis != domain.ForecastBasisCommitments || s.ForecastCost != 900000 {
			t.Fatalf("%v %v", s.ForecastBasis, s.ForecastCost)
		}
		if s.ForecastProfit != 300000 || s.ForecastProfitNet != 100000 || s.ForecastMarginPercentNet != 10 {
			t.Fatalf("%v %v %v", s.ForecastProfit, s.ForecastProfitNet, s.ForecastMarginPercentNet)
		}
	})

	t.Run("gerçek bütçe varsa EAC + Maliyet Kontrolü'nün görmediği eski taşeron", func(t *testing.T) {
		s := base()
		applyForecast(&s, &domain.CostControlSummary{HasBudget: true, RevisedBudget: 800000, EACTotal: 700000, EACNet: 700000})
		if s.ForecastBasis != domain.ForecastBasisBudget || s.ForecastCost != 850000 {
			t.Fatalf("%v %v", s.ForecastBasis, s.ForecastCost)
		}
		if s.ForecastProfit != 350000 || s.ForecastProfitNet != 150000 || s.ForecastMarginPercentNet != 15 {
			t.Fatalf("%v %v %v", s.ForecastProfit, s.ForecastProfitNet, s.ForecastMarginPercentNet)
		}
	})

	// Basit taşerona verilen avans (migration 0073) kalan taahhüdün içinde
	// durur; EAC'ye eklenen eski taşeron payı onu ikinci kez saymamalı.
	t.Run("eski taşeron avansı EAC'ye iki kez eklenmez", func(t *testing.T) {
		s := base()
		s.SubcontractorPaid, s.SubcontractorAdvanceOpen = 130000, 30000
		applyForecast(&s, &domain.CostControlSummary{HasBudget: true, RevisedBudget: 800000, EACTotal: 700000, EACNet: 700000})
		if s.ForecastCost != 850000 {
			t.Fatalf("avans iki kez sayılmamalı: %v", s.ForecastCost)
		}
	})

	t.Run("Maliyet Kontrolü okunamazsa taahhüt bazlı", func(t *testing.T) {
		s := base()
		applyForecast(&s, nil)
		if s.ForecastBasis != domain.ForecastBasisCommitments {
			t.Fatal(s.ForecastBasis)
		}
	})

	t.Run("KDV bilinmiyorsa net değerler KDV dahil ile aynı", func(t *testing.T) {
		s := domain.ProjectFinancialSummary{CurrentContractValue: 1000, RealizedCost: 400, CommittedCost: 600}
		applyNetFigures(&s)
		if s.CurrentContractValueNet != 1000 || s.RealizedGrossProfitNet != 600 || s.EstimatedGrossProfitNet != 400 {
			t.Fatalf("%+v", s)
		}
	})

	// Masraf KDV'si (migration 0065): gerçekleşen maliyetin içindeki KDV
	// (migration 0078'den beri realized_cost_vat: masraf satırı + satın
	// almalar) KDV hariç maliyetten düşülür; bütçe tahmininde Maliyet
	// Kontrolü'nün kendi KDV hariç EAC'si (yalnızca kodlu satırların KDV'si
	// düşülmüş) kullanılır. ExpenseVATTotal (bütün onaylı masrafların KDV'si)
	// artık yalnızca bilgidir -- satın almanın içindeki fatura iki kez düşülmesin.
	withExpenseVAT := func(known bool) domain.ProjectFinancialSummary {
		s := domain.ProjectFinancialSummary{
			CurrentContractValue: 1200000, ContractVATAmount: 200000, ContractVATKnown: known,
			RealizedCost: 500000, CommittedCost: 900000,
			SubcontractorPaid: 100000, SubcontractorWorkPaid: 100000, SubcontractorRemaining: 50000,
			ExpenseVATTotal: 99999, RealizedCostVAT: 30000,
		}
		if !known {
			s.ContractVATAmount = 0
		}
		applyNetFigures(&s)
		return s
	}

	t.Run("masraf KDV'si KDV hariç maliyet ve kârdan düşülür", func(t *testing.T) {
		s := withExpenseVAT(true)
		if s.RealizedCostNet != 470000 || s.CommittedCostNet != 870000 {
			t.Fatalf("maliyet hariç: %v %v", s.RealizedCostNet, s.CommittedCostNet)
		}
		if s.RealizedGrossProfitNet != 530000 || s.EstimatedGrossProfitNet != 130000 || s.RealizedMarginPercentNet != 53 {
			t.Fatalf("kâr hariç: %v %v %v", s.RealizedGrossProfitNet, s.EstimatedGrossProfitNet, s.RealizedMarginPercentNet)
		}
		applyForecast(&s, nil)
		if s.ForecastCostNet != 870000 || s.ForecastProfitNet != 130000 || s.ForecastCost != 900000 {
			t.Fatalf("taahhüt bazlı tahmin: %v %v %v", s.ForecastCostNet, s.ForecastProfitNet, s.ForecastCost)
		}
	})

	t.Run("bütçe tahmininde yalnızca kodlu masrafın KDV'si düşülür", func(t *testing.T) {
		s := withExpenseVAT(true)
		// EAC'nin içindeki (kodlu) masraf KDV'si 10.000: eac_net = 690.000.
		applyForecast(&s, &domain.CostControlSummary{HasBudget: true, RevisedBudget: 800000, EACTotal: 700000, EACNet: 690000})
		if s.ForecastCost != 850000 || s.ForecastCostNet != 840000 || s.ForecastProfitNet != 160000 || s.ForecastMarginPercentNet != 16 {
			t.Fatalf("%v %v %v %v", s.ForecastCost, s.ForecastCostNet, s.ForecastProfitNet, s.ForecastMarginPercentNet)
		}
	})

	// Satın almalar (migration 0078): maliyet koduna bağlı olmayan satın alma
	// Maliyet Kontrolü'nde görünmez; bütçe bazlı tahmine eski taşeron gibi
	// ayrıca eklenir (KDV'si bilinmez, KDV hariç tahmine de aynı tutar).
	t.Run("kodsuz satın alma bütçe tahminine ayrıca eklenir", func(t *testing.T) {
		s := withExpenseVAT(true)
		s.PurchaseCostUncoded = 7000
		applyForecast(&s, &domain.CostControlSummary{HasBudget: true, RevisedBudget: 800000, EACTotal: 700000, EACNet: 690000})
		if s.ForecastBasis != domain.ForecastBasisBudget || s.ForecastCost != 857000 || s.ForecastCostNet != 847000 {
			t.Fatalf("%v %v %v", s.ForecastBasis, s.ForecastCost, s.ForecastCostNet)
		}
		applyForecast(&s, nil)
		if s.ForecastCost != s.CommittedCost {
			t.Fatalf("taahhüt bazlı tahmin gerçekleşeni (satın almalar dahil) zaten içerir: %v", s.ForecastCost)
		}
	})

	t.Run("sözleşme KDV'si bilinmiyorsa maliyet hariç ama kâr KDV dahil kalır", func(t *testing.T) {
		s := withExpenseVAT(false)
		if s.RealizedCostNet != 470000 {
			t.Fatalf("maliyet hariç yine gerçek değer: %v", s.RealizedCostNet)
		}
		if s.RealizedGrossProfitNet != 700000 || s.EstimatedGrossProfitNet != 300000 {
			t.Fatalf("kâr KDV dahil ile aynı olmalı: %v %v", s.RealizedGrossProfitNet, s.EstimatedGrossProfitNet)
		}
		applyForecast(&s, nil)
		if s.ForecastProfitNet != s.ForecastProfit || s.ForecastMarginPercentNet != s.ForecastMarginPercent {
			t.Fatalf("tahmini kâr KDV dahil ile aynı olmalı: %v/%v %v/%v",
				s.ForecastProfitNet, s.ForecastProfit, s.ForecastMarginPercentNet, s.ForecastMarginPercent)
		}
	})
}
