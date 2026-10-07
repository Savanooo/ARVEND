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
			SubcontractorPaid: 100000, SubcontractorRemaining: 50000,
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
		applyForecast(&s, &domain.CostControlSummary{HasBudget: true, RevisedBudget: 800000, EACTotal: 700000})
		if s.ForecastBasis != domain.ForecastBasisBudget || s.ForecastCost != 850000 {
			t.Fatalf("%v %v", s.ForecastBasis, s.ForecastCost)
		}
		if s.ForecastProfit != 350000 || s.ForecastProfitNet != 150000 || s.ForecastMarginPercentNet != 15 {
			t.Fatalf("%v %v %v", s.ForecastProfit, s.ForecastProfitNet, s.ForecastMarginPercentNet)
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

	// Masraf KDV'si (migration 0065): onaylı masrafların içindeki KDV KDV
	// hariç maliyetten düşülür; bütçe tahmininde yalnızca kodlu masrafınki.
	withExpenseVAT := func(known bool) domain.ProjectFinancialSummary {
		s := domain.ProjectFinancialSummary{
			CurrentContractValue: 1200000, ContractVATAmount: 200000, ContractVATKnown: known,
			RealizedCost: 500000, CommittedCost: 900000,
			SubcontractorPaid: 100000, SubcontractorRemaining: 50000,
			ExpenseVATTotal: 30000, CodedExpenseVATTotal: 10000,
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
		applyForecast(&s, &domain.CostControlSummary{HasBudget: true, RevisedBudget: 800000, EACTotal: 700000})
		if s.ForecastCost != 850000 || s.ForecastCostNet != 840000 || s.ForecastProfitNet != 160000 || s.ForecastMarginPercentNet != 16 {
			t.Fatalf("%v %v %v %v", s.ForecastCost, s.ForecastCostNet, s.ForecastProfitNet, s.ForecastMarginPercentNet)
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
