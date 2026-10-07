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
}
