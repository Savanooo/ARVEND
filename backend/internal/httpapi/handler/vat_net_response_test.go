package handler

import (
	"encoding/json"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

func jsonMap(t *testing.T, v any) map[string]any {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

// Proje listesi KDV hariç karşılıkları financial-summary'nin alan adlarıyla
// döner; tekil okuma yollarında (aggregate yok) ve projects.finance.read
// izni olmayana (bkz. canSeeProjectFinance) hiçbiri yanıtta olmaz.
func TestProjectResponseVATNetFields(t *testing.T) {
	p := domain.Project{
		ContractAmount: 1200000, ChangeOrderNet: 48000, CollectedAmount: 300000,
		TotalExpenses: 150000, SubcontractorPaid: 25000, NewSubcontractPaid: 40000,
		ExpenseVATTotal: 20000, ContractVATAmount: 208000, ContractVATKnown: true,
		HasFinanceAggregates: true,
	}
	m := jsonMap(t, toProjectResponse(p, true))
	want := map[string]any{
		"realized_cost": 215000.0, "realized_gross_profit": 1033000.0,
		"expense_vat_total": 20000.0, "contract_vat_known": true,
		"current_contract_value_net": 1040000.0, "realized_cost_net": 195000.0,
		"realized_gross_profit_net": 845000.0,
	}
	for k, v := range want {
		if m[k] != v {
			t.Errorf("%s = %v, beklenen %v", k, m[k], v)
		}
	}

	withheld := jsonMap(t, toProjectResponse(p, false))
	for k := range want {
		if _, ok := withheld[k]; ok {
			t.Errorf("finans izni olmayana %s gitmemeli", k)
		}
	}

	p.HasFinanceAggregates = false
	single := jsonMap(t, toProjectResponse(p, true))
	for k := range want {
		if _, ok := single[k]; ok {
			t.Errorf("tekil okumada %s olmamalı", k)
		}
	}
}

// costControlRevenueKeys: Maliyet Kontrolü özetinin gelir tarafı (satış
// bedeli ve ondan türeyen kâr) -- KDV dahil ve KDV hariç hepsi AYNI
// görünürlükte olmalı: biri null ise hepsi null (bkz. setCostControlRevenue).
// projects.finance.read izni olmayana hepsi null döner (showRevenue false).
var costControlRevenueKeys = []string{
	"contract_value", "forecast_profit", "forecast_margin_percent",
	"contract_vat_amount", "contract_vat_known", "contract_value_net",
	"forecast_profit_net", "forecast_margin_percent_net",
}

func assertCostControlRevenueTogether(t *testing.T, summary map[string]any) {
	t.Helper()
	hidden := summary["contract_value"] == nil
	for _, k := range costControlRevenueKeys {
		val, present := summary[k]
		if !present {
			t.Errorf("%s yanıtta olmalı (gizliyse null): %v", k, summary)
			continue
		}
		if (val == nil) != hidden {
			t.Errorf("%s = %v; contract_value gizli=%v -- gelir tarafı birlikte açılıp kapanmalı", k, val, hidden)
		}
	}
}

func TestCostControlAndChangeOrderVATNetFields(t *testing.T) {
	summary := domain.CostControlSummary{
		ContractValue: 1248000, EACTotal: 500000, ActualCostNet: 50000, EACNet: 490000,
		ForecastProfit: 748000, ForecastMarginPercent: 59.94,
		ContractVATAmount: 208000, ContractVATKnown: true, ContractValueNet: 1040000,
		ForecastProfitNet: 550000, ForecastMarginPercentNet: 52.88,
	}
	cc := jsonMap(t, toCostControlSummaryResponse(summary, true))
	for k, v := range map[string]any{
		"contract_value": 1248000.0, "forecast_profit": 748000.0, "forecast_margin_percent": 59.94,
		"eac": 500000.0, "actual_cost_net": 50000.0, "eac_net": 490000.0, "contract_vat_amount": 208000.0,
		"contract_vat_known": true, "contract_value_net": 1040000.0,
		"forecast_profit_net": 550000.0, "forecast_margin_percent_net": 52.88,
	} {
		if cc[k] != v {
			t.Errorf("maliyet kontrolü %s = %v, beklenen %v", k, cc[k], v)
		}
	}
	assertCostControlRevenueTogether(t, cc)

	// Finans izni yok: gelir tarafının tamamı null, maliyet tarafı (KDV
	// hariç dahil) aynen.
	hidden := jsonMap(t, toCostControlSummaryResponse(summary, false))
	for _, k := range costControlRevenueKeys {
		if hidden[k] != nil {
			t.Errorf("finans izni olmayana %s = %v gitmemeli", k, hidden[k])
		}
	}
	assertCostControlRevenueTogether(t, hidden)
	if hidden["eac"] != 500000.0 || hidden["actual_cost_net"] != 50000.0 || hidden["eac_net"] != 490000.0 {
		t.Errorf("maliyet rakamları gizlenmemeli: %v", hidden)
	}
	line := jsonMap(t, toCostControlLineResponse(domain.CostControlLine{ActualCost: 60000, ActualCostNet: 50000, EACNet: 490000}))
	if line["actual_cost_net"] != 50000.0 || line["eac_net"] != 490000.0 {
		t.Errorf("satır: %v %v", line["actual_cost_net"], line["eac_net"])
	}

	co := toChangeOrderResponse(domain.ChangeOrder{Profitability: &domain.ChangeOrderProfitability{
		RevenueEffect: 60000, RevenueEffectNet: 50000, RealizedCostNet: 10000, CommittedCostNet: 10000,
		RealizedProfitNet: 40000, EstimatedProfitNet: 40000, RealizedMarginPercentNet: 80, EstimatedMarginPercentNet: 80,
	}})
	pm := jsonMap(t, co)["profitability"].(map[string]any)
	for k, v := range map[string]any{
		"revenue_effect_net": 50000.0, "realized_cost_net": 10000.0, "committed_cost_net": 10000.0,
		"realized_profit_net": 40000.0, "estimated_profit_net": 40000.0,
		"realized_margin_percent_net": 80.0, "estimated_margin_percent_net": 80.0,
	} {
		if pm[k] != v {
			t.Errorf("ek iş %s = %v, beklenen %v", k, pm[k], v)
		}
	}
}
