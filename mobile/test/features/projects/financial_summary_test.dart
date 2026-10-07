import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/projects/domain/project.dart';

Map<String, dynamic> _base() => {
      'current_contract_value': 1200000,
      'collected_amount': 0,
      'remaining_receivable': 1200000,
      'total_expenses': 0,
      'subcontractor_paid': 900000,
      'subcontractor_remaining': 0,
      'realized_cost': 900000,
      'committed_cost': 900000,
      'realized_gross_profit': 300000,
      'estimated_gross_profit': 300000,
      'realized_margin_percent': 25,
      'estimated_margin_percent': 25,
      'currency': 'TRY',
    };

void main() {
  test('KDV hariç ve tahmin alanları sunucudan okunur', () {
    final s = FinancialSummary.fromJson({
      ..._base(),
      'contract_vat_known': true,
      'contract_vat_amount': 200000,
      'current_contract_value_net': 1000000,
      'realized_gross_profit_net': 100000,
      'realized_margin_percent_net': 10,
      'forecast_basis': 'budget',
      'forecast_cost': 950000,
      'forecast_profit': 250000,
      'forecast_profit_net': 50000,
      'forecast_margin_percent': 20.83,
      'forecast_margin_percent_net': 5,
    });
    expect(s.contractVatKnown, isTrue);
    expect(s.currentContractValueNet, 1000000);
    expect(s.realizedGrossProfitNet, 100000);
    expect(s.forecastFromBudget, isTrue);
    expect(s.forecastCost, 950000);
    expect(s.forecastProfitNet, 50000);
    expect(s.forecastMarginPercentNet, 5);
  });

  test('eski sunucu (alanlar yok): KDV dahil ve taahhüt bazlı değerlere düşer', () {
    final s = FinancialSummary.fromJson(_base());
    expect(s.contractVatKnown, isFalse);
    expect(s.currentContractValueNet, 1200000);
    expect(s.realizedGrossProfitNet, 300000);
    expect(s.forecastFromBudget, isFalse);
    expect(s.forecastCost, 900000);
    expect(s.forecastProfit, 300000);
    expect(s.forecastMarginPercent, 25);
  });
}
